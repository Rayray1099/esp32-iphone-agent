import Foundation

struct ClickTarget: Codable, Equatable, Identifiable {
    var id = UUID()
    var x = 5000, y = 5000
    var press_us = 1000, delay_us = 5000
    var enabled = true
    enum CodingKeys: String, CodingKey { case x, y, press_us, delay_us, enabled }
}

struct ClickProfile: Codable, Equatable {
    var schema = 1
    var name = "My click sequence"
    var repeats = 0
    var landscape = false
    var fast = false
    var points = [ClickTarget()]

    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= 48, (1...1000).contains(points.count),
              (0...1_000_000_000).contains(repeats), points.contains(where: { $0.enabled }),
              points.allSatisfy({ (0...10000).contains($0.x) && (0...10000).contains($0.y) &&
                  (1...3_600_000_000).contains($0.press_us) && (1...3_600_000_000).contains($0.delay_us) })
        else { throw DeviceError(message: "Use a name up to 48 bytes, 1–1000 targets, coordinates 0–10000 and positive microsecond timings.") }
    }
}

@MainActor struct ClickerClient {
    let channel: CommandChannel

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = .max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }

    func request(_ path: String, method: String = "GET", object: [String: Any]? = nil) async throws -> String {
        var command = "v1 \(method) \(path)"
        if let object { command += " " + String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        return try await channel.send(command)
    }

    func upload(_ data: Data, path: String, progress: (Double) -> Void) async throws {
        guard data.count <= 196608 else { throw DeviceError(message: "Profile or certificate exceeds board transfer limit.") }
        let id = UUID().uuidString
        guard (channel.transport?.maxWrite ?? 0) >= 200 else { throw DeviceError(message: "Wait for BLE MTU negotiation, or use the hotspot controller for this upload.") }
        _ = try await request("transfer/begin", method: "POST", object: ["id": id, "path": path, "size": data.count, "crc32": Self.crc32(data)])
        // Fit the negotiated ATT payload, including request id and JSON/base64 overhead.
        let room = max(1, min(144, ((channel.transport?.maxWrite ?? 180) - 130) / 4 * 3))
        var offset = 0
        while offset < data.count {
            let end = min(offset + room, data.count)
            _ = try await request("transfer/chunk", method: "POST", object: ["id": id, "offset": offset, "data": data[offset..<end].base64EncodedString()])
            offset = end
            progress(Double(offset) / Double(data.count))
        }
        _ = try await request("transfer/commit", method: "POST", object: ["id": id])
    }

    func save(_ profile: ClickProfile, slot: Int, progress: (Double) -> Void) async throws {
        try profile.validate()
        try await upload(JSONEncoder().encode(profile), path: "profiles/\(slot)", progress: progress)
    }

    func start(slots: [Int], nonce: String = UUID().uuidString) async throws {
        guard (1...16).contains(slots.count), slots.allSatisfy({ (0..<32).contains($0) }) else {
            throw DeviceError(message: "Choose 1–16 profile slots from 0 to 31.")
        }
        _ = try await request("run/start", method: "POST", object: ["profiles": slots, "nonce": nonce])
    }
}
