import XCTest
import CoreGraphics
@testable import IPhoneAgent

@MainActor final class InputSafetyTests: XCTestCase {
    func testOnlyReadCommandsCanReplayAfterAnUncertainReply() {
        for command in ["click", "move 20 -4", "type text", "key cmd+a", "press", "button 4", "v1 POST run/start {}"] {
            XCTAssertFalse(CommandChannel.canReplay(command), command)
        }
        XCTAssertTrue(CommandChannel.canReplay("video-status"))
        XCTAssertTrue(CommandChannel.canReplay("snap"))
    }

    func testEnglishSourceIsOneEisuKeyWithoutControlSpace() async throws {
        let device = FakeDevice()
        var messages: [String] = []
        try await EnglishInput.ensure(device: device, log: { messages.append($0) })
        XCTAssertEqual(device.sent, ["key eisu"])
        XCTAssertFalse(device.sent.contains(where: { $0.hasPrefix("source") }))
        XCTAssertEqual(messages.count, 1)
    }

    func testFirmwareWithoutEisuNeverTypes() async throws {
        let device = RejectingDevice(reject: "key eisu", reply: "err unknown key")
        let screen = FakeScreen()  // Pointer holds its screen weakly.
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                              screen: screen)
        do { try await pointer.type("Weather"); XCTFail("Typed without selecting English") }
        catch { XCTAssertTrue((error as? DeviceError)?.message.contains("韌體") == true, "\(error)") }
        XCTAssertEqual(device.sent, ["key eisu"])
    }

    func testEisuLinkFailureIsReportedAsIsAndNeverTypes() async throws {
        let device = RejectingDevice(reject: "key eisu", reply: "board not connected")
        let screen = FakeScreen()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                              screen: screen)
        do { try await pointer.type("Weather"); XCTFail("Typed after a failed source key") }
        catch { XCTAssertEqual((error as? DeviceError)?.message, "board not connected") }
        XCTAssertEqual(device.sent, ["key eisu"])
    }

    func testMissingMirroredScreenNeverTypes() async throws {
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        do { try await pointer.type("Weather"); XCTFail("Typed without screen") }
        catch { XCTAssertTrue(error is BlindError) }
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testPointerTypeSelectsEnglishBeforeText() async throws {
        let device = FakeDevice()
        let screen = FakeScreen()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                              screen: screen)
        try await pointer.type("AbC_123!")
        XCTAssertEqual(device.sent, ["key eisu", "type AbC_123!"])
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

    func testActualPointerSearchOrdersFocusClearAndTypeWithoutSubmitting() async throws {
        let screen = FakeScreen()
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), screen: screen)
        try await pointer.search("Weather")
        XCTAssertEqual(device.sent, ["key cmd+space", "key eisu", "key cmd+a", "key backspace", "type Weather"])
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

/// Fails one command the way CommandChannel does: an `err` reply or a dropped link.
@MainActor private final class RejectingDevice: HIDDevice {
    let links = 1, connected = true
    let reject: String, reply: String
    var sent: [String] = []
    init(reject: String, reply: String) { self.reject = reject; self.reply = reply }
    func send(_ command: String) async throws -> String {
        sent.append(command)
        if command == reject { throw DeviceError(message: reply) }
        return "ok"
    }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { true }
}
