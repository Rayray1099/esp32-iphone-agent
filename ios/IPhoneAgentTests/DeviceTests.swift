import XCTest
@testable import IPhoneAgent

/// A board that answers every command like the firmware does.
@MainActor final class FakeBoard: BoardTransport {
    var isConnected = true
    var lines: [String] = []
    var drops = 0
    var silent = false
    weak var channel: CommandChannel?

    func write(_ line: String) throws {
        lines.append(line)
        guard !silent else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let reply = parts[1] == "bad" ? "\(parts[0]) err unknown command" : "\(parts[0]) ok"
        Task { @MainActor in self.channel?.handleReply(reply) }
    }

    func dropLink() { drops += 1 }
}

/// Port of server/tests/test_device.py, with a fake BLE transport instead of a TCP socket.
@MainActor final class DeviceTests: XCTestCase {
    func testTimeoutGrowsWithMoveDistanceAndTextLength() {
        XCTAssertEqual(CommandChannel.timeout("click"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("move 1000 -20"), CommandChannel.timeout("move 10 10"))
        XCTAssertGreaterThanOrEqual(CommandChannel.timeout("move 10 10"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("type " + String(repeating: "x", count: 40)),
                             CommandChannel.timeout("type hi"))
    }

    func testSendWithoutBoardFailsFast() async {
        do {
            try await CommandChannel().send("ping")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not connected"))
        }
    }

    func testRoundTripWithAFakeBoard() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        channel.linkUp()
        let ok = await channel.waitConnected(2)
        XCTAssertTrue(ok)
        try await channel.send("ping")
        do {
            try await channel.send("bad")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown command"))
        }
        XCTAssertEqual(channel.links, 1)
        let ids = board.lines.compactMap { Int($0.split(separator: " ")[0]) }  // request ids: random start, then +1
        XCTAssertEqual(board.lines.map { $0.split(separator: " ")[1] }, ["ping", "bad"])
        XCTAssertEqual(ids.count == 2 ? ids[1] - ids[0] : 0, 1)
    }

    func testCommandsGoOneAtATime() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        async let a: String = channel.send("move 1 0")
        async let b: String = channel.send("move -1 0")
        _ = try await (a, b)
        XCTAssertEqual(board.lines.count, 2)
    }

