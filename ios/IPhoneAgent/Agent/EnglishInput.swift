import Foundation
import Vision

/// On-device OCR of the keyboard only. No text, screenshot, or extra request is sent to a model.
enum EnglishInput {
    enum Layout: Equatable { case english, zhuyin, unknown }

    static func layout(_ words: [String]) -> Layout {
        let text = words.joined(separator: " ").lowercased()
        if text.contains("english") || text.contains("英文") || text.contains("qwerty") { return .english }
        let symbols = Set(text.unicodeScalars.filter { (0x3105...0x312f).contains($0.value) })
        if symbols.count >= 3 || text.contains("注音") || text.contains("zhuyin") { return .zhuyin }
        let letters = Set(words.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        if letters.intersection(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]).count >= 6 { return .english }
        return .unknown
    }

    static func read(_ jpeg: Data) async -> Layout {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US", "zh-Hant"]
            request.usesLanguageCorrection = false
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.42)
            do {
                try VNImageRequestHandler(data: jpeg).perform([request])
                return layout((request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
            } catch { return .unknown }
        }.value
    }

    @MainActor static func ensure(screen: ScreenSource, device: HIDDevice, log: (String) -> Void) async throws {
        guard let image = screen.frame else { throw BlindError() }
        let initial = await read(image)
        // A hidden hardware keyboard has no visible language indicator. Preserve it; never blindly toggle.
        guard initial == .zhuyin else { return }
        log("keyboard: 注音 detected; selecting English before ASCII input")
        for _ in 0..<3 {
            try Task.checkCancellation()
            try await device.send("key ctrl+space")
            guard let frame = await screen.fresh(since: now(), timeout: 3) else { throw BlindError() }
            await screen.settled(quiet: 0.15, least: 0.15, most: 0.8)
            if await read(screen.frame ?? frame) == .english {
                log("keyboard: English confirmed")
                return
            }
        }
        throw DeviceError(message: "未能確認英文鍵盤，未輸入文字，避免產生注音或重複內容。")
    }
}
