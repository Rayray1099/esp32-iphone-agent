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
        XCTAssertEqual(EnglishInput.layout(["q w e r t y u i o p"]), .english)
        XCTAssertEqual(EnglishInput.layout(["注"]), .zhuyin)
        XCTAssertEqual(EnglishInput.layout(["繁體手寫"]), .other)
        XCTAssertEqual(EnglishInput.layout(["搜尋", "ㄅ"]), .unknown)
        XCTAssertEqual(EnglishInput.layout([]), .unknown)
    }

    func testKeyboardOCRFromCroppedPhysicalPhoneFixtures() async throws {
        let bundle = Bundle(for: Self.self)
        for (name, expected) in [("english-keyboard", EnglishInput.Layout.english),
                                 ("zhuyin-keyboard", .zhuyin), ("english-source-menu", .english)] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jpg"))
            let actual = await EnglishInput.read(try Data(contentsOf: url))
            XCTAssertEqual(actual, expected, name)
        }
    }

    func testUnknownKeyboardCyclesToConfirmedEnglishWithoutTypingProbeText() async throws {
        let device = FakeDevice()
        var observations: [EnglishInput.Layout] = [.unknown, .zhuyin, .other, .english]
        var freshChecks = 0
        try await EnglishInput.ensure(device: device, observe: { observations.removeFirst() },
                                      changed: { _ in freshChecks += 1 }, log: { _ in })
        XCTAssertEqual(device.sent, Array(repeating: "key ctrl+space", count: 3))
        XCTAssertEqual(freshChecks, 3)
        XCTAssertTrue(observations.isEmpty)
    }

    func testUnrecognizedKeyboardFailsAfterOneBoundedCycle() async {
        let device = FakeDevice()
        do {
            try await EnglishInput.ensure(device: device, observe: { .unknown }, changed: { _ in }, log: { _ in })
            XCTFail("Unknown input source was accepted")
        } catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertEqual(device.sent, Array(repeating: "key ctrl+space", count: 6))
        XCTAssertFalse(device.sent.contains(where: { $0.hasPrefix("type ") }))
    }

    func testEnglishFastPathDoesNotToggleOrWait() async throws {
        let device = FakeDevice()
        try await EnglishInput.ensure(device: device, observe: { .english },
                                      changed: { _ in XCTFail("Known English waited") }, log: { _ in })
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testMissingMirroredScreenNeverTypes() async throws {
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do { try await pointer.type("Weather"); XCTFail("Typed without screen") }
        catch { XCTAssertTrue(error is BlindError) }
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testSpotlightSearchIsOneActorActionAndNeverPressesReturn() async throws {
        let phone = FakeGestures()
        let screen = FakeScreen()
        let actor = FakeModel { _ in "THINK: Search first\nDO: search Weather" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        _ = try await agent.step()
        XCTAssertEqual(phone.calls, ["search"])
        XCTAssertEqual(actor.prompts.count, 1)
        XCTAssertEqual(try Actions.parseCommand("search Weather")["text"], .str("Weather"))
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
