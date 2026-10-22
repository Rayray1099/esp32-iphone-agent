import XCTest

final class ClickerUITests: XCTestCase {
    func testOfflineEditorOnPhoneAndTablet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-onboarded", "YES", "-sharePrivacyAsked", "YES", "-acceptedDisclaimer", "YES", "-AppleLanguages", "(zh-Hant)"]
        app.launch()
        XCTAssertTrue(app.otherElements["clickerDashboard"].waitForExistence(timeout: 20) || app.staticTexts["liveCPS"].exists)
        XCTAssertTrue(app.staticTexts["43.7"].exists)
        XCTAssertTrue(app.buttons["startClicker"].exists)
        XCTAssertTrue(app.buttons["stopClicker"].exists)
        var screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "PULSE zh-TW dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.segmentedControls["clickerPages"].buttons["編輯目標"].tap()
        let addTarget = app.buttons["addTarget"]
        for _ in 0..<5 { if addTarget.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addTarget.isHittable)
        addTarget.tap()
        let fast = app.buttons["applyCPS"]
        for _ in 0..<8 { if fast.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(fast.isHittable)
        XCTAssertTrue(app.staticTexts["目標 2"].exists)
        fast.tap()
        screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "PULSE zh-TW target editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
