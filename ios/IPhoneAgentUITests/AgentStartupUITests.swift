import XCTest

final class AgentStartupUITests: XCTestCase {
    private func launch(failing: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mock", "-mock-startup-delay", "-agent-startup-fixture", "-onboarded", "YES", "-sharePrivacyAsked", "YES",
                               "-acceptedDisclaimer", "YES", "-askedNotifications", "YES", "-AppleLanguages", "(zh-Hant)"]
        if failing { app.launchArguments.append("-mock-startup-failure") }
        app.launch()
        XCTAssertTrue(app.buttons["startAgent"].waitForExistence(timeout: 20))
        app.buttons["startAgent"].tap()
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.element(boundBy: 1).tap() }
        return app
    }

    func testCancelPreparationDoesNotStartLater() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["startupStage"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Preparing is explicit and cancellable"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["stopAgent"].tap()
        XCTAssertTrue(app.staticTexts["已停止・啟動已取消"].waitForExistence(timeout: 5))
        // Beyond the simulated video wait, a cancelled startup must still be stopped.
        let running = app.staticTexts["AI 執行中"]
        let neverRuns = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: running)
        XCTAssertEqual(XCTWaiter.wait(for: [neverRuns], timeout: 4), .timedOut)
        XCTAssertTrue(app.buttons["startAgent"].isEnabled)
    }

    func testUnavailableVideoLeavesPersistentFailureAndRetry() {
        let app = launch(failing: true)
        XCTAssertTrue(app.staticTexts["啟動失敗・尚未執行"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["startAgent"].isEnabled)
        XCTAssertFalse(app.staticTexts["AI 執行中"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Missing source video explains recovery"; shot.lifetime = .keepAlways; add(shot)
    }
}
