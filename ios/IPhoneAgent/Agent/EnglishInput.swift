import Foundation
import Vision
import CoreGraphics

/// On-device keyboard OCR. Unknown input sources must not silently accept ASCII keystrokes.
enum EnglishInput {
    enum Layout: Equatable { case english, zhuyin, other, unknown }
    struct Word { let text: String; let box: CGRect } // Vision coordinates, origin bottom left

    struct SourceImage {
        let image: CGImage
        let box: CGRect // Region of the full frame, in Vision coordinates.

        func fullFrame(_ word: Word) -> Word {
            Word(text: word.text, box: CGRect(x: box.minX + word.box.minX * box.width,
                                             y: box.minY + word.box.minY * box.height,
                                             width: word.box.width * box.width,
                                             height: word.box.height * box.height))
        }
    }

    /// The hardware-source selector is centered on iOS. OCR only its region:
    /// a full AirPlay frame spends CPU time recognizing unrelated app content.
    /// Keep the pixel crop's exact bounds so highlight samples use full-frame
    /// coordinates rather than Vision's crop-relative bounding boxes.
    static func sourceImage(_ image: CGImage) -> SourceImage? {
        let pixels = CGRect(x: Double(image.width) * 0.18, y: Double(image.height) * 0.18,
                            width: Double(image.width) * 0.64, height: Double(image.height) * 0.64).integral
        guard let crop = image.cropping(to: pixels) else { return nil }
        let width = min(440, crop.width)
        let height = Int((Double(crop.height) * Double(width) / Double(crop.width)).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return SourceImage(image: scaled, box: CGRect(x: pixels.minX / Double(image.width),
                                                    y: 1 - pixels.maxY / Double(image.height),
                                                    width: pixels.width / Double(image.width),
                                                    height: pixels.height / Double(image.height)))
    }

    /// Crop pixels, not Vision's ROI: its returned boxes are ROI-relative. A
    /// keyboard-only pass also avoids the recognizer spending time on app icons
    /// and missing small isolated key caps in a full mirrored frame.
    static func keyboardImage(_ image: CGImage) -> (image: CGImage, fraction: Double)? {
        let height = Int((Double(image.height) * 0.45).rounded())
        guard let crop = image.cropping(to: CGRect(x: 0, y: image.height - height, width: image.width, height: height)) else { return nil }
        let width = min(440, crop.width)
        let scaledHeight = Int((Double(crop.height) * Double(width) / Double(crop.width)).rounded())
        guard let context = CGContext(data: nil, width: width, height: scaledHeight, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: scaledHeight))
        guard let scaled = context.makeImage() else { return nil }
        return (scaled, Double(height) / Double(image.height))
    }

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

