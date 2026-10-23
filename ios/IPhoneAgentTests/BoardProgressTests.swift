import XCTest
@testable import IPhoneAgent

final class BoardProgressTests: XCTestCase {
    func testPublicSummaryIsBoundedUnicodeAndSingleLine() {
        let cleaned = BoardAgentProgress.cleanSummary("檢查鬧鐘\n時間\u{202e}😀")
        XCTAssertEqual(cleaned, "檢查鬧鐘 時間")
        let long = BoardAgentProgress.cleanSummary(String(repeating: "臺", count: 80))
        XCTAssertEqual(long.utf8.count, 90)
        XCTAssertEqual(long.count, 30)
        let progress = BoardAgentProgress(run: 123, summary: long)
        XCTAssertTrue(progress.line(at: 1).contains(" |" + long))
        XCTAssertLessThan(progress.line(at: 1).utf8.count, 200)
    }
    func testSummaryDoesNotFallBackToPrivateThoughtOrTypedContent() throws {
        let acts = try Actions.parseActions("THINK: private diagnostic text\nSTATUS: 檢查鬧鐘時間\nDO: type secret")
        XCTAssertEqual(acts[0]["status_zh"]?.str, "檢查鬧鐘時間")
        XCTAssertNil(Actions.key(acts[0])["status_zh"])
        XCTAssertNil(try Actions.parseActions("THINK: private\nDO: tap 10 20")[0]["status_zh"])
    }
    @MainActor func testDifferentTasksAndMultiActionRoundsKeepTheirOwnSummary() {
        let app = AppModel()
        app.boardProgress.run = 123
        for text in ["計算數字並檢查結果", "檢查鬧鐘時間", "尋找相簿照片", "繪製下一條線"] {
            app.showBoardDoing(.acting(["action": .str("tap"), "status_zh": .str(text)]))
            XCTAssertEqual(app.boardProgress.summary, text)
            app.showBoardDoing(.acting(["action": .str("key")]))
            XCTAssertEqual(app.boardProgress.summary, text)
            app.showBoardDoing(.waiting)
            XCTAssertEqual(app.boardProgress.summary, text)
        }
        app.setBoardProgress("done", action: "Completed")
        XCTAssertEqual(app.boardProgress.summary, "已確認任務完成")
    }
    func testTelemetryIsCompactAndContainsOnlyFixedFields() {
        let progress = BoardAgentProgress(run: 123, phase: "acting", action: "Tap", step: 3,
                                           limit: 40, started: 10, frameMs: 400, modelMs: 5000, hidMs: 120)
        XCTAssertEqual(progress.line(at: 20), "@agent 123 acting 3 40 400 5000 120 10 Tap")
        XCTAssertLessThan(progress.line(at: 20).utf8.count, 100)
    }
    @MainActor func testMetricsStepCounterRestartsForEachRun() {
        let metrics = Metrics()
        metrics.step(.init()); metrics.step(.init())
        XCTAssertEqual(metrics.runStepCount, 2)
        metrics.beginRun()
        XCTAssertTrue(metrics.steps.isEmpty)
        metrics.step(.init())
        XCTAssertEqual(metrics.runStepCount, 1)
    }
}
