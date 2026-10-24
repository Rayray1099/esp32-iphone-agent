import Foundation

/// A changing transport timestamp is not evidence of a changing picture.
/// Compare a small luminance image against the last changed image, so slow
/// animations accumulate instead of being mistaken for a quiet screen.
struct FrameStability {
    private var anchor: [UInt8] = []
    private(set) var changedAt = 0.0
    mutating func observe(_ pixels: [UInt8], at time: Double) {
        guard !pixels.isEmpty else { return }
        let changed: Bool
        if pixels.count != anchor.count { changed = true }
        else {
            var total = 0, hits = 0
            for (a, b) in zip(pixels, anchor) {
                let delta = abs(Int(a) - Int(b))
                total += delta
                if delta > 10 { hits += 1 }
            }
            changed = hits >= 2 || Double(total) / Double(pixels.count) > 0.6
        }
        if changed { anchor = pixels; changedAt = time }
    }
    func quiet(at time: Double, for duration: Double) -> Bool {
        !anchor.isEmpty && time - changedAt >= duration
    }
}
