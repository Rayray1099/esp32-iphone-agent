import XCTest
@testable import IPhoneAgent

final class ClickerTests: XCTestCase {
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
    @MainActor func testTransferCRC() {
        XCTAssertEqual(ClickerClient.crc32(Data("123456789".utf8)), 0xcbf43926)
    }
}
