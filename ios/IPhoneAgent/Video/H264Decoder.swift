import Foundation

/// CPU decoding and JPEG conversion, confined to one serial queue.
final class H264Decoder: @unchecked Sendable {
    struct Frame {
        let jpeg: Data
        let width: Int, height: Int
        let decodeMs: Double
        let unit: AccessUnit
    }
    var onFrame: ((Frame) -> Void)?
    var onError: ((String) -> Void)?
    var quality: Double = 0.75
    let queue = DispatchQueue(label: "video.decode")
    private let software = SoftwareH264()
    private var config = Data()
    private var needsKey = true

    func reset() { software.reset(); config = Data(); needsKey = true }

    func decode(_ unit: AccessUnit, emit: Bool = true) {
        if unit.config {
            config = unit.data
            software.reset()
            needsKey = true
        } else if needsKey && !unit.idr { return }
        if unit.idr && needsKey && !config.isEmpty {
            _ = software.decode(config, timestamp: UInt64(unit.boardMs), jpegQuality: quality, emit: false)
        }
        let started = CFAbsoluteTimeGetCurrent()
        let jpeg = software.decode(unit.data, timestamp: UInt64(unit.boardMs), jpegQuality: quality, emit: emit)
        guard software.lastStatus == 0 else {
            needsKey = true
            onError?("CPU H.264 decode failed \(software.lastStatus)")
            return
        }
        if unit.idr { needsKey = false }
        guard let jpeg, emit else { return }
        let captured = AccessUnit(data: Data(), idr: unit.idr, config: false, snap: unit.snap,
                                  boardMs: UInt32(truncatingIfNeeded: software.outputTimestamp))
        onFrame?(Frame(jpeg: jpeg, width: software.width, height: software.height,
                       decodeMs: (CFAbsoluteTimeGetCurrent() - started) * 1000, unit: captured))
    }
}
