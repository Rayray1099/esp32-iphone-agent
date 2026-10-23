import XCTest

final class ClickerUITests: XCTestCase {
    func testBulkDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-onboarded", "YES", "-sharePrivacyAsked", "YES", "-acceptedDisclaimer", "YES", "-AppleLanguages", "(zh-Hant)"]
        app.launch()
        let manage = app.buttons["manageProfiles"]
        XCTAssertTrue(manage.waitForExistence(timeout: 20))
        for _ in 0..<6 { if manage.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(manage.isHittable); manage.tap()
        let all = app.buttons["selectAllProfiles"]
        XCTAssertTrue(all.isHittable); all.tap()
        let delete = app.buttons["deleteSelectedProfiles"]
        XCTAssertTrue(delete.isEnabled); delete.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let cancel = confirmation.buttons["取消"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.buttons["savedProfile-3"].exists)
        XCTAssertTrue(app.buttons["savedProfile-4"].exists)
        delete.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["刪除 2 個腳本"].tap()
        let removed = NSPredicate(format: "exists == false")
        expectation(for: removed, evaluatedWith: app.buttons["savedProfile-3"])
        expectation(for: removed, evaluatedWith: app.buttons["savedProfile-4"])
        waitForExpectations(timeout: 10)
    }
    func testScreenshotAspect() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-target-portrait-fixture", "-onboarded", "YES", "-sharePrivacyAsked", "YES", "-acceptedDisclaimer", "YES", "-AppleLanguages", "(zh-Hant)"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["clickerPages"].waitForExistence(timeout: 20))
        app.segmentedControls["clickerPages"].buttons["編輯目標"].tap()
        let image = app.images["targetScreenshot"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertEqual(image.frame.width / image.frame.height, 440.0 / 956, accuracy: 0.01)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Screenshot kept at original aspect"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testOfflineEditorOnPhoneAndTablet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-onboarded", "YES", "-sharePrivacyAsked", "YES", "-acceptedDisclaimer", "YES", "-AppleLanguages", "(zh-Hant)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["liveCPS"].waitForExistence(timeout: 20))
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
