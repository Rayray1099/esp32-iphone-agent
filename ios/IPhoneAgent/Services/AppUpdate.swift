import Combine
import CryptoKit
import Foundation

struct AppUpdateManifest: Decodable {
    let bundleID: String
    let version: String
    let build: Int
    let url: URL
    let bytes: Int64
    let sha256: String
    let notes: String

    func validate(bundleID installedID: String) throws {
        guard bundleID == installedID, build > 0, !version.isEmpty,
              bytes > 0, bytes <= 100 * 1024 * 1024,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/Rayray1099/esp32-iphone-agent/releases/download/"),
              url.pathExtension == "ipa" else { throw AppUpdateError.invalidManifest }
    }

    var filename: String { "ESP32-Agent-build\(build).ipa" }
    func isNewer(than installedBuild: Int) -> Bool { build > installedBuild }

    func verify(_ file: URL) throws {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(bytes) else { throw AppUpdateError.badDownload }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else { throw AppUpdateError.badDownload }
    }
}

enum AppUpdateError: LocalizedError {
    case invalidManifest, badDownload, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "更新資訊不正確，請稍後再試。"
        case .badDownload: return "下載的檔案不完整或校驗失敗，請重新下載。"
        case .unavailable: return "目前尚未提供可下載的更新，請稍後再試。"
        }
    }
}

@MainActor final class AppUpdater: ObservableObject {
    static let manifestURL = URL(string: "https://github.com/Rayray1099/esp32-iphone-agent/releases/download/ios-latest/update.json")!
    let installedBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    @Published private(set) var manifest: AppUpdateManifest?
    @Published private(set) var busy = false
    @Published private(set) var message = "按下「檢查更新」取得最新版本。"
    @Published private(set) var package: URL?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    var available: Bool { manifest?.isNewer(than: installedBuild) == true }

    func check() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        manifest = nil; package = nil; message = "正在檢查更新⋯"
        do {
            let (data, response) = try await session.data(from: Self.manifestURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppUpdateError.unavailable }
            guard data.count <= 32768 else { throw AppUpdateError.invalidManifest }
            let update = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
            try update.validate(bundleID: Bundle.main.bundleIdentifier ?? "")
            manifest = update
            message = available ? "發現新版本，可下載後交給 LCSign 安裝。" : "已是最新版本。"
        } catch { message = error.localizedDescription }
    }

    func download() async {
        guard !busy, available, let manifest else { return }
        busy = true; defer { busy = false }
        package = nil; message = "正在下載更新並驗證 SHA-256⋯"
        do {
            let (temporary, response) = try await session.download(from: manifest.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppUpdateError.unavailable }
            try await Task.detached(priority: .utility) { try manifest.verify(temporary) }.value
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppUpdates", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(manifest.filename)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: temporary, to: destination)
            package = destination
            message = "檔案驗證完成。按「交給 LCSign 安裝」，選擇 LCSign 或儲存到「檔案」後匯入。"
        } catch { message = error.localizedDescription }
    }
}
