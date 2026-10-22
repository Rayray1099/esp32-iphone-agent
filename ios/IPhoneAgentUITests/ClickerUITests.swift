import XCTest

final class ClickerUITests: XCTestCase {
    func testOfflineEditorOnPhoneAndTablet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-onboarded", "YES", "-sharePrivacyAsked", "YES", "-acceptedDisclaimer", "YES"]
        app.launch()
        let clicker = app.buttons["Clicker"]
        XCTAssertTrue(clicker.waitForExistence(timeout: 20))
        clicker.tap()
        XCTAssertTrue(app.buttons["Add target"].waitForExistence(timeout: 10))
        app.buttons["Add target"].tap()
        XCTAssertTrue(app.staticTexts["Target 2"].exists || app.staticTexts["Target 2"].waitForExistence(timeout: 2))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Offline clicker editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let fast = app.buttons["Set fast repeat timing"]
        for _ in 0..<8 { if fast.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(fast.isHittable)
        fast.tap()
    }
}
