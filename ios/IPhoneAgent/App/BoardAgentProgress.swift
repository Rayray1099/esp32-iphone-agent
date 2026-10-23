import Foundation

/// Bounded, non-sensitive telemetry. No task, typed text, model reply or credentials.
struct BoardAgentProgress {
    var run: UInt32 = 0
    var phase = "preparing"
    var action = "Checking"
    var step = 0
    var limit = 40
    var started = 0.0
    var frameMs = 0, modelMs = 0, hidMs = 0
    func line(at time: Double) -> String {
        let seconds = min(604800, max(0, Int(time - started)))
        return "@agent \(run) \(phase) \(min(step, limit)) \(limit) \(frameMs) \(modelMs) \(hidMs) \(seconds) \(action)"
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
            boardProgress.step = agent.round
            boardProgress.phase = "acting"
            boardProgress.action = labels[act["action"]?.str ?? ""] ?? "Input"
            sendBoardProgress()
        }
    }
}
