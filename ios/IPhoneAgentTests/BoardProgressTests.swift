import XCTest
@testable import IPhoneAgent

final class BoardProgressTests: XCTestCase {
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
