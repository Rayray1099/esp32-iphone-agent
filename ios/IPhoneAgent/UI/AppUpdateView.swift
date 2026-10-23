import SwiftUI

struct AppUpdateView: View {
    @ObservedObject var app: AppModel
    @StateObject private var updater = AppUpdater()
    @State private var shareURL: URL?
    private var runActive: Bool { app.startingAgent || app.agent.running }

    var body: some View {
        List {
            Section {
                LabeledContent("目前版本", value: "\(updater.installedVersion)（\(updater.installedBuild)）")
                if let update = updater.manifest {
                    LabeledContent("最新版本", value: "\(update.version)（\(update.build)）")
                }
                Button { Task { await updater.check() } } label: {
                    HStack {
                        Label("檢查更新", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if updater.busy { ProgressView() }
                    }
                }
                .disabled(updater.busy || runActive)
                Text(updater.message).font(.subheadline).foregroundStyle(.secondary)
            } header: { Text("App 更新") } footer: {
                Text(runActive ? "請先停止 AI 任務，再下載更新。" : "僅透過 Wi-Fi 連線；不使用行動數據。")
            }
            if updater.available, let update = updater.manifest {
                Section {
                    Text(update.notes)
                    LabeledContent("下載大小", value: ByteCountFormatter.string(fromByteCount: update.bytes, countStyle: .file))
                    if let package = updater.package {
                        Button { shareURL = package } label: {
                            Label("交給 LCSign 安裝", systemImage: "square.and.arrow.up")
                        }
                        .disabled(runActive)
                    } else {
                        Button { Task { await updater.download() } } label: {
                            Label("下載更新", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(updater.busy || runActive)
                    }
                } header: { Text("更新內容") }
            }
            Section {
                Text("iOS 需要重新簽名並確認安裝。請在 LCSign 使用相同的憑證與套件識別碼覆蓋安裝，保留設定與腳本。")
                Text("請勿先刪除目前的 App。若分享選單未出現 LCSign，請先儲存至「檔案」，再從 LCSign 匯入 IPA。")
            } header: { Text("如何安裝") }
        }
        .navigationTitle("App 更新")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
    }
}
