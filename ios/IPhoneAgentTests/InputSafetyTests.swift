import XCTest
@testable import IPhoneAgent

@MainActor final class InputSafetyTests: XCTestCase {
    func testOnlyReadCommandsCanReplayAfterAnUncertainReply() {
        for command in ["click", "move 20 -4", "type text", "key cmd+a", "press", "button 4", "v1 POST run/start {}"] {
            XCTAssertFalse(CommandChannel.canReplay(command), command)
        }
        XCTAssertTrue(CommandChannel.canReplay("video-status"))
        XCTAssertTrue(CommandChannel.canReplay("snap"))
    }

    func testKeyboardRecognitionDoesNotMistakeOneZhuyinCharacterForALayout() {
        XCTAssertEqual(EnglishInput.layout(["ㄅ ㄉ ㄓ ㄚ", "空白"]), .zhuyin)
        XCTAssertEqual(EnglishInput.layout(["注音"]), .zhuyin)
        XCTAssertEqual(EnglishInput.layout(["English (US)"]), .english)
        XCTAssertEqual(EnglishInput.layout(["Q", "W", "E", "R", "T", "Y"]), .english)
        XCTAssertEqual(EnglishInput.layout(["搜尋", "ㄅ"]), .unknown)
        XCTAssertEqual(EnglishInput.layout([]), .unknown)
    }

    func testSmallTargetUsesEachScreenAxisInPoints() {
        let size = CGSize(width: 440, height: 956)
        let target = CGPoint(x: 0.5, y: 0.5)
        let hit = PointerAccuracySample(target: target, landed: CGPoint(x: 0.51, y: 0.495))
        XCTAssertTrue(hit.hit(in: size))
        XCTAssertEqual(hit.offset(in: size)!.y, -4.78, accuracy: 0.01)
        XCTAssertFalse(PointerAccuracySample(target: target, landed: CGPoint(x: 0.5, y: 0.48)).hit(in: size))
        XCTAssertFalse(PointerAccuracySample(target: target, landed: nil).hit(in: size))
    }

    func testPreciseTapDoesNotClickWhenPointerCannotBeVerified() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let screen = FakeScreen()
        let pointer = Pointer(device: device, calibrationFile: file, screen: screen)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        do { try await pointer.tap(0.5, 0.5, aim: true); XCTFail("Unverified tap succeeded") }
        catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertFalse(device.sent.contains("click"))
    }

    func testOldDiagonalCalibrationIsNotReusedForAxisPacedFirmware() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"w":522,"h":1204}"#.utf8).write(to: file)
        XCTAssertFalse(Pointer(device: FakeDevice(), calibrationFile: file).calibrated)
    }
}
