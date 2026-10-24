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

    static func classify(_ words: [Word], image: CGImage) -> Layout {
        // Ctrl-Space lists every language. "English" in that list does not mean
        // it is selected; compare backgrounds beside the option labels.
        let labels = ["english", "注音", "手寫", "日本語", "表情符號", "emoji"]
        let options = words.filter { word in
            word.box.midX > 0.25 && word.box.midX < 0.75 && word.box.midY > 0.25 && word.box.midY < 0.8 &&
            labels.contains(where: { word.text.lowercased().contains($0) })
        }
        if options.count >= 2, let left = options.map({ $0.box.minX }).min() {
            let gray = Vision.gray(image, image.width, image.height)
            let scores = options.map { word -> (Word, Double) in
                let x = max(0, Int((left - 0.025) * Double(gray.w)))
                let y = max(0, Int((1 - word.box.midY - 0.008) * Double(gray.h)))
                let width = max(2, Int(Double(gray.w) * 0.015))
                let height = max(2, Int(Double(gray.h) * 0.016))
                var total = 0, count = 0
                for row in y..<min(gray.h, y + height) {
                    for col in x..<min(gray.w, x + width) { total += Int(gray.px[row * gray.w + col]); count += 1 }
                }
                return (word, Double(total) / Double(max(count, 1)))
            }.sorted { $0.1 > $1.1 }
            guard scores[0].1 - scores[1].1 >= 8 else { return .unknown }
            return layout([scores[0].0.text])
        }
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
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.8)
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                let words = (request.results ?? []).compactMap { r in
                    r.topCandidates(1).first.map { Word(text: $0.string, box: r.boundingBox) }
                }
                diagnostic?(words.map { "\($0.text) @ \($0.box)" }.joined(separator: "; "))
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
