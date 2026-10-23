import XCTest
@testable import IPhoneAgent

final class ClickerTests: XCTestCase {
    func testScreenshotAspectAndTargetMapping() {
        for image in [CGSize(width: 440, height: 956), CGSize(width: 956, height: 440), CGSize(width: 768, height: 1024)] {
            for width in [CGFloat(320), 400, 794] {
                let size = TargetCanvasGeometry.size(image: image, landscape: false, availableWidth: width, maximumHeight: 430)
                XCTAssertEqual(size.width / size.height, image.width / image.height, accuracy: 0.00001)
                XCTAssertLessThanOrEqual(size.width, width)
                XCTAssertLessThanOrEqual(size.height, 430.001)
                let center = TargetCanvasGeometry.normalized(CGPoint(x: size.width / 2, y: size.height / 2), in: size)
                XCTAssertEqual(center.x, 5000); XCTAssertEqual(center.y, 5000)
                let edge = TargetCanvasGeometry.normalized(CGPoint(x: -40, y: size.height + 40), in: size)
                XCTAssertEqual(edge.x, 0); XCTAssertEqual(edge.y, 10000)
            }
        }
    }
    func testProfileRoundTripAndBounds() throws {
        var profile = ClickProfile()
        profile.points = (0..<1000).map { i in ClickTarget(x: i, y: 10000-i, press_us: 1, delay_us: 1) }
        try profile.validate()
        let decoded = try JSONDecoder().decode(ClickProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.points.count, 1000)
        XCTAssertEqual(decoded.points[999].x, 999)
        profile.points.append(ClickTarget())
        XCTAssertThrowsError(try profile.validate())
        profile.points = [ClickTarget(press_us: 0)]
        XCTAssertThrowsError(try profile.validate())
        profile.points = [ClickTarget(enabled: false)]
        XCTAssertThrowsError(try profile.validate())
        profile = ClickProfile();profile.device = "../bad"
        XCTAssertThrowsError(try profile.validate())
        profile.device = "my-ipad";try profile.validate()
        profile.schema = 2
        XCTAssertThrowsError(try profile.validate())
    }
    func testCompactStatusAndTraditionalChineseResources() throws {
        let raw = #"{"running":true,"releasing":false,"clicks":300,"loops":300,"active":1,"point":0,"late":0,"output_cps":43.7,"requested_cps":50,"output":"bluetooth","mouse_connected":true,"profile":"遊戲連點","network":"off"}"#
        let status = try JSONDecoder().decode(ClickerRunStatus.self, from: Data(raw.utf8))
        XCTAssertEqual(status.output_cps, 43.7)
        XCTAssertTrue(status.mouse_connected)
        XCTAssertEqual(status.profile, "遊戲連點")
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"))
        XCTAssertFalse(bundle.isEmpty)
    }
    @MainActor func testTransferCRC() {
        XCTAssertEqual(ClickerClient.crc32(Data("123456789".utf8)), 0xcbf43926)
    }
}
