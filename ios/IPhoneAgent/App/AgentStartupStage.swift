import Foundation

/// Preparation is distinct from a running agent.
enum AgentStartupStage: Int, CaseIterable {
    case checking, model, video, leaving, firstFrame, stopping

    var title: String {
        switch self {
        case .checking: return "檢查連線與游標校正"
        case .model: return "準備 AI 模型"
        case .video: return "驗證即時螢幕畫面"
        case .leaving: return "切換至主畫面"
        case .firstFrame: return "確認操作前的新畫面"
        case .stopping: return "正在取消啟動"
        }
    }
    var detail: String {
        switch self {
        case .video: return "AirPlay 已連線仍需確認可解碼畫面。請保持螢幕鏡像輸出開啟。"
        case .leaving: return "準備完成後會離開此 App；動態島會顯示執行狀態。"
        case .stopping: return "正在停止畫面傳輸並釋放滑鼠控制。"
        default: return "目前仍在準備，AI 尚未開始操作。你可以隨時取消。"
        }
    }
    var progress: Double { Double(min(rawValue, 4) + 1) / 5 }
}
