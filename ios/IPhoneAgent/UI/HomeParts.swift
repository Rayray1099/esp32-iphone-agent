import SwiftUI

/// A persistent status card: preparation must never look like an already running task.
struct AgentRunStatus: View {
    @ObservedObject var app: AppModel
    @ObservedObject var agent: AgentLoop

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(app.startingAgent ? "準備啟動中" : agent.running ? "AI 執行中" : app.startupCancelled ? "已停止・啟動已取消" : "啟動失敗・尚未執行",
                      systemImage: app.startingAgent ? "hourglass" : agent.running ? "play.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(app.startupFailure != nil ? Palette.stop : app.startingAgent ? Palette.warning : Palette.ok)
                    .accessibilityIdentifier("agentRunState")
                Spacer()
                if app.startingAgent {
                    Text(app.startupSince, style: .timer).font(.caption.monospacedDigit())
                }
            }
            if app.startingAgent {
                ProgressView(value: app.startupStage.progress).tint(Palette.warning)
                Text(verbatim: app.startupStage.title).font(.headline).accessibilityIdentifier("startupStage")
                Text(verbatim: app.startupStage.detail).font(.subheadline).foregroundStyle(.secondary)
            } else if let error = app.startupFailure {
                Text(verbatim: error).font(.subheadline).textSelection(.enabled)
                Button("檢查螢幕鏡像輸出") { app.setupPage = .see }.buttonStyle(.bordered)
            } else if app.startupCancelled {
                Text("AI 沒有開始操作。你可以調整任務後重新開始。")
            } else {
                Text("已完成準備；請從動態島查看目前步驟。返回此 App 時會暫停操作。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

/// "Needs your help": why, and Take over / Continue / Skip / Stop (the same as the Live Activity).
struct HelpPanel: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Section {
            Label { Text(verbatim: app.help ?? "") } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning)
            }
            .font(.body.weight(.semibold))
            if app.takingOver {
                Text("Do the step yourself, then tap Continue.").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: Space.s) {
                if app.takingOver {
                    Button { app.answerHelp(.resume) } label: { Label("Continue", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Palette.ok)
                } else {
                    Button { app.takeOver() } label: { Label("Take Over", systemImage: "hand.point.up.left.fill") }
                        .buttonStyle(.borderedProminent)
                }
                Button { app.answerHelp(.skip) } label: { Text("Skip Step") }.buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive) { Task { await app.stopAgent() } } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered).accessibilityLabel(Text("Stop"))
            }
            .controlSize(.regular)
        } header: {
            Text("Needs your help")
        }
    }
}

/// The run is paused for a lost link: what is missing, how long, and what (if anything) the user should do.
struct RecoveryPanel: View {
    @ObservedObject var app: AppModel
    let stage: Recovery.Stage

    var body: some View {
        Section {
            HStack(spacing: Space.m) {
                if stage.ask {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Palette.warning)
                } else {
                    ProgressView()
                }
                Text(verbatim: stage.status.full).font(.body.weight(.semibold))
                Spacer()
                Text(timerInterval: app.recoverySince...Date.distantFuture, countsDown: false)
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(verbatim: stage.line).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(role: .destructive) { Task { await app.stopAgent() } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
            }
        } header: {
            Text("Connection lost, run paused")
        }
    }
}

/// A demonstration in progress: timer, screens captured, Stop / Cancel; then "working out the steps".
struct RecordingPanel: View {
    @ObservedObject var recorder: DemoRecorder

    var body: some View {
        Section {
            if recorder.recording {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Text(timerInterval: recorder.started...Date.distantFuture, countsDown: false)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Spacer()
                    Text("\(recorder.keyframes) screens").foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Go to the Home Screen and do the task. Stop here or in the Dynamic Island.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button { Task { await recorder.stop() } } label: { Label("Stop Recording", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent).tint(.red)
                    Spacer()
                    Button("Cancel", role: .destructive) { recorder.cancel() }
                }
            } else if recorder.inferring {
                HStack(spacing: Space.m) {
                    ProgressView()
                    Text("Working out the steps from \(recorder.keyframes) screens…")
                }
            } else if let error = recorder.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(Palette.warning)
                Button("OK") { recorder.error = nil }
            }
        } header: {
            Text("Recording")
        }
    }
}
