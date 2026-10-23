import XCTest
@testable import IPhoneAgent

final class LocalVideoTests: XCTestCase {
    private func word(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8((n >> ($0 * 8)) & 255) } }
    private func batch(_ records: [(UInt32, UInt8, [UInt8])]) -> Data {
        var data = Array("S3VF".utf8) + word(7) + word(2) + word(UInt32(records.count))
        for (ms, flags, bytes) in records { data += word(ms) + word(UInt32(bytes.count)) + [flags] + bytes }
        return Data(data)
    }
    func testIncrementalCaptureTimestampsAndKeyFlags() throws {
        let data = batch([(100, 8, [0,0,1,0x67]), (101, 4, [0,0,1,0x65]), (200, 0, [0,0,1,0x41])])
        let decoded = try LocalVideoBatch(data)
        XCTAssertEqual(decoded.generation, 7); XCTAssertEqual(decoded.next, 2)
        XCTAssertTrue(decoded.units[0].config); XCTAssertTrue(decoded.units[1].idr)
        XCTAssertEqual(decoded.units.last?.boardMs, 200)
        XCTAssertEqual(decoded.units.last?.data, Data([0,0,1,0x41]))
    }
    func testEmptyIncrementDoesNotInventAFrame() throws {
        XCTAssertTrue(try LocalVideoBatch(batch([])).units.isEmpty)
    }
    func testTruncationInvalidFlagsAndTrailingBytesAreRejected() {
        let valid = batch([(100, 4, [0,0,1,0x65])])
        for count in 0..<valid.count { XCTAssertThrowsError(try LocalVideoBatch(valid.prefix(count))) }
        XCTAssertThrowsError(try LocalVideoBatch(valid + Data([0])))
        XCTAssertThrowsError(try LocalVideoBatch(batch([(100, 1, [1])])))
    }
    func testCredentialsAllowOnlyPrivateLocalAddresses() throws {
        func credentials(_ url: String) throws -> LocalVideoCredentials {
            try JSONDecoder().decode(LocalVideoCredentials.self, from: JSONEncoder().encode(["url": url, "token": "test"]))
        }
        XCTAssertTrue(try credentials("http://192.168.4.1").isLocal)
        XCTAssertTrue(try credentials("http://10.0.0.4").isLocal)
        for url in ["http://example.com", "http://8.8.8.8", "http://192.168.4.1@evil.test", "https://192.168.4.1", "http://192.168.4.1:8200"] {
            XCTAssertFalse(try credentials(url).isLocal)
        }
    }
    func testCPUDecoderReconstructsFixtureWithoutVideoToolbox() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "tiny", withExtension: "h264") else {
            return XCTFail("Missing H.264 fixture")
        }
        let decoder = SoftwareH264()
        var image: Data?
        for nal in annexBUnits(try Data(contentsOf: url)) {
            let unit = Data([0,0,0,1]) + nal
            if let decoded = decoder.decode(unit, timestamp: 123, jpegQuality: 0.75, emit: true) { image = decoded }
            XCTAssertEqual(decoder.lastStatus, 0)
        }
        XCTAssertNotNil(image); XCTAssertEqual(decoder.width, 32); XCTAssertEqual(decoder.height, 32)
        XCTAssertEqual(decoder.outputTimestamp, 123)
    }
    func testQuietHighProfileFramesReleaseDisplayReferencesAndKeepTimestamps() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "interframes", withExtension: "h264"))
        let nals = annexBUnits(try Data(contentsOf: url))
        let decoder = SoftwareH264()
        var frames = 0
        for nal in nals {
            let type = nal.first! & 31
            let isPicture = type == 1 || type == 5
            let timestamp = UInt64(1000 + frames * 100)
            let image = decoder.decode(Data([0,0,0,1]) + nal, timestamp: timestamp,
                                       jpegQuality: 0.6, emit: true)
            XCTAssertEqual(decoder.lastStatus, 0, "picture \(frames)")
            if isPicture {
                // Each quiet picture must be available without a later packet,
                // even after the decoder's reference pool would have filled.
                XCTAssertNotNil(image, "picture \(frames)")
                XCTAssertEqual(decoder.outputTimestamp, timestamp)
                frames += 1
            }
        }
        XCTAssertEqual(frames, 120)
        XCTAssertEqual(decoder.width, 64); XCTAssertEqual(decoder.height, 64)
    }
}
