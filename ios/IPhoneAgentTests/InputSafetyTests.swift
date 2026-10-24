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
        XCTAssertEqual(EnglishInput.layout(["is you and just I'm good s", "注"]), .zhuyin)
        XCTAssertEqual(EnglishInput.layout(["you", "are", "quite", "right"]), .unknown)
        XCTAssertEqual(EnglishInput.layout(["繁體手寫"]), .other)
        XCTAssertEqual(EnglishInput.layout(["搜尋", "ㄅ"]), .unknown)
        XCTAssertEqual(EnglishInput.layout([]), .unknown)
    }

    func testKeyboardOCRFromCroppedPhysicalPhoneFixtures() async throws {
        let bundle = Bundle(for: Self.self)
        for name in ["english-keyboard", "mirrored-english-keyboard", "zhuyin-keyboard", "english-source-menu"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jpg"))
            let actual = await EnglishInput.read(try Data(contentsOf: url), diagnostic: { print("OCR fixture \(name): \($0)") })
            // Ambiguous Bopomofo key caps must never be accepted as English.
            if name == "zhuyin-keyboard" { XCTAssertNotEqual(actual, .english, name) }
            else { XCTAssertEqual(actual, .english, name) }
        }
    }

    func testMirroredKeyboardCropKeepsKeyPixelsAndMapsBackToFullFrame() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mirrored-english-keyboard", withExtension: "jpg"))
        let image = try XCTUnwrap(Vision.image(Data(contentsOf: url)))
        let crop = try XCTUnwrap(EnglishInput.keyboardImage(image))
        XCTAssertEqual(crop.image.width, 440)
        XCTAssertEqual(Double(crop.image.height) / Double(crop.image.width), Double(image.height) * crop.fraction / Double(image.width), accuracy: 0.003)
        XCTAssertEqual(crop.fraction, 0.45, accuracy: 0.001)
        // The bottom of both images remains the same coordinate origin.
        let gray = Vision.gray(crop.image, 44, 90)
        XCTAssertGreaterThan(Set(gray.px).count, 40)
    }

    func testSparseRealKeyObservationsFitStaggeredQwertyRows() {
        let keys: [(String, Double, Double)] = [("w", 0.157, 0.284), ("e", 0.252, 0.284),
            ("t", 0.452, 0.286), ("a", 0.105, 0.225), ("s", 0.202, 0.225), ("d", 0.300, 0.228),
            ("h", 0.598, 0.227), ("j", 0.693, 0.225), ("k", 0.793, 0.227),
            ("x", 0.302, 0.166), ("v", 0.498, 0.166), ("b", 0.595, 0.169), ("n", 0.695, 0.166), ("m", 0.793, 0.166)]
        let words = keys.map { EnglishInput.Word(text: $0.0, box: CGRect(x: $0.1 - 0.02, y: $0.2 - 0.01, width: 0.04, height: 0.02)) }
        XCTAssertTrue(EnglishInput.qwertyGrid(words, aspect: 440.0 / 956))
        XCTAssertFalse(EnglishInput.qwertyGrid(words.map { .init(text: $0.text, box: CGRect(x: $0.box.minX, y: 0.2, width: 0.04, height: 0.02)) }, aspect: 440.0 / 956))
    }

    func testEnglishMenuLabelRequiresItsOwnHighlight() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-source-menu", withExtension: "jpg"))
        let image = try XCTUnwrap(Vision.image(Data(contentsOf: url)))
        let selected = EnglishInput.Word(text: "English (US)", box: CGRect(x: 0.345, y: 0.484, width: 0.305, height: 0.028))
        XCTAssertEqual(EnglishInput.classify([selected], image: image), .english)
        let unselected = EnglishInput.Word(text: "English (US)", box: CGRect(x: 0.345, y: 0.589, width: 0.305, height: 0.028))
        XCTAssertNotEqual(EnglishInput.classify([unselected], image: image), .english)
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

    func testActualPointerSearchOrdersFocusClearAndTypeWithoutSubmitting() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-keyboard", withExtension: "jpg"))
        let screen = FakeScreen()
        screen.frame = try Data(contentsOf: url)
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), screen: screen)
        try await pointer.search("Weather")
        XCTAssertEqual(device.sent, ["key cmd+space", "key cmd+a", "key backspace", "type Weather"])
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
