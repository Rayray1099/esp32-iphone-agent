import Foundation
import Vision

/// On-device keyboard OCR. Unknown input sources must not silently accept ASCII keystrokes.
enum EnglishInput {
    enum Layout: Equatable { case english, zhuyin, other, unknown }
    struct Word { let text: String; let box: CGRect } // Vision coordinates, origin bottom left

    static func layout(_ words: [String]) -> Layout {
        let text = words.joined(separator: " ").lowercased()
        let symbols = Set(text.unicodeScalars.filter { (0x3105...0x312f).contains($0.value) })
        if symbols.count >= 3 || text.contains("注音") || text.contains("zhuyin") { return .zhuyin }
        if text.contains("手寫") || text.contains("handwriting") || text.contains("日本語") || text.contains("表情符號") { return .other }
        if text.contains("english") || text.contains("英文") || text.contains("qwerty") { return .english }
        // Vision often groups a row into one observation, e.g. "q w e r t y".
        let rows = words.map { $0.lowercased().filter { !$0.isWhitespace } }
        let keys = Set(rows.filter { row in
            row.count == 1 || ["qwert", "asdfg", "zxcvb"].contains(where: row.contains)
        }.joined())
        if words.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "注" }) { return .zhuyin }
        if keys.intersection(Set("qwertyuiop")).count >= 6 { return .english }
        return .unknown
    }

    /// OCR misses individual key caps. Require their positions to fit the three
    /// staggered QWERTY rows, rather than counting letters in suggestions.
    static func qwertyGrid(_ words: [Word], aspect: Double) -> Bool {
        let rows = [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm")]
        let starts = [0.06, 0.106, 0.204]
        let keys = words.filter { $0.text.count == 1 && $0.box.width < 0.085 && $0.box.midY < 0.45 }
        for spacing in [0.12, 0.13, 0.14] {
            let gap = spacing * aspect
            for anchor in keys {
                for row in rows.indices {
                    guard let col = rows[row].firstIndex(of: Character(anchor.text.lowercased())),
                          abs(anchor.box.midX - (starts[row] + Double(col) * 0.098)) < 0.035 else { continue }
                    let top = anchor.box.midY + Double(row) * gap
                    var hits = Set<String>(), hitRows = Set<Int>()
                    for key in keys {
                        for r in rows.indices {
                            guard let c = rows[r].firstIndex(of: Character(key.text.lowercased())),
                                  abs(key.box.midX - (starts[r] + Double(c) * 0.098)) < 0.035,
                                  abs(key.box.midY - (top - Double(r) * gap)) < gap * 0.25 else { continue }
                            hits.insert(key.text.lowercased()); hitRows.insert(r)
                        }
                    }
                    if hits.count >= 8 && hitRows.count >= 2 { return true }
                }
            }
        }
        return false
    }

    static func classify(_ words: [Word], image: CGImage) -> Layout {
        // Ctrl-Space lists every language. "English" in that list does not mean
        // it is selected; compare backgrounds beside the option labels.
        let labels = ["english", "注音", "手寫", "日本語", "表情符號", "emoji"]
        let options = words.filter { word in
            word.box.midX > 0.25 && word.box.midX < 0.75 && word.box.midY > 0.25 && word.box.midY < 0.8 &&
            labels.contains(where: { word.text.lowercased().contains($0) })
        }
        if !options.isEmpty {
            let gray = Vision.gray(image, image.width, image.height)
            func background(_ x: Double, _ y: Double) -> Double {
                let cx = Int(x * Double(gray.w)), cy = Int((1 - y) * Double(gray.h))
                var total = 0, count = 0
                for row in max(0, cy - 3)..<min(gray.h, cy + 4) {
                    for col in max(0, cx - 2)..<min(gray.w, cx + 3) { total += Int(gray.px[row * gray.w + col]); count += 1 }
                }
                return Double(total) / Double(max(count, 1))
            }
            // Compare each label's margins with the rows directly above/below.
            // This also works when OCR reads only the English label in a menu.
            let selected = options.filter { word in
                let step = word.box.height * 1.85
                return [word.box.minX - 0.02, word.box.maxX + 0.02].contains { x in
                    let value = background(x, word.box.midY)
                    return value > background(x, word.box.midY + step) + 12 &&
                           value > background(x, word.box.midY - step) + 12
                }
            }
            guard let first = selected.first,
                  selected.allSatisfy({ abs($0.box.midY - first.box.midY) < 0.015 }) else { return .unknown }
            return layout(selected.map { $0.text })
        }
        if qwertyGrid(words, aspect: Double(image.width) / Double(image.height)) { return .english }
        return layout(words.filter { $0.box.midY < 0.36 }.map { $0.text })
    }

    static func read(_ jpeg: Data, diagnostic: ((String) -> Void)? = nil) async -> Layout {
        await Task.detached(priority: .userInitiated) {
            guard let image = Vision.image(jpeg) else { return Layout.unknown }
            let request = VNRecognizeTextRequest()
            #if targetEnvironment(simulator)
            request.usesCPUOnly = true // Hosted simulators have no usable Neural Engine.
            #endif
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "zh-Hant"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.008
            // Full image coordinates keep key positions and menu pixel samples
            // in the same space. Vision's ROI boxes are relative to the ROI.
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                var words = (request.results ?? []).compactMap { r in
                    r.topCandidates(1).first.map { Word(text: $0.string, box: r.boundingBox) }
                }
                diagnostic?(words.map { "\($0.text) @ \($0.box)" }.joined(separator: "; "))
                let first = classify(words, image: image)
                if first != .unknown { return first }
                // Chinese input-source labels and the small 注 space-bar hint
                // can disappear when English has recognition priority. The
                // common English path needs only the first pass.
                request.recognitionLanguages = ["zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: image).perform([request])
                words += (request.results ?? []).compactMap { r in
                    r.topCandidates(1).first.map { Word(text: $0.string, box: r.boundingBox) }
                }
                diagnostic?("Chinese pass: " + words.map { "\($0.text) @ \($0.box)" }.joined(separator: "; "))
                return classify(words, image: image)
            } catch {
                diagnostic?("OCR failed: \(error)")
                return .unknown
            }
        }.value
    }

    /// Injectable observations exercise the actual recovery path in regression tests.
    @MainActor static func ensure(device: HIDDevice, observe: () async throws -> Layout,
                                  changed: (Double) async throws -> Void, log: (String) -> Void) async throws {
        if try await observe() == .english { return }
        log("keyboard: selecting a confirmed English input source")
        // A bounded cycle includes handwriting/emoji. Never type probe characters
        // into a user's field, and never retry user text after an uncertain reply.
        for _ in 0..<6 {
            try Task.checkCancellation()
            let sent = now()
            try await device.send("key ctrl+space")
            try await changed(sent)
            if try await observe() == .english {
                log("keyboard: English confirmed")
                return
            }
        }
        throw DeviceError(message: "未能確認英文輸入來源，未輸入文字。請選擇 English (US) 後再試。")
    }

    @MainActor static func ensure(screen: ScreenSource, device: HIDDevice, log: (String) -> Void) async throws {
        try await ensure(device: device, observe: {
            guard screen.live, let frame = screen.frame else { throw BlindError() }
            return await read(frame)
        }, changed: { sent in
            try await screen.afterAction(since: sent)
        }, log: log)
    }
}
