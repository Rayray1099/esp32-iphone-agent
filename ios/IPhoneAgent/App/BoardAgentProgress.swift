import Foundation

/// Bounded telemetry plus an explicit public progress summary; no raw reasoning.
struct BoardAgentProgress {
    var run: UInt32 = 0
    var phase = "preparing"
    var action = "Checking"
    var step = 0
    var limit = 40
    var started = 0.0
    var frameMs = 0, modelMs = 0, hidMs = 0
    var summary = ""
    var summaryRound = -1
    static func cleanSummary(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            // Collapse control/format separators; don't break UTF-8 or send emoji
            // that the embedded CJK font cannot draw.
            let v = scalar.value
            if v < 32 || (0x7f...0x9f).contains(v) || (0x200b...0x200f).contains(v) ||
                (0x2028...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0xfeff {
                if !result.hasSuffix(" ") { result += " " }
                continue
            }
            guard (32...126).contains(v) || (0x3000...0x303f).contains(v) ||
                    (0x3400...0x9fff).contains(v) || (0xff01...0xff60).contains(v) else { continue }
            let next = String(scalar)
            if result.utf8.count + next.utf8.count > 90 { break }
            result += next
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func line(at time: Double) -> String {
        let seconds = min(604800, max(0, Int(time - started)))
        let base = "@agent \(run) \(phase) \(min(step, limit)) \(limit) \(frameMs) \(modelMs) \(hidMs) \(seconds) \(action)"
        let text = Self.cleanSummary(summary)
        return text.isEmpty ? base : base + " |" + text
    }
}

extension AppModel {
    func beginBoardProgress() {
        boardProgress = BoardAgentProgress(run: max(boardProgress.run + 1, UInt32(Date().timeIntervalSince1970)),
                                           limit: agent.maxSteps, started: now())
        sendBoardProgress()
    }

    func setBoardProgress(_ phase: String, action: String? = nil) {
        guard boardProgress.run != 0 else { return }
        boardProgress.phase = phase
        if ["done", "failed", "stopped", "help", "stopping"].contains(phase) {
            let labels = ["done": "已確認任務完成", "failed": "操作未完成，請查看手機記錄", "stopped": "已停止並釋放輸入",
                          "help": "請在手機上確認下一步", "stopping": "正在停止操作"]
            boardProgress.summary = labels[phase] ?? ""
        }
        if ["done", "failed", "stopped"].contains(phase) { boardProgressFinishedAt = now() }
        if let action { boardProgress.action = action }
        boardProgress.step = startingAgent ? 0 : agent.round
        if let timing = metrics.steps.last {
            boardProgress.frameMs = min(3600000, max(0, Int(timing.frameMs)))
            boardProgress.modelMs = min(3600000, max(0, Int(timing.llmMs)))
            boardProgress.hidMs = min(3600000, max(0, Int(timing.hidMs)))
        }
        sendBoardProgress()
    }

    func sendBoardProgress() {
        guard !MockMode.on, boardProgress.run != 0, board.connected else { return }
        if ["done", "failed", "stopped"].contains(boardProgress.phase), now() - boardProgressFinishedAt > 5 { return }
        // Fire-and-forget: a busy transport drops this update; the next heartbeat retries.
        board.commands.relayLog(boardProgress.line(at: now()))
    }

    func showBoardDoing(_ doing: AgentLoop.Doing) {
        switch doing {
        case .looking: setBoardProgress("looking", action: "Read_screen")
        case .waiting: setBoardProgress("waiting", action: "Model_response")
        case .planning: setBoardProgress("planning", action: "Make_plan")
        case .thinking: setBoardProgress("thinking", action: "Choose_action")
        case .retrying: setBoardProgress("retrying", action: "Model_retry")
        case .acting(let act):
            let labels = ["tap": "Tap", "swipe": "Swipe", "path": "Drag", "circle": "Draw",
                          "type": "Type_text", "key": "Keyboard", "home": "Home", "back": "Back", "wait": "Wait"]
            let newRound = boardProgress.summaryRound != agent.round
            boardProgress.step = agent.round
            boardProgress.phase = "acting"
            boardProgress.action = labels[act["action"]?.str ?? ""] ?? "Input"
            if let summary = act["status_zh"]?.str {
                boardProgress.summary = BoardAgentProgress.cleanSummary(summary)
            } else if newRound || boardProgress.summary.isEmpty {
                let fallback = ["tap": "點擊畫面上的目標", "swipe": "滑動畫面尋找目標", "type": "在欄位輸入文字",
                                "key": "使用鍵盤快捷鍵", "home": "返回手機主畫面", "back": "返回上一個畫面", "wait": "等待畫面更新"]
                boardProgress.summary = fallback[act["action"]?.str ?? ""] ?? "執行下一步操作"
            }
            boardProgress.summaryRound = agent.round
            sendBoardProgress()
        }
    }
}