    static func classify(_ words: [Word], image: CGImage, hardwareSource: Bool = false) -> Layout {
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
            // A translucent menu can be brighter near its bottom even when that
            // row is not selected. Require the rounded selection pill's two
            // horizontal edges and a vertical peak at one of those margins.
            // Scale by the font's pixel height so this works at any size.
            let selected = options.filter { word in
                let step = word.box.height * 1.85
                let textHeight = word.box.height * Double(image.height) / Double(image.width)
                var verticalPeak = false
                let edges = [-1.0, 1.0].allSatisfy { side in
                    let edge = side < 0 ? word.box.minX : word.box.maxX
                    let x = edge + side * textHeight * 0.3
                    let value = background(x, word.box.midY)
                    if value > background(x, word.box.midY + step) + 12 &&
                       value > background(x, word.box.midY - step) + 12 { verticalPeak = true }
                    return value > background(edge + side * textHeight * 0.7, word.box.midY) + 12
                }
                return edges && verticalPeak
            }
            guard let first = selected.first,
                  selected.allSatisfy({ abs($0.box.midY - first.box.midY) < 0.015 }) else { return .unknown }
            return layout(selected.map { $0.text })
        }
        if hardwareSource { return .unknown }
        if qwertyGrid(words, aspect: Double(image.width) / Double(image.height)) { return .english }
        return layout(words.filter { $0.box.midY < 0.36 }.map { $0.text })
    }

    static func read(_ jpeg: Data, diagnostic: ((String) -> Void)? = nil, failure: ((String) -> Void)? = nil, summary: ((String) -> Void)? = nil, hardwareSource: Bool = false) async -> Layout {
        await Task.detached(priority: .userInitiated) {
            guard let image = Vision.image(jpeg) else { return Layout.unknown }
            let request = VNRecognizeTextRequest()
            // The agent types with its own app in the background. GPU Vision
            // requests can be denied there, even when the same test passes in
            // the foreground or on a simulator. Match our CPU video decoder.
            request.usesCPUOnly = true
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "zh-Hant"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.008
            // Full image coordinates keep key positions and menu pixel samples
            // in the same space. Vision's ROI boxes are relative to the ROI.
            do {
                if !hardwareSource, let crop = keyboardImage(image) {
                    request.minimumTextHeight = 0.018
                    request.recognitionLanguages = ["en-US"]
                    for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
                        request.recognitionLevel = level
                        try VNImageRequestHandler(cgImage: crop.image).perform([request])
                        let keys = (request.results ?? []).compactMap { r -> Word? in
                            guard let text = r.topCandidates(1).first?.string else { return nil }
                            var box = r.boundingBox
                            box.origin.y *= crop.fraction; box.size.height *= crop.fraction
                            return Word(text: text, box: box)
                        }
                        diagnostic?("Keyboard crop: " + keys.map { "\($0.text) @ \($0.box)" }.joined(separator: "; "))
                        let layout = classify(keys, image: image)
                        summary?("crop \(image.width)x\(image.height), \(level == .fast ? "fast" : "accurate"), \(keys.count) observations, grid \(qwertyGrid(keys, aspect: Double(image.width) / Double(image.height)))")
                        if layout != .unknown { return layout }
                    }
                }
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US", "zh-Hant"]
                request.minimumTextHeight = 0.008
                let source = hardwareSource ? sourceImage(image) : nil
                let recognitionImage = source?.image ?? image
                try VNImageRequestHandler(cgImage: recognitionImage).perform([request])
                var words = (request.results ?? []).compactMap { r in
                    r.topCandidates(1).first.map {
                        let word = Word(text: $0.string, box: r.boundingBox)
                        return source?.fullFrame(word) ?? word
                    }
                }
                summary?("\(hardwareSource ? "source" : "full") \(recognitionImage.width)x\(recognitionImage.height), accurate, \(words.count) observations")
                diagnostic?(words.map { "\($0.text) @ \($0.box)" }.joined(separator: "; "))
                let first = classify(words, image: image, hardwareSource: hardwareSource)
                if first != .unknown { return first }
                // Chinese input-source labels and the small 注 space-bar hint
                // can disappear when English has recognition priority. The
                // common English path needs only the first pass.
                request.recognitionLanguages = ["zh-Hant", "en-US"]
                try VNImageRequestHandler(cgImage: recognitionImage).perform([request])
                words += (request.results ?? []).compactMap { r in
                    r.topCandidates(1).first.map {
                        let word = Word(text: $0.string, box: r.boundingBox)
                        return source?.fullFrame(word) ?? word
                    }
                }
                diagnostic?("Chinese pass: " + words.map { "\($0.text) @ \($0.box)" }.joined(separator: "; "))
                return classify(words, image: image, hardwareSource: hardwareSource)
            } catch {
                diagnostic?("OCR failed: \(error)")
                let ns = error as NSError
                failure?("keyboard OCR unavailable: \(ns.domain) (\(ns.code))")
                return .unknown
            }
        }.value
    }

    /// Injectable observations exercise the actual recovery path in regression tests.
    @MainActor static func ensure(device: HIDDevice, observe: () async throws -> Layout,
                                  changed: (Double) async throws -> Void, log: (String) -> Void) async throws {
        log("keyboard: selecting a confirmed English input source")
        // A bounded cycle includes handwriting/emoji. Never type probe characters
        // into a user's field, and never retry user text after an uncertain reply.
        do {
            for _ in 0..<6 {
                try Task.checkCancellation()
                let sent = now()
                try await device.send("source next")
                try await changed(sent)
                if try await observe() == .english {
                    let released = now()
                    try await device.send("source release")
                    // A highlighted row is only a pending choice while Control
                    // is held. Let iOS commit it and dismiss the selector before
                    // the first ASCII key, then require the capture path to be
                    // fresh after that release as for every other HID action.
                    try await changed(released)
                    try Task.checkCancellation()
                    log("keyboard: hardware English confirmed")
                    return
                }
            }
            throw DeviceError(message: "未能確認英文硬體輸入來源，未輸入文字。請確認開發板韌體已更新後再試。")
        } catch {
            _ = try? await device.send("source release")
            throw error
        }
    }

    @MainActor static func ensure(screen: ScreenSource, device: HIDDevice, log: @escaping (String) -> Void) async throws {
        try await ensure(device: device, observe: {
            guard screen.live, let frame = screen.frame else { throw BlindError() }
            let began = now()
            var issue: String?
            let result = await read(frame, failure: { issue = $0 }, summary: { log("keyboard OCR: " + $0) }, hardwareSource: true)
            if let issue { throw DeviceError(message: issue + "；未輸入文字。") }
            log(String(format: "keyboard: %@ (%.0f ms)", String(describing: result), (now() - began) * 1000))
            return result
        }, changed: { sent in
            try await screen.afterAction(since: sent)
        }, log: log)
    }
}
