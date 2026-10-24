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

    func testBrightTranslucentUnselectedMenuRowIsNotASelection() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-source-menu", withExtension: "jpg"))
        let image = try XCTUnwrap(Vision.image(Data(contentsOf: url)))
        // The bright wallpaper behind this bottom row used to pass both vertical
        // comparisons. It has no selection pill edge around its label.
        let japanese = EnglishInput.Word(text: "日本語手書き", box: CGRect(x: 0.35, y: 0.381, width: 0.32, height: 0.027))
        XCTAssertEqual(EnglishInput.classify([japanese], image: image, hardwareSource: true), .unknown)
        let english = EnglishInput.Word(text: "English (US)", box: CGRect(x: 0.3499, y: 0.483, width: 0.3002, height: 0.0298))
        XCTAssertEqual(EnglishInput.classify([japanese, english], image: image, hardwareSource: true), .english)
    }

    func testSourceCropMapsMenuLabelsBackToTheirHighlightPixels() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-source-menu", withExtension: "jpg"))
        let image = try XCTUnwrap(Vision.image(Data(contentsOf: url)))
        let source = try XCTUnwrap(EnglishInput.sourceImage(image))
        XCTAssertLessThan(source.image.width * source.image.height, image.width * image.height / 2)
        let selected = CGRect(x: 0.345, y: 0.484, width: 0.305, height: 0.028)
        let local = EnglishInput.Word(text: "English (US)", box: CGRect(
            x: (selected.minX - source.box.minX) / source.box.width,
            y: (selected.minY - source.box.minY) / source.box.height,
            width: selected.width / source.box.width, height: selected.height / source.box.height))
        let mapped = source.fullFrame(local)
        XCTAssertEqual(mapped.box.minX, selected.minX, accuracy: 0.000001)
        XCTAssertEqual(mapped.box.minY, selected.minY, accuracy: 0.000001)
        XCTAssertEqual(EnglishInput.classify([mapped], image: image, hardwareSource: true), .english)
    }

    func testHardwareSourceOCRFromCroppedMenu() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-source-menu", withExtension: "jpg"))
        let actual = await EnglishInput.read(try Data(contentsOf: url), hardwareSource: true)
        XCTAssertEqual(actual, .english)
    }

    func testUnknownKeyboardCyclesToConfirmedEnglishWithoutTypingProbeText() async throws {
        let device = FakeDevice()
        var observations: [EnglishInput.Layout] = [.zhuyin, .other, .english]
        var freshChecks = 0
        try await EnglishInput.ensure(device: device, observe: { observations.removeFirst() },
                                      changed: { _ in freshChecks += 1 }, log: { _ in })
        XCTAssertEqual(device.sent, Array(repeating: "source next", count: 3) + ["source release"])
        XCTAssertEqual(freshChecks, 4) // three pending choices, then the committed release
        XCTAssertTrue(observations.isEmpty)
    }

    func testUnrecognizedKeyboardFailsAfterTwoBoundedCycles() async {
        let device = FakeDevice()
        do {
            try await EnglishInput.ensure(device: device, observe: { .unknown }, changed: { _ in }, log: { _ in })
            XCTFail("Unknown input source was accepted")
        } catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertEqual(device.sent, Array(repeating: "source next", count: 12) + ["source release"])
        XCTAssertFalse(device.sent.contains(where: { $0.hasPrefix("type ") }))
    }

    func testEnglishHardwareSourceAlwaysOpensAndReleasesSelector() async throws {
        let device = FakeDevice()
        var checkedCommands: [String] = []
        try await EnglishInput.ensure(device: device, observe: { .english },
                                      changed: { _ in checkedCommands.append(device.sent.last!) }, log: { _ in })
        XCTAssertEqual(device.sent, ["source next", "source release"])
        XCTAssertEqual(checkedCommands, ["source next", "source release"])
    }

    func testSelectedEnglishCannotProceedWithoutAFreshReleaseFrame() async {
        let device = FakeDevice()
        do {
            try await EnglishInput.ensure(device: device, observe: { .english }, changed: { _ in
                if device.sent.last == "source release" { throw BlindError() }
            }, log: { _ in })
            XCTFail("A pending English choice was accepted without its committed frame")
        } catch { XCTAssertTrue(error is BlindError) }
        XCTAssertEqual(device.sent, ["source next", "source release", "source release"])
        XCTAssertFalse(device.sent.contains(where: { $0.hasPrefix("type ") }))
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
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-source-menu", withExtension: "jpg"))
        let screen = FakeScreen()
        screen.frame = try Data(contentsOf: url)
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), screen: screen)
        try await pointer.search("Weather")
        XCTAssertEqual(device.sent, ["key cmd+space", "source next", "source release", "key cmd+a", "key backspace", "type Weather"])
    }

    func testQwertyPixelsCannotConfirmTheHardwareSource() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-keyboard", withExtension: "jpg"))
        let actual = await EnglishInput.read(try Data(contentsOf: url), hardwareSource: true)
        XCTAssertEqual(actual, .unknown)
    }

    func testMissedFirstSourceFrameCyclesAgainBeforeObservingConfirmedEnglish() async throws {
        let device = FakeDevice()
        var checks = 0, observations = 0
        var messages: [String] = []
        try await EnglishInput.ensure(device: device, observe: {
            observations += 1
            return .english
        }, changed: { _ in
            checks += 1
            if checks == 1 { throw BlindError() }
        }, log: { messages.append($0) })
        XCTAssertEqual(device.sent, ["source next", "source next", "source release"])
        XCTAssertEqual(checks, 3) // Missed menu, fresh menu, then fresh release.
        XCTAssertEqual(observations, 1)
        XCTAssertTrue(messages.contains(where: { $0.contains("missed fresh menu frame") }))
    }

    func testAllMissedSourceFramesAreBoundedWithoutOCRAndReleaseControl() async {
        let device = FakeDevice()
        var observations = 0
        do {
            try await EnglishInput.ensure(device: device, observe: {
                observations += 1
                return .english
            }, changed: { _ in throw BlindError() }, log: { _ in })
            XCTFail("Missing frame was accepted")
        } catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertEqual(observations, 0)
        XCTAssertEqual(device.sent, Array(repeating: "source next", count: 12) + ["source release"])
    }

    func testSourceFrameCancellationIsNotRetried() async {
        let device = FakeDevice()
        let selection = Task {
            try await EnglishInput.ensure(device: device, observe: {
                XCTFail("Cancelled selection reached OCR")
                return .english
            }, changed: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw BlindError()
            }, log: { _ in })
        }
        do { try await selection.value; XCTFail("Cancelled selection succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(device.sent, ["source next", "source release"])
    }

    func testSourceFrameDeviceErrorIsNotRetried() async {
        let device = FakeDevice()
        do {
            try await EnglishInput.ensure(device: device, observe: {
                XCTFail("Failed source capture reached OCR")
                return .english
            }, changed: { _ in throw DeviceError(message: "capture device failed") }, log: { _ in })
            XCTFail("Device failure was accepted")
        } catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertEqual(device.sent, ["source next", "source release"])
    }

    func testSourceCommandFailureIsNotRetried() async {
        @MainActor final class FailingSourceDevice: HIDDevice {
            let links = 1, connected = true
            var sent: [String] = []
            func waitConnected(_ timeout: TimeInterval) async -> Bool { true }
            func send(_ command: String) async throws -> String {
                sent.append(command)
                if command == "source next" { throw DeviceError(message: "HID submission failed") }
                return "ok"
            }
        }
        let device = FailingSourceDevice()
        do {
            try await EnglishInput.ensure(device: device, observe: {
                XCTFail("Failed HID command reached OCR")
                return .english
            }, changed: { _ in XCTFail("Failed HID command checked freshness") }, log: { _ in })
            XCTFail("Failed HID command was accepted")
        } catch { XCTAssertTrue(error is DeviceError) }
        XCTAssertEqual(device.sent, ["source next", "source release"])
    }

    func testSearchUsesSourceFreshnessOnlyForSelectorAndRelease() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "english-source-menu", withExtension: "jpg"))
        let screen = SourceFreshnessScreen(frame: try Data(contentsOf: url))
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), screen: screen)
        try await pointer.search("Weather")
        XCTAssertEqual(screen.gestures, 1) // Spotlight focus still uses normal gesture recovery.
        XCTAssertEqual(screen.sourceChanges, 2) // Choice and Control release both require freshness.
        XCTAssertEqual(device.sent, ["key cmd+space", "source next", "source release", "key cmd+a", "key backspace", "type Weather"])
    }

    func testSourceFreshnessStartsAfterTheHIDReplyRatherThanBeforeDelivery() async throws {
        let device = SourceTimingDevice()
        var cutoffs: [Double] = []
        try await EnglishInput.ensure(device: device, observe: { .english },
                                      changed: { cutoffs.append($0) }, log: { _ in })
        XCTAssertEqual(cutoffs.count, 2)
        XCTAssertEqual(device.repliedAt.count, 2)
        for (cutoff, reply) in zip(cutoffs, device.repliedAt) { XCTAssertGreaterThanOrEqual(cutoff, reply) }
    }

    func testKeyboardFastWaitRejectsAFrameCapturedBeforeTheSourceChange() async throws {
        let device = FakeDevice()
        let feed = VideoFeed()
        feed.device = device; feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 440, height: 956)
        let ready = try await feed.waitForKeyboardSourceFrame(since: now(), timeout: 0.06)
        XCTAssertFalse(ready)
        XCTAssertTrue(device.sent.isEmpty) // The fast wait itself must not move/click/type.
    }

    func testKeyboardFastWaitRejectsAFrameCapturedAtTheHIDReply() async throws {
        let device = FakeDevice()
        let feed = VideoFeed()
        feed.device = device; feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 440, height: 956)
        let ready = try await feed.waitForKeyboardSourceFrame(since: feed.capturedAt, timeout: 0.06)
        XCTAssertFalse(ready)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testKeyboardSourceAcceptsTheOnlyTransientFrameSoonAfterTheHIDReply() async throws {
        let device = FakeDevice()
        let feed = VideoFeed()
        feed.device = device; feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 440, height: 956)
        let reply = feed.capturedAt - 0.05  // The menu was captured 50 ms after the reply, then stays quiet.
        try await feed.afterKeyboardSource(since: reply)
        XCTAssertLessThan(feed.capturedAt, reply + 0.2)
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testKeyboardSourceTimeoutDoesNotEnterQuietRecoveryOrMoveThePointer() async throws {
        let device = FakeDevice()
        let feed = VideoFeed()
        feed.device = device; feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 440, height: 956)
        do {
            try await feed.afterKeyboardSource(since: now())
            XCTFail("A stale source frame was accepted")
        } catch { XCTAssertTrue(error is BlindError) }
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testKeyboardSourceSnapModeCapturesDirectlyWithoutQuietRecoveryOrPointerMoves() async throws {
        let savedMode = UserDefaults.standard.object(forKey: FrameMode.key)
        let savedFallback = FrameMode.fallback
        defer {
            UserDefaults.standard.set(savedMode, forKey: FrameMode.key)
            FrameMode.fallback = savedFallback
        }
        FrameMode.current = .snap
        let device = FakeDevice()
        let feed = VideoFeed()
        feed.device = device; feed.mirroring = true
        let reply = now()
        let capture = Task { @MainActor in
            while !device.sent.contains("snap") {
                if Task.isCancelled { return }
                await Task.yield()
            }
            feed.show(Data([0xff, 0xd8]), width: 440, height: 956)
        }
        defer { capture.cancel() }
        try await feed.afterKeyboardSource(since: reply)
        XCTAssertGreaterThan(feed.capturedAt, reply)
        XCTAssertEqual(device.sent, ["snap"])
    }

    func testKeyboardFastWaitDoesNotWaitForWholeScreenQuiet() async throws {
        let device = FakeDevice()
        let feed = VideoFeed()
        feed.device = device; feed.mirroring = true
        let began = now()
        var updatesFinished = false
        let updates = Task { @MainActor in
            for _ in 0..<40 {
                if Task.isCancelled { return }
                feed.show(Data([0xff, 0xd8]), width: 440, height: 956)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            updatesFinished = true
        }
        defer { updates.cancel() }
        let ready = try await feed.waitForKeyboardSourceFrame(since: began, timeout: 1.2)
        XCTAssertTrue(ready)
        XCTAssertGreaterThan(feed.capturedAt, began)
        XCTAssertFalse(updatesFinished) // Continuous cursor frames no longer force a quiet window.
        XCTAssertTrue(device.sent.isEmpty)
    }

    func testKeyboardFastWaitPropagatesCancellation() async {
        let feed = VideoFeed()
        let wait = Task { try await feed.waitForKeyboardSourceFrame(since: now()) }
        wait.cancel()
        do { _ = try await wait.value; XCTFail("Cancelled source capture was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
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

@MainActor private final class SourceFreshnessScreen: ScreenSource {
    let live = true
    let frame: Data?
    let updated = 0.0, capturedAt = 0.0, aspect = 0.46
    var gestures = 0, sourceChanges = 0
    init(frame: Data) { self.frame = frame }
    func afterAction(since: Double) async throws { gestures += 1 }
    func afterKeyboardSource(since: Double) async throws { sourceChanges += 1 }
}

@MainActor private final class SourceTimingDevice: HIDDevice {
    let links = 1, connected = true
    var repliedAt: [Double] = []
    func send(_ command: String) async throws -> String {
        try await Task.sleep(nanoseconds: 20_000_000)
        repliedAt.append(now())
        return "ok"
    }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { true }
}
