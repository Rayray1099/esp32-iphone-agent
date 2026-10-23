import UIKit

struct PointerAccuracySample {
    let target: CGPoint
    let landed: CGPoint?
    static let side = 20.0
    func offset(in size: CGSize) -> CGPoint? {
        landed.map { CGPoint(x: ($0.x - target.x) * size.width, y: ($0.y - target.y) * size.height) }
    }
    func hit(in size: CGSize) -> Bool {
        guard let d = offset(in: size) else { return false }
        return abs(d.x) <= Self.side / 2 && abs(d.y) <= Self.side / 2
    }
}

extension AutoCalibrator {
    /// Actual UIKit touch landings. Validation samples never train the calibration.
    func testSmallTargets(precise: Bool = false) {
        guard !busy, !app.agent.running, !app.startingAgent, boardReady, app.pointer.calibrated,
              DeviceScreen.foreground else { return }
        current = Task {
            accuracy = []
            accuracySummary = nil
            problem = nil
            phase = .verifying
            openBoard()
            defer {
                accuracyTarget = nil
                phase = .done
                progress = nil
                Task { _ = try? await app.pointer.reset() }
            }
            do {
                let device = app.board.commands
                _ = try await device.send("v1 POST input/claim {}")
                defer { Task { _ = try? await device.send("v1 POST input/release {}") } }
                if precise { try await app.feed.stream(true) }
                defer { if precise { Task { try? await app.feed.stream(false) } } }
                let positions = [CGPoint(x: 0.16, y: 0.20), CGPoint(x: 0.84, y: 0.72),
                                 CGPoint(x: 0.50, y: 0.36), CGPoint(x: 0.84, y: 0.20),
                                 CGPoint(x: 0.16, y: 0.55), CGPoint(x: 0.50, y: 0.72),
                                 CGPoint(x: 0.84, y: 0.36), CGPoint(x: 0.16, y: 0.72),
                                 CGPoint(x: 0.50, y: 0.20), CGPoint(x: 0.84, y: 0.55),
                                 CGPoint(x: 0.16, y: 0.36), CGPoint(x: 0.50, y: 0.55)]
                try await app.pointer.reset()
                for (index, target) in (positions + Array(positions.reversed())).enumerated() {
                    try Task.checkCancellation()
                    accuracyTarget = target
                    progress = Progress(done: index, total: positions.count * 2)
                    // Let the displayed target be captured before an optional visual check.
                    if precise { _ = await app.feed.fresh(since: now(), timeout: 3) }
                    let sent = now()
                    try await app.pointer.tap(target.x, target.y, aim: precise)
                    let landed = await app.probe.tap(since: sent)
                    let sample = PointerAccuracySample(target: target, landed: landed)
                    accuracy.append(sample)
                    if let d = sample.offset(in: DeviceScreen.size) {
                        app.say(String(format: "accuracy %d %@: target %.4f %.4f landed %.4f %.4f dx %+.2f dy %+.2f pt hit %d",
                                       index + 1, precise ? "precise" : "calibrated", target.x, target.y, landed!.x, landed!.y,
                                       d.x, d.y, sample.hit(in: DeviceScreen.size) ? 1 : 0))
                    } else { app.say("accuracy \(index + 1): no touch received") }
                }
                let size = DeviceScreen.size
                let offsets = accuracy.compactMap { $0.offset(in: size) }
                let hits = accuracy.filter { $0.hit(in: size) }.count
                let dy = offsets.isEmpty ? 0 : offsets.map(\.y).reduce(0, +) / Double(offsets.count)
                let worst = offsets.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
                accuracySummary = String(format: "20 pt 小目標：%d/%d 命中，平均上下偏移 %+.1f pt，最大誤差 %.1f pt",
                                         hits, accuracy.count, dy, worst)
                app.say("accuracy result: " + (accuracySummary ?? ""))
            } catch {
                accuracySummary = "測試中止：" + error.localizedDescription
                app.say("accuracy failed: " + error.localizedDescription)
            }
        }
    }
}
