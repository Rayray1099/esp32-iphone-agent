import Foundation
import UIKit

/// What the agent and the pointer need from the screen (VideoFeed, or a fake in tests). Port of screen.py.
@MainActor protocol ScreenSource: AnyObject {
    var live: Bool { get }
    var frame: Data? { get }
    var updated: Double { get }
    var capturedAt: Double { get }
    var aspect: Double { get }
    /// After a gesture that ended at `since`: wait until the screen shows its result (and fetch it, in snap mode).
    func afterAction(since: Double) async throws
}

/// How a run gets its frames: the live stream (`stream on`, the default: a frame in under a second), or one
/// snap after each action (`stream off`; waits for the board's whole GOP, often 20-30 s).
enum FrameMode: String {
    case stream, snap
    static let key = "frameModeV2"  // V2: drops the old saved "snap" left by earlier automatic fallbacks
    /// A command timeout switches the current run to snap; not saved, so the next run streams again.
    static var fallback: FrameMode?
    static var current: FrameMode {
        get { fallback ?? FrameMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .stream }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); fallback = nil }
    }
}

extension ScreenSource {
    func afterAction(since: Double) async { await settled() }

    /// Wait until the screen stops changing (AirPlay only sends frames on change). Mid-animation frames are big and
    /// can reach us late over BLE, so a gap is only "quiet" once it also covers the last frame's transport lag.
    func settled(quiet: Double = 0.5, least: Double = 0.3, most: Double = 4) async {
        let started = now()
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        while now() - updated < quiet + lag && now() - started < most {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How late the shown frame arrived after the board got it (0 when unknown), capped.
    private var lag: Double { capturedAt > 0 ? min(max(updated - capturedAt, 0), 1) : 0 }

    /// The first frame captured after `since` (received, when capture times are unknown), or nil if none in time.
    func fresh(since: Double, timeout: Double = 0.8) async -> Data? {
        let deadline = now() + timeout
        while (capturedAt > 0 ? capturedAt : updated) <= since {
            if now() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return frame
    }
}

/// The phone's screen, mirrored over AirPlay to the board and forwarded over BLE, as JPEG frames.
@MainActor final class VideoFeed: ObservableObject, ScreenSource {
    @Published private(set) var frame: Data?
    @Published private(set) var size = CGSize.zero
    @Published private(set) var note = ""  // last decoder problem, shown in Diagnostics
    private(set) var updated = 0.0
    /// When the board received the shown frame, in local time (≈; see `boardClock`).
    private(set) var capturedAt = 0.0
    /// A decode error or a lost chunk since the last good frame: the shown frame is stale until the next IDR.
    private(set) var broken = false
    private var clockOffset: Double?  // local s − board s, the smallest seen (≈ the link latency)
    var mirroring = false  // board status says ap == streaming
    var metrics: Metrics?
    weak var device: HIDDevice?

    private var assembler = VideoAssembler()
    private let decoder = H264Decoder()
    private var localTask: Task<Void, Never>?
    private var localGeneration: UInt32?
    private var localNext: UInt32 = 0
    private var localLatestMs: UInt32 = 0
    private var localVerifiedAt = 0.0
    private var decodedBoardMs: UInt32 = 0
    private var localActive = false
    private(set) var transport = "BLE"
    private lazy var localSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        // A VPN or metered Wi-Fi can be marked expensive. Cellular is prohibited
        // separately; rejecting expensive paths can also reject the local LAN.
        // A large IDR may exceed one small batch on a busy ESP32 radio.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: LocalVideoRedirectPolicy(), delegateQueue: nil)
    }()

    init() {
        decoder.onFrame = { [weak self] f in DispatchQueue.main.async { self?.publish(f) } }
        decoder.onError = { [weak self] msg in
            DispatchQueue.main.async {
                let bg = UIApplication.shared.applicationState == .background
                self?.note = bg ? "\(msg) [in background]" : msg
                self?.metrics?.decodeError(background: bg)
                self?.broken = true
            }
        }
    }

    var live: Bool { mirroring && !broken && frame != nil && (device?.connected ?? false) }

    /// Frame width / height (portrait iPhone as a fallback).
    var aspect: Double { size.width > 0 && size.height > 0 ? size.width / size.height : 9 / 19.5 }

    /// One `video` notify from BoardLink.
    func receive(_ chunk: Data) {
        guard !localActive else { return }
        metrics?.videoBytes(chunk.count)
        let dropsBefore = assembler.drops
        let unit = assembler.add(chunk)
        if assembler.drops > dropsBefore { metrics?.videoDrops(assembler.drops - dropsBefore); broken = true }
        guard let unit else { return }
        if !unit.snap { boardClock(ms: Int(unit.boardMs)) }  // snap units are resent late: their ages say nothing
        if unit.idr { metrics?.idrSeen() }
        decoder.queue.async { [decoder] in decoder.decode(unit) }
    }

    /// The link (re)connected: chunk numbering starts over.
    func resetStream() {
        localTask?.cancel(); localTask = nil; localActive = false
        localGeneration = nil; localNext = 0; localVerifiedAt = 0; decodedBoardMs = 0
        decoder.queue.async { [decoder] in decoder.reset() }
        assembler.reset(); clockOffset = nil
        frame = nil; capturedAt = 0; updated = 0; broken = true
    }

    /// A board timestamp (status `up`, or a streamed unit) just arrived: keep the smallest offset.
    func boardClock(ms: Int) {
        let offset = now() - Double(ms) / 1000
        clockOffset = min(clockOffset ?? offset, offset)
    }

    /// Show a still frame (demo data).
    func show(_ jpeg: Data, width: Int, height: Int) {
        publish(H264Decoder.Frame(jpeg: jpeg, width: width, height: height, decodeMs: 4.2,
                                  unit: AccessUnit(data: Data(), idr: false, config: false, snap: false, boardMs: 0)))
    }

    private func publish(_ f: H264Decoder.Frame) {
        let capture = clockOffset.map { Double(f.unit.boardMs) / 1000 + $0 } ?? now()
        guard capture >= capturedAt else { return }  // a replay must never move the screen backwards
        frame = f.jpeg
        updated = now()
        capturedAt = capture
        decodedBoardMs = f.unit.boardMs
        broken = false
        if size.width != CGFloat(f.width) || size.height != CGFloat(f.height) {
            size = CGSize(width: f.width, height: f.height)
        }
        metrics?.frameDecoded(ms: f.decodeMs)
    }

    /// The app asked the board to forward the stream (`stream on`).
    private(set) var streamOn = false

    /// Seconds a snap may take: the buffered GOP over the measured BLE rate, doubled, at least 8 s.
    var snapTimeout: Double {
        let gopBytes = Double(metrics?.board?.gop ?? 0)
        let kbps = max(metrics?.bleKbps ?? 0, metrics?.board?.ble?.kbps ?? 0, 40)
        return max(8, gopBytes * 8 / 1000 / kbps * 2 + 3)
    }

    /// A current frame for the model. While the board streams, the live stream has it (an IDR comes every
    /// ~2 s): use a frame younger than `maxAge`, or wait for the next one. Snap only as a fallback, retried
    /// once with a longer timeout. Returns where the frame came from, for the log.
    @discardableResult
    func currentFrame(maxAge: Double = 1, wait: Double = 3) async throws -> String {
        if localActive {
            let deadline = now() + max(wait, 30)
            while localActive && now() < deadline {
                try Task.checkCancellation()
                // AirPlay sends nothing for an unchanged screen. A recent board watermark
                // proves that our decoded frame is still the newest captured image.
                if !broken, frame != nil, localVerifiedAt > now() - 2,
                   decodedBoardMs == localLatestMs { return "local Wi-Fi (verified latest)" }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if localActive {
                throw BlindError(reason: "區域網路鏡像未追上最新畫面，已停止以避免誤觸。")
            }
        }
        if streamOn && mirroring {
            if !broken && frame != nil && now() - capturedAt < maxAge { return "live" }
            if await fresh(since: now() - maxAge, timeout: wait) != nil && !broken { return "live (waited)" }
        }
        do {
            try await snap()
        } catch is BoardTimeout {
            DebugLog.write("snap timed out; retrying once with a longer timeout")
            try await snap(timeout: snapTimeout * 1.5)
        }
        guard !broken, frame != nil, now() - capturedAt < maxAge + wait else {
            throw BlindError(reason: "螢幕畫面已過期，請重新連接螢幕鏡像輸出後再執行。")
        }
        return "snap"
    }

    /// Ask the board for the current GOP and wait until it is decoded. Returns the latency in ms.
    @discardableResult
    func snap(timeout: Double? = nil) async throws -> Double {
        if localActive {
            let began = now()
            _ = try await currentFrame(wait: timeout ?? 10)
            return (now() - began) * 1000
        }
        guard let device else { throw DeviceError(message: "board not connected") }
        let started = now()
        if let channel = device as? CommandChannel {
            try await channel.send("snap", timeout: timeout ?? snapTimeout)
        } else {
            try await device.send("snap")
        }
        await withCheckedContinuation { c in decoder.queue.async { c.resume() } }  // the GOP is decoded
        try? await Task.sleep(nanoseconds: 30_000_000)  // let the last frame reach the main queue
        let ms = (now() - started) * 1000
        metrics?.snapLatency(ms)
        return ms
    }

    func stream(_ on: Bool) async throws {
        localTask?.cancel(); localTask = nil; localActive = false
        if on, let channel = device as? CommandChannel,
           let response = try? await channel.send("video-auth", timeout: 5),
           let credentials = try? JSONDecoder().decode(LocalVideoCredentials.self, from: Data(response.utf8)),
           credentials.isLocal {
            try await device?.send("stream off")
            localGeneration = nil; localNext = 0; localVerifiedAt = 0
            localActive = true; transport = "Wi-Fi"; streamOn = true
            localTask = Task { [weak self] in await self?.readLocalVideo(credentials) }
            DebugLog.write("video: local Wi-Fi enabled; cellular disabled for video requests")
            return
        }
        transport = "BLE"
        try await device?.send("stream \(on ? "on" : "off")")
        streamOn = on
    }

    private func readLocalVideo(_ credentials: LocalVideoCredentials) async {
        var failures = 0
        while !Task.isCancelled && localActive {
            do {
                var components = URLComponents(url: credentials.url.appendingPathComponent("api/v1/video/frames"), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "generation", value: String(localGeneration ?? UInt32.max)),
                                         URLQueryItem(name: "after", value: String(localNext)),
                                         URLQueryItem(name: "max_bytes", value: "131072")]
                var request = URLRequest(url: components.url!)
                request.allowsCellularAccess = false
                request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
                let (data, response) = try await localSession.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      let up = response.value(forHTTPHeaderField: "X-Board-Uptime-Ms").flatMap(Int.init),
                      let latest = response.value(forHTTPHeaderField: "X-Video-Captured-Ms").flatMap(UInt32.init)
                else { throw DeviceError(message: "Local video is not ready") }
                let batch = try LocalVideoBatch(data)
                boardClock(ms: up)
                if localGeneration != batch.generation {
                    frame = nil; capturedAt = 0; decodedBoardMs = 0; broken = true
                }
                localGeneration = batch.generation; localNext = batch.next
                localLatestMs = latest; localVerifiedAt = now()
                let units = batch.units
                await withCheckedContinuation { continuation in
                    decoder.queue.async { [decoder] in
                        for (index, unit) in units.enumerated() {
                            decoder.decode(unit, emit: index == units.count - 1)
                        }
                        continuation.resume()
                    }
                }
                failures = 0
                // Drain catch-up batches immediately. Once caught up, poll at
                // 5 Hz; the board watermark still gates every model decision.
                if units.isEmpty || units.last?.boardMs == latest {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch is CancellationError { return }
            catch {
                if Task.isCancelled { return }
                failures += 1
                let issue = error as NSError
                note = "local video: \(issue.domain) \(issue.code): \(issue.localizedDescription)"
                DebugLog.write(note)
                if failures >= 2 {
                    localActive = false; transport = "BLE"; assembler.reset()
                    decoder.queue.async { [decoder] in decoder.reset() }
                    DebugLog.write("video: local Wi-Fi unavailable; switching to BLE")
                    try? await device?.send("stream on")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The model must never see a frame from before the action that ended at `since`. Stream: let the screen
    /// settle, then wait (bounded) for a frame captured after the action; none while the stream is healthy means
    /// the screen did not change, but a broken stream (waiting for an IDR) needs a snap. Snap: give the UI a moment,
    /// snap, and snap once more if the GOP still ends before the action.
    func afterAction(since: Double) async throws {
        do {
            if localActive {
                await settled()
                if await newer(than: since, timeout: 4) && !broken { return }
            }
            if FrameMode.current == .snap {
                try await Task.sleep(nanoseconds: 700_000_000)
                try await currentFrame()
                guard capturedAt < since else { return }
                DebugLog.write(String(format: "frame: snap ends %.1f s before the action; snapping again", since - capturedAt))
                try await Task.sleep(nanoseconds: 500_000_000)
                try await currentFrame()
            } else {
                await settled()
                if await newer(than: since, timeout: 2) && !broken { return }
                // A tiny out-and-back pointer probe forces a screen update even when a tap changed
                // nothing. A decoded frame from after it proves the entire capture path still works.
                try Task.checkCancellation()
                let probeAt = now()
                try await device?.send("move 1 0")
                try await device?.send("move -1 0")
                if await newer(than: probeAt, timeout: 4) && !broken { return }
                DebugLog.write("frame: no capture after the action/probe; requesting current GOP")
                try await snap()
            }
        } catch {
            DebugLog.write("frame after action failed: \(error.localizedDescription)")
        }
        guard !broken, capturedAt >= since else {
            throw BlindError(reason: "ESP32 未傳回操作後的新畫面，已停止以避免誤觸。請重新連接螢幕鏡像輸出。")
        }
    }

    /// Waits until the shown frame was captured after `t`; false on timeout.
    private func newer(than t: Double, timeout: Double) async -> Bool {
        let deadline = now() + timeout
        while capturedAt < t {
            if now() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// The link dropped: the board forgets `stream on`.
    func linkLost() {
        localTask?.cancel(); localTask = nil; localActive = false
        streamOn = false
    }
}
