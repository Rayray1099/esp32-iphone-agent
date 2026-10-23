import XCTest

final class ClickerUITests: XCTestCase {
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["clickerScroll"]
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let upward = !element.exists || element.frame.midY > scroll.frame.midY
            // The screenshot canvas handles drags. Scroll in the outer padding
            // so a test gesture cannot move a target instead of the page.
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upward ? 0.8 : 0.3))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: upward ? 0.3 : 0.8))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
    func testBulkDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-onboarded", "YES", "-sharePrivacyAsked", "YES", "-acceptedDisclaimer", "YES", "-AppleLanguages", "(zh-Hant)"]
        app.launch()
        let manage = app.buttons["manageProfiles"]
        XCTAssertTrue(manage.waitForExistence(timeout: 20))
        reveal(manage, in: app)
        XCTAssertTrue(manage.isHittable); manage.tap()
        let all = app.buttons["selectAllProfiles"]
        XCTAssertTrue(all.waitForExistence(timeout: 5)); reveal(all, in: app)
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
        reveal(addTarget, in: app)
        XCTAssertTrue(addTarget.isHittable)
        addTarget.tap()
        let fast = app.buttons["applyCPS"]
        reveal(fast, in: app)
        XCTAssertTrue(fast.isHittable)
        XCTAssertTrue(app.staticTexts["目標 2"].exists)
        fast.tap()
        screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "PULSE zh-TW target editor"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
