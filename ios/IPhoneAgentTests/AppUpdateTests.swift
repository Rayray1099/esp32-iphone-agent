import CryptoKit
import XCTest
@testable import IPhoneAgent

final class AppUpdateTests: XCTestCase {
    private let bundleID = "com.example.esp32agent"
    private let url = "https://github.com/Rayray1099/esp32-iphone-agent/releases/download/ios-latest/ESP32-Agent-build13.ipa"
    private let payload = Data("fixture IPA bytes".utf8)

    private func manifest(changes: [String: Any] = [:]) throws -> AppUpdateManifest {
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let values: [String: Any] = ["bundleID": bundleID, "version": "1.1", "build": 13,
                                     "url": url, "bytes": payload.count, "sha256": hash, "notes": "測試"]
        return try JSONDecoder().decode(AppUpdateManifest.self, from: JSONSerialization.data(withJSONObject:
            values.merging(changes, uniquingKeysWith: { _, changed in changed })))
    }

    func testOnlyNewerMatchingBundleIsOffered() throws {
        let update = try manifest()
        XCTAssertNoThrow(try update.validate(bundleID: bundleID))
        XCTAssertTrue(update.isNewer(than: 12))
        XCTAssertFalse(update.isNewer(than: 13))
        XCTAssertFalse(update.isNewer(than: 14))
        XCTAssertThrowsError(try update.validate(bundleID: "other.app"))
        XCTAssertEqual(update.filename, "ESP32-Agent-build13.ipa")
    }

    func testRejectsUntrustedURLsAndInvalidMetadata() throws {
        for badURL in ["http://github.com/Rayray1099/esp32-iphone-agent/releases/download/v13/app.ipa",
                       "https://evil.test/app.ipa",
                       "https://github.com/other/repo/releases/download/v13/app.ipa",
                       "https://github.com/Rayray1099/esp32-iphone-agent/releases/download/v13/app.bin",
                       "https://user@github.com/Rayray1099/esp32-iphone-agent/releases/download/v13/app.ipa"] {
            XCTAssertThrowsError(try manifest(changes: ["url": badURL]).validate(bundleID: bundleID))
        }
        let invalidMetadata: [[String: Any]] = [["build": 0], ["bytes": 0], ["bytes": 101 * 1024 * 1024],
                                               ["sha256": "bad"], ["sha256": String(repeating: "z", count: 64)]]
        for change in invalidMetadata {
            XCTAssertThrowsError(try manifest(changes: change).validate(bundleID: bundleID))
        }
    }

    func testDownloadMustMatchSizeAndHashBeforeSharing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let update = try manifest()
        try payload.write(to: file)
        XCTAssertNoThrow(try update.verify(file))
        try payload.dropLast().write(to: file)
        XCTAssertThrowsError(try update.verify(file))
        var corrupt = payload; corrupt[0] ^= 1
        try corrupt.write(to: file)
        XCTAssertThrowsError(try update.verify(file))
    }
}
