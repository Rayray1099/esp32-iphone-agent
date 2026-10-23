import Foundation

/// Bounded incremental video response. Unit boundaries and capture times survive Wi-Fi.
struct LocalVideoBatch {
    let generation: UInt32, next: UInt32
    let units: [AccessUnit]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        func word(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        }
        guard bytes.count >= 16, bytes.count <= 5 * 1024 * 1024,
              Array(bytes.prefix(4)) == Array("S3VF".utf8) else { throw DeviceError(message: "Invalid local video header") }
        generation = word(4); next = word(8)
        let count = Int(word(12))
        guard count <= 8193, next <= 8192 else { throw DeviceError(message: "Invalid local video count") }
        var pos = 16, result: [AccessUnit] = []
        for _ in 0..<count {
            guard bytes.count - pos >= 9 else { throw DeviceError(message: "Truncated local video record") }
            let ms = word(pos), size = Int(word(pos + 4)), flags = bytes[pos + 8]
            pos += 9
            guard size > 0, size <= bytes.count - pos, flags & ~UInt8(12) == 0 else {
                throw DeviceError(message: "Invalid local video unit")
            }
            result.append(AccessUnit(data: Data(bytes[pos..<(pos + size)]), idr: flags & 4 != 0,
                                     config: flags & 8 != 0, snap: false, boardMs: ms))
            pos += size
        }
        guard pos == bytes.count else { throw DeviceError(message: "Trailing local video data") }
        units = result
    }
}

struct LocalVideoCredentials: Decodable {
    let url: URL
    let token: String
    var isLocal: Bool {
        guard url.scheme == "http", url.port == nil, url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.query == nil, let host = url.host else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }), !token.isEmpty else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

/// Credentials belong to the paired board; never follow an HTTP redirect with them.
final class LocalVideoRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
