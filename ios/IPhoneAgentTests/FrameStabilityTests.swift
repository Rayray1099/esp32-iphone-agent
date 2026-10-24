import XCTest
@testable import IPhoneAgent

final class FrameStabilityTests: XCTestCase {
    func testRepeatedFramesBecomeQuietWithoutWaitingForTransportToStop() {
        var s = FrameStability()
        for i in 0...20 { s.observe([20, 40, 60, 80], at: Double(i) / 10) }
        XCTAssertTrue(s.quiet(at: 2, for: 0.4))
        XCTAssertEqual(s.changedAt, 0)
    }
    func testSlowChangesAccumulateAgainstLastChangedPicture() {
        var s = FrameStability()
        s.observe(Array(repeating: 10, count: 100), at: 0)
        s.observe(Array(repeating: 11, count: 100), at: 0.5)
        XCTAssertFalse(s.quiet(at: 0.6, for: 0.4))
        XCTAssertEqual(s.changedAt, 0.5)
    }
    func testAnimationAndSmallContentChangesResetQuietWindow() {
        var s = FrameStability()
        s.observe(Array(repeating: 20, count: 100), at: 0)
        var pixels = Array(repeating: UInt8(20), count: 100)
        pixels[20] = 60; pixels[21] = 60
        s.observe(pixels, at: 1)
        XCTAssertFalse(s.quiet(at: 1.2, for: 0.4))
        XCTAssertTrue(s.quiet(at: 1.5, for: 0.4))
    }
    func testNoFrameNeverBecomesQuiet() {
        XCTAssertFalse(FrameStability().quiet(at: 100, for: 0.4))
    }
}