    func testCancelledQueuedInputClaimNeverReachesTheBoard() async throws {
        let board = FakeBoard()
        board.silent = true
        let channel = CommandChannel(transport: board)
        board.channel = channel
        let first = Task { try await channel.send("ping") }
        while board.lines.isEmpty { await Task.yield() }
        let claim = Task { try await channel.send("v1 POST input/claim {}") }
        await Task.yield()
        claim.cancel()
        let id = try XCTUnwrap(board.lines.first?.split(separator: " ").first)
        channel.handleReply("\(id) ok")
        _ = try await first.value
        do { _ = try await claim.value; XCTFail("cancelled claim succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(board.lines.count, 1)
    }

    func testLinkDownFailsCommandsInFlight() async {
        let board = FakeBoard()
        board.silent = true
        let channel = CommandChannel(transport: board)
        board.channel = channel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            channel.linkDown()
        }
        do {
            try await channel.send("click")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disconnected"))
        }
    }

    func testReplyParsing() {
        XCTAssertEqual(BoardReply.parse("12 ok"), BoardReply(id: 12, ok: true, text: ""))
        XCTAssertEqual(BoardReply.parse("3 ok 812\n"), BoardReply(id: 3, ok: true, text: "812"))
        XCTAssertEqual(BoardReply.parse("4 err unknown command"), BoardReply(id: 4, ok: false, text: "unknown command"))
        XCTAssertNil(BoardReply.parse("ok"))
    }

    func testStatusDecoding() throws {
        let json = #"{"up":123456,"rst":"power-on","heap":81234,"psram":6200000,"usb":"ok","net":"ap","ip":"192.168.4.1","sta":1,"ap":"streaming","w":480,"h":1040,"kbps":180,"fps":4.8,"idr":2000,"gop":42000,"ble":{"mtu":247,"phy":2,"kbps":350,"drop":0}}"#
        let s = try XCTUnwrap(BoardStatus.decode(Data(json.utf8)))
        XCTAssertEqual(s.ap, "streaming")
        XCTAssertEqual(s.ble?.mtu, 247)
        XCTAssertEqual(s.fps, 4.8)
    }

    func testSelectedInputReadinessAndLegacyFirmware() throws {
        func status(_ json: String) throws -> BoardStatus {
            try XCTUnwrap(BoardStatus.decode(Data(json.utf8)))
        }
        XCTAssertTrue(try status(#"{"usb":"ok"}"#).inputReady)
        XCTAssertFalse(try status(#"{"usb":"off"}"#).inputReady)
        let bluetooth = try status(#"{"usb":"off","output":"bluetooth","hid":"ok"}"#)
        XCTAssertTrue(bluetooth.inputReady)
        // A live USB cable must not mask the selected Bluetooth target disconnecting.
        let disconnected = try status(#"{"usb":"ok","output":"bluetooth","hid":"off"}"#)
        XCTAssertFalse(bluetooth.merged(with: disconnected).inputReady)
        XCTAssertFalse(try status(#"{"usb":"ok","output":"bluetooth"}"#).inputReady)
        let compact = try status(#"{"up":2,"hid":"off","output":"bluetooth"}"#)
        XCTAssertEqual(bluetooth.merged(with: compact).output, "bluetooth")
        XCTAssertFalse(bluetooth.merged(with: compact).inputReady)
    }

    func testDistinctPointerGesturesUseTheCalibratedPathFromHome() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        try await pointer.point(0.5, 0.5)
        try await pointer.point(0.25, 0.75)
        try await pointer.point(0.5, 0.5)
        XCTAssertEqual(device.sent, ["release", "home", "move 200 400",
                                     "home", "move 100 600", "home", "move 200 400"])
    }

    func testRepeatedPointerTargetReusesItsKnownPosition() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        for _ in 0..<11 { try await pointer.point(0.5, 0.5) }
        try await pointer.point(0.5001, 0.5001)  // same rounded mouse coordinates
        XCTAssertEqual(device.sent, ["release", "home", "move 200 400"])
    }

    func testPointerDragStaysContinuousAndReanchorsItsEndpointForTheNextGesture() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.drag([CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
                                CGPoint(x: 0.75, y: 0.75)], hold: false)
        try await pointer.point(0.75, 0.75)
        try await pointer.point(0.75, 0.75)
        XCTAssertEqual(device.sent, ["release", "home", "move 100 200", "press",
                                     "move 100 200", "move 100 200", "release", "home", "move 300 600"])
    }

    func testPointerReconnectReleasesAndHomesEvenAtTheSameTarget() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.point(0.5, 0.5)
        device.links += 1
        try await pointer.point(0.5, 0.5)
        XCTAssertEqual(device.sent, ["release", "home", "move 200 400",
                                     "release", "home", "move 200 400"])
    }

    func testHomeUsesMappedButtonWithoutClickingAnAppControl() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.goHome()
        XCTAssertEqual(device.sent, ["button 4"])
        try await pointer.point(0.5, 0.5)
        XCTAssertEqual(device.sent.filter { $0 == "home" }.count, 1)
        try await pointer.goHome()
        try await pointer.point(0.5, 0.5)
        XCTAssertEqual(device.sent.filter { $0 == "home" }.count, 2)
    }

    func testShortStatusNotifyIsMergedWithTheFullRead() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":1,"heap":81234,"usb":"ok","net":"ap","sta":2,"ap":"idle","kbps":180,"ble":{"mtu":247,"phy":2}}"#.utf8)))
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":2,"usb":"asleep","net":"ap","ap":"streaming","ble":{"mtu":23}}"#.utf8)))
        let m = full.merged(with: short)
        XCTAssertEqual(m.up, 2)
        XCTAssertEqual(m.usb, "asleep")
        XCTAssertEqual(m.ap, "streaming")
        XCTAssertEqual(m.heap, 81234)  // kept from the full read
        XCTAssertEqual(m.sta, 2)
        XCTAssertEqual(m.ble?.mtu, 23)
        XCTAssertEqual(m.ble?.phy, 2)
    }

    func testFreshCalibrationHasNoDriftAndSurvivesARestart() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertFalse(pointer.calibrated)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertEqual(pointer.drift, 0)
        let again = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertEqual(again.span, Pointer.Span(w: 400, h: 800))
    }

    func testModelSettingsNeedOnlyAnEndpoint() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = Settings(defaults: defaults, info: nil)  // no build-time preset
        XCTAssertFalse(settings.isConfigured)  // nothing is built in
        settings.baseURL = "https://example.com/v1"
        XCTAssertTrue(settings.isConfigured)  // the model is picked from GET /models
        XCTAssertNil(settings.currentModel)
        settings.model = "some-model"
        XCTAssertEqual(settings.currentModel, "some-model")
    }

    func testProbeFitRecoversScaleAndOffset() {
        let samples: [(Double, Double)] = [150.0, 350, 60].map { u in (u, 0.02 + u / 400) }
        let line = ProbeFit.line(samples)
        XCTAssertEqual(line?.a ?? 0, 1 / 400, accuracy: 1e-9)
        XCTAssertEqual(line?.b ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(line?.rms ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(line?.units(for: 0.52), 200)
        XCTAssertNil(ProbeFit.line([(100, 0.3)]))
        XCTAssertFalse(ProbeFit.usable(0.995))  // stuck at the edge
    }
}
