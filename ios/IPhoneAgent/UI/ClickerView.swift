import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ClickerView: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var board: BoardLink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 0
    @State private var profile = ClickProfile()
    @State private var savedProfile: ClickProfile?
    @State private var profiles: [SavedClickProfile] = []
    @State private var status = ClickerRunStatus()
    @State private var slot = 0
    @State private var schedules = "0"
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var message = "選擇腳本，讓 ESP32 接手點擊。"
    @State private var progress = 0.0
    @State private var busy = false
    @State private var stopping = false
    @State private var statusAvailable = false
    @State private var bulkDelay = 15000
    @State private var requestedCPS = 50
    @State private var importing = false
    @State private var exporting = false
    @State private var zoom = 1.0
    @State private var selectingProfiles = false
    @State private var selectedProfiles = Set<Int>()
    @State private var confirmingDeletion = false
    @State private var spanX = ""
    @State private var spanY = ""
    @State private var mouseOutput = "bluetooth"
    @State private var networkJSON = "{\"mode\":\"apsta\",\"ssid\":\"eduroam\",\"eap\":{\"method\":\"peap\",\"username\":\"\",\"identity\":\"\",\"password\":\"\",\"server\":\"\",\"ca\":\"\"}}"
    private let cyan = Color(red: 0.33, green: 0.91, blue: 0.97)
    private let mint = Color(red: 0.53, green: 0.98, blue: 0.73)
    private var client: ClickerClient { ClickerClient(channel: board.commands) }
    private var dirty: Bool { savedProfile.map { profile != $0 } ?? false }

    init(app: AppModel) { self.app = app; _board = ObservedObject(wrappedValue: app.board) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Picker("頁面", selection: $page) {
                        Text("控制台").tag(0); Text("編輯目標").tag(1); Text("連線設定").tag(2)
                    }.pickerStyle(.segmented).accessibilityIdentifier("clickerPages")
                    if page == 0 { dashboard; savedProfiles; runOptions }
                    if page == 1 { editor; timing; profileSettings }
                    if page == 2 { connectionSettings; calibration; schoolNetwork; sharingGuide }
                    if busy { ProgressView(value: progress).tint(cyan) }
                    Label(message, systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("clickerMessage")
                    Text("原始專案：ESP32 iPhone Agent · Henry Yuan").font(.caption2).foregroundStyle(.tertiary)
                }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("PULSE 連點器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { perform { try await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新整理腳本").disabled(busy || !board.connected)
            } }
            .safeAreaInset(edge: .bottom) { controls }
            .task(id: board.connected) { await watchStatus() }
            .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self), let imported = UIImage(data: data) { setImage(imported) } } }
            .confirmationDialog("刪除選取的 \(selectedProfiles.count) 個腳本？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                Button("刪除 \(selectedProfiles.count) 個腳本", role: .destructive) { perform { await deleteSelectedProfiles() } }
                Button("取消", role: .cancel) {}
            } message: { Text("腳本將從開發板移除，無法復原。正在執行時不能刪除。") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 196608 else { throw DeviceError(message: "腳本檔案太大。") }
                    let imported = try JSONDecoder().decode(ClickProfile.self, from: data)
                    try imported.validate(); profile = imported; message = "已匯入，請儲存到開發板。"
                } catch { message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: ClickProfileDocument(profile: profile), contentType: .json, defaultFilename: "pulse-profile") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.title2.bold()).foregroundStyle(cyan)
                .frame(width: 48, height: 48).background(Color(red: 0.04, green: 0.12, blue: 0.18), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("每一下，都在掌握之中。").font(.headline)
                Text(board.connected ? board.name : "開啟藍牙，連接你的 ESP32")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle().fill(board.connected ? mint : Color.orange).frame(width: 9, height: 9)
                .accessibilityLabel(board.connected ? "開發板已連線" : "開發板未連線")
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(status.running ? "正在點擊" : "準備就緒", systemImage: status.running ? "bolt.fill" : "pause.fill")
                    .font(.caption.bold()).foregroundStyle(mint)
                Spacer()
                Text(status.output == "bluetooth" ? "BLUETOOTH" : "USB").font(.caption2.monospaced().bold()).foregroundStyle(.white.opacity(0.65))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(statusAvailable ? String(format: "%.1f", status.output_cps) : "—")
                    .font(.system(size: 82, weight: .semibold, design: .rounded)).tracking(-4)
                    .contentTransition(.numericText()).minimumScaleFactor(0.5).lineLimit(1)
                    .accessibilityIdentifier("liveCPS")
                Text("CPS").font(.title2.bold()).foregroundStyle(cyan)
            }.foregroundStyle(.white)
            Text(status.running ? "開發板目前輸出速率" : "上次執行的輸出速率")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
            PulseStrip(active: status.running && !reduceMotion, color: cyan)
                .frame(height: 30).accessibilityHidden(true)
            HStack(spacing: 0) {
                metric("累計點擊", String(status.clicks))
                metric("啟用排程", String(status.active))
                metric("設定 CPS", String(format: "%.0f", status.requested_cps))
            }
            Divider().overlay(.white.opacity(0.12))
            HStack {
                Image(systemName: "square.stack.3d.up").foregroundStyle(cyan)
                Text(status.profile.isEmpty ? "尚未選擇腳本" : status.profile).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text(status.network == "off" ? "離線執行" : "Wi-Fi 開啟").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }.foregroundStyle(.white)
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(red: 0.06, green: 0.15, blue: 0.22), Color(red: 0.025, green: 0.065, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(cyan.opacity(0.22), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: status.output_cps)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(.white)
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.6))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savedProfiles: some View {
        card("我的腳本", "square.stack") {
            if !profiles.isEmpty {
                HStack {
                    Text(selectingProfiles ? "已選取 \(selectedProfiles.count) 個" : "共 \(profiles.count) 個腳本").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(selectingProfiles ? "完成" : "批次管理") {
                        selectingProfiles.toggle(); selectedProfiles.removeAll()
                    }.accessibilityIdentifier("manageProfiles")
                        .disabled(busy || status.running || status.releasing || !statusAvailable)
                }
            }
            if selectingProfiles {
                HStack {
                    Button(selectedProfiles.count == profiles.count ? "取消全選" : "全選") {
                        selectedProfiles = selectedProfiles.count == profiles.count ? [] : Set(profiles.map(\.id))
                    }.accessibilityIdentifier("selectAllProfiles")
                    Spacer()
                    Button("刪除所選（\(selectedProfiles.count)）", role: .destructive) { confirmingDeletion = true }
                        .accessibilityIdentifier("deleteSelectedProfiles").disabled(selectedProfiles.isEmpty || busy || status.running || status.releasing || !statusAvailable)
                }.buttonStyle(.bordered).frame(minHeight: 44)
            }
            if profiles.isEmpty {
                Text(board.connected ? "尚無腳本，前往「編輯目標」建立。" : "連線後會顯示開發板已儲存的腳本。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(profiles) { item in
                Button {
                    if selectingProfiles {
                        if !selectedProfiles.insert(item.id).inserted { selectedProfiles.remove(item.id) }
                    } else { perform { try await choose(item.id) } }
                } label: {
                    HStack(spacing: 14) {
                        Text(String(format: "%02d", item.id)).font(.headline.monospaced()).foregroundStyle(.secondary)
                            .frame(width: 42, height: 46).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.bold()).foregroundStyle(.primary)
                            Text("\(item.points) 個點擊位置").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let checked = selectingProfiles ? selectedProfiles.contains(item.id) : slot == item.id
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(checked ? Color.teal : Color.secondary)
                    }.frame(minHeight: 56).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(busy || status.running || status.releasing)
                    .accessibilityIdentifier("savedProfile-\(item.id)")
                    .accessibilityValue(selectingProfiles ? (selectedProfiles.contains(item.id) ? "已選取" : "未選取") : (slot == item.id ? "目前腳本" : ""))
            }
            Button { page = 1 } label: { Label("建立或編輯腳本", systemImage: "plus.circle") }.frame(minHeight: 44)
        }
    }

    private var runOptions: some View {
        card("執行方式", "play.rectangle") {
            Label(status.mouse_connected ? "目標手機已連接" : "等待滑鼠連線", systemImage: status.mouse_connected ? "checkmark.shield.fill" : "antenna.radiowaves.left.and.right")
                .font(.subheadline).foregroundStyle(status.mouse_connected ? Color.teal : Color.orange)
            Text("已儲存的腳本會在開發板執行。切換到遊戲或關閉此 App，連點仍會繼續。")
                .font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("多組排程與離線模式") {
                TextField("腳本編號，例如 0,1,2", text: $schedules).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                Text("最多 16 組排程共用一個指標，依序點擊不同位置。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("切換為離線執行") { perform {
                    let ids = try scheduleIDs()
                    _ = try await client.request("run/selection", method: "PUT", object: ["profiles": ids])
                    _ = try await client.request("mode/offline", method: "POST")
                    message = "開發板將重啟並關閉 Wi-Fi；選用藍牙時會保留藍牙。按住 BOOT 1 秒後放開即可開始。"
                } }.frame(minHeight: 44).disabled(busy || status.running)
            }
            Text("顯示的是開發板輸出 CPS。藍牙傳送及遊戲處理可能讓實際收到的點擊較少。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { stop() } label: {
                Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 52)
            }.buttonStyle(.bordered).tint(.red).disabled(!board.connected || stopping).accessibilityIdentifier("stopClicker")
            Button { perform {
                guard !dirty else { throw DeviceError(message: "請先儲存修改，再開始執行。") }
                try await client.start(slots: scheduleIDs()); message = "開發板開始執行。請切換到目標 App；按 BOOT 可隨時停止。"
                status = try await client.runStatus(); Haptics.start()
            } } label: {
                Label(status.running ? "執行中" : "開始連點", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 52)
            }.buttonStyle(.borderedProminent).tint(.teal)
                .disabled(!board.connected || !statusAvailable || !status.mouse_connected || busy || status.running || status.releasing || app.agent.running)
                .accessibilityIdentifier("startClicker")
        }.font(.headline).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }

    private var editor: some View {
        card("目標畫布", "scope") {
            HStack {
                Text("拖曳編號即可調整位置").font(.caption).foregroundStyle(.secondary)
                Spacer(); Text("\(profile.points.count) 個目標").font(.caption.bold()).foregroundStyle(.teal)
            }
            canvas
            ViewThatFits(in: .horizontal) {
                HStack { imageButtons }
                VStack(alignment: .leading) { imageButtons }
            }.buttonStyle(.bordered)
            HStack { Text("縮放").font(.caption); Slider(value: $zoom, in: 1...2).tint(.teal) }
        }
    }
    @ViewBuilder private var imageButtons: some View {
        PhotosPicker(selection: $photo, matching: .images) { Label("匯入截圖", systemImage: "photo") }
        Button { if let data = app.feed.frame, let captured = UIImage(data: data) { setImage(captured) } else { message = "請先啟用螢幕鏡像，或匯入截圖。" } } label: { Image(systemName: "camera.viewfinder") }.accessibilityLabel("擷取鏡像畫面")
        Button { addTarget() } label: { Label("新增目標", systemImage: "plus") }.accessibilityIdentifier("addTarget")
    }
    private var canvas: some View {
        GeometryReader { geometry in
            let size = TargetCanvasGeometry.size(image: image?.size, landscape: profile.landscape, availableWidth: geometry.size.width, maximumHeight: 430 * zoom)
            ZStack {
                Color(red: 0.04, green: 0.10, blue: 0.15)
                Canvas { context, size in
                    var grid = Path()
                    for n in 1..<10 {
                        let x = size.width * CGFloat(n) / 10, y = size.height * CGFloat(n) / 10
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                }.accessibilityHidden(true)
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height).accessibilityLabel("原比例截圖").accessibilityIdentifier("targetScreenshot") }
                ForEach(Array(profile.points.enumerated()), id: \.element.id) { index, target in
                    Text("\(index + 1)").font(.system(size: 15, weight: .bold, design: .rounded)).frame(width: 44, height: 44)
                        .background(target.enabled ? cyan : Color.gray, in: Circle()).foregroundStyle(.black)
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                        .position(x: Double(target.x) / 10000 * size.width, y: Double(target.y) / 10000 * size.height)
                        .gesture(DragGesture(coordinateSpace: .named("targets")).onChanged { value in
                            guard profile.points.indices.contains(index) else { return }
                            let position = TargetCanvasGeometry.normalized(value.location, in: size)
                            profile.points[index].x = position.x
                            profile.points[index].y = position.y
                        }).accessibilityLabel("目標 \(index + 1)")
                }
            }.frame(width: size.width, height: size.height)
                .coordinateSpace(name: "targets").clipShape(RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.frame(height: 430 * zoom)
    }

    private func setImage(_ imported: UIImage) {
        image = imported; profile.landscape = imported.size.width > imported.size.height
        message = "已依截圖原始比例顯示；目標座標與圖片共用同一畫布。"
    }

    private var timing: some View {
        card("點擊與時間", "timer") {
            HStack { number("設定 CPS", value: $requestedCPS); Button("套用速度") {
                guard (1...500).contains(requestedCPS) else { message = "CPS 請輸入 1 到 500。"; return }
                let period = max(2, 1_000_000 / requestedCPS)
                for i in profile.points.indices { profile.points[i].press_us = max(1, min(5000, period / 2)); profile.points[i].delay_us = max(1, period - profile.points[i].press_us) }
                profile.fast = true
            }.buttonStyle(.bordered).accessibilityIdentifier("applyCPS") }
            DisclosureGroup("批次延遲") {
                number("放開後延遲（µs）", value: $bulkDelay)
                Button("套用到所有目標") { for i in profile.points.indices { profile.points[i].delay_us = bulkDelay } }.frame(minHeight: 44)
            }
            Text("1 µs 是設定精度，實際速度取決於 USB／藍牙、移動距離及目標 App。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($profile.points) { $target in
                let index = profile.points.firstIndex(where: { $0.id == target.id }) ?? 0
                DisclosureGroup {
                    HStack { number("X（0–10000）", value: $target.x); number("Y（0–10000）", value: $target.y) }
                    HStack { number("按住（µs）", value: $target.press_us); number("放開後（µs）", value: $target.delay_us) }
                    Toggle("啟用目標", isOn: $target.enabled)
                    HStack {
                        Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("目標上移")
                        Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("目標下移")
                        Button("複製") { if profile.points.count < 1000 { var copy = target; copy.id = UUID(); profile.points.insert(copy, at: index + 1) } }
                        Spacer()
                        Button("刪除", role: .destructive) { if profile.points.count > 1 { profile.points.removeAll { $0.id == target.id } } }
                    }.buttonStyle(.bordered)
                } label: {
                    HStack {
                        Text("目標 \(index + 1)").font(.subheadline.bold())
                        Spacer()
                        Text("\(target.x), \(target.y)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
            }
        }
    }

    private var profileSettings: some View {
        card("儲存腳本", "square.and.arrow.down") {
            TextField("腳本名稱", text: $profile.name).textFieldStyle(.roundedBorder)
            Picker("儲存位置", selection: $slot) { ForEach(0..<32) { Text("位置 \($0)").tag($0) } }
            Toggle("橫向畫面", isOn: $profile.landscape)
            Toggle("同一位置快速連點", isOn: $profile.fast)
            number("重複次數（0＝持續執行）", value: $profile.repeats)
            Button { perform {
                try await client.save(profile, slot: slot) { progress = $0 }
                let verified = try await client.load(slot: slot)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(profile) == encoder.encode(verified) else { throw DeviceError(message: "腳本驗證失敗，請重新儲存。") }
                savedProfile = profile; profiles = try await client.savedProfiles(); schedules = String(slot); message = "已儲存並讀回驗證。"
            } } label: { Label(dirty ? "儲存修改到開發板" : "儲存到開發板", systemImage: "checkmark.shield") }
                .buttonStyle(.borderedProminent).tint(.teal).disabled(busy || !board.connected || status.running)
            HStack {
                Button("讀取腳本") { perform { try await choose(slot) } }.disabled(busy || !board.connected)
                Spacer(); Button("匯入") { importing = true }; Button("匯出") { exporting = true }
            }.buttonStyle(.bordered)
        }
    }

    private var connectionSettings: some View {
        card("連接開發板", "antenna.radiowaves.left.and.right") {
            if !board.connected {
                ForEach(board.found) { found in
                    Button { board.pair(found.id) } label: { LabeledContent(found.name, value: "\(found.rssi) dBm") }.frame(minHeight: 44)
                }
                Button(board.scanning ? "正在搜尋…" : "搜尋附近的 ESP32") { board.scan() }.buttonStyle(.borderedProminent).disabled(board.scanning)
            } else { Label(board.name, systemImage: "checkmark.circle.fill").foregroundStyle(.teal) }
            Picker("滑鼠輸出", selection: $mouseOutput) { Text("藍牙無線").tag("bluetooth"); Text("USB 有線").tag("usb") }.pickerStyle(.segmented)
            Button("套用輸出方式") { perform {
                _ = try await client.request("input/output", method: "PUT", object: ["output": mouseOutput])
                message = "已切換輸出。藍牙模式請在目標手機配對 ESP32，並啟用「輔助觸控」。"
            } }.disabled(busy || !board.connected || status.running).frame(minHeight: 44)
        }
    }

    private var calibration: some View {
        card("指標校正", "scope") {
            Text("每支手機與畫面方向需要各自校正。請先完成自動校正，再儲存到開發板。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("校正識別碼", text: Binding(get: { profile.device ?? "default" }, set: { profile.device = $0 }))
                .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("開始自動校正") { app.calibrator.calibrate() }.frame(minHeight: 44).disabled(!board.connected || status.running)
            Button("使用 App 目前的校正值") {
                if let span = app.pointer.span { spanX = String(span.w); spanY = String(span.h) }
                else { message = "請先完成自動校正。" }
            }.frame(minHeight: 44)
            HStack {
                TextField("水平 HID 範圍", text: $spanX).keyboardType(.numberPad)
                TextField("垂直 HID 範圍", text: $spanY).keyboardType(.numberPad)
            }.textFieldStyle(.roundedBorder)
            Button("儲存校正到開發板") { perform {
                guard let x = Int(spanX), let y = Int(spanY), (1...32000).contains(x), (1...32000).contains(y) else { throw DeviceError(message: "請輸入兩個有效的校正範圍。") }
                _ = try await client.request("calibration", method: "PUT", object: ["device": profile.device ?? "default", "span_x": x, "span_y": y, "landscape": profile.landscape])
                message = "已儲存這支手機與方向的校正值。"
            } }.frame(minHeight: 44).disabled(busy || !board.connected || status.running)
        }
    }
    private var schoolNetwork: some View {
        card("學校 Wi-Fi / eduroam", "wifi") {
            Text("帳號使用學校電子郵件與密碼。第一次設定仍需學校官方的 CA 憑證與驗證伺服器名稱。")
                .font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup("進階設定匯入") {
                TextEditor(text: $networkJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 160).privacySensitive()
                Button("上傳網路設定") { perform {
                    guard var object = try JSONSerialization.jsonObject(with: Data(networkJSON.utf8)) as? [String: Any] else { throw DeviceError(message: "JSON 格式不正確。") }
                    object["unix_time"] = Int(Date().timeIntervalSince1970)
                    try await client.upload(JSONSerialization.data(withJSONObject: object), path: "network") { progress = $0 }
                    networkJSON = "{}"; message = "已上傳網路設定。"
                } }.frame(minHeight: 44).disabled(busy || !board.connected)
            }
            Text("完整表單可從開發板熱點的網頁控制台設定。離線連點不需要 Wi-Fi。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sharingGuide: some View {
        card("用這支手機控制另一支手機", "iphone.gen3.radiowaves.left.and.right") {
            Text("1. 經對方同意，在目標手機的藍牙設定配對 ESP32，並開啟輔助觸控。")
            Text("2. 控制手機連上 ESP32 的熱點，開啟 192.168.4.1，以螢幕上的控制台權杖登入。")
            Text("3. 儲存目標手機的校正與腳本，再開始點擊。")
            Text("熱點網頁可避免控制手機同時搶用藍牙滑鼠。螢幕觀看需要目標手機另外啟用螢幕鏡像；藍牙滑鼠本身不會傳送螢幕。")
                .font(.caption).foregroundStyle(.secondary)
        }.font(.subheadline)
    }

    private func card<Content: View>(_ title: String, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }
    private func number(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, format: .number).keyboardType(.numberPad).textFieldStyle(.roundedBorder) }
    }
    private func scheduleIDs() throws -> [Int] {
        let parts = schedules.split(separator: ",", omittingEmptySubsequences: false)
        let ids = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard ids.count == parts.count, (1...16).contains(ids.count), Set(ids).count == ids.count, ids.allSatisfy({ (0..<32).contains($0) }) else { throw DeviceError(message: "請選擇 1–16 個不重複的腳本編號（0–31）。") }
        return ids
    }
    private func addTarget() { if profile.points.count < 1000 { profile.points.append(ClickTarget()) } }
    private func move(_ i: Int, _ direction: Int) { let j = i + direction; if profile.points.indices.contains(j) { profile.points.swapAt(i, j) } }
    private func deleteSelectedProfiles() async {
        guard !status.running, !status.releasing else { message = "請先停止並放開按鍵，再刪除腳本。"; return }
        let ids = selectedProfiles.sorted()
        var deleted = Set<Int>()
        var failure: Error?
        for id in ids {
            do {
                if !MockMode.on { _ = try await client.request("profiles/\(id)", method: "DELETE") }
                deleted.insert(id); progress = Double(deleted.count) / Double(ids.count)
            } catch { failure = error; break }
        }
        profiles.removeAll { deleted.contains($0.id) }
        selectedProfiles.subtract(deleted)
        // Reload even after an uncertain reply: the board may have committed a
        // deletion before the Bluetooth link dropped. Do not retry it blindly.
        if deleted.contains(slot) { profile = ClickProfile(); savedProfile = profile; image = nil; schedules = "" }
        do {
            if !MockMode.on { try await reload() }
        } catch { if failure == nil { failure = error } }
        selectedProfiles.formIntersection(Set(profiles.map(\.id)))
        if let failure { message = "已確認刪除 \(deleted.count) 個；請重新整理確認其餘腳本：\(failure.localizedDescription)" }
        else { message = "已刪除 \(deleted.count) 個腳本。"; selectingProfiles = false; selectedProfiles.removeAll() }
    }
    private func choose(_ id: Int) async throws {
        if MockMode.on { slot = id; return }
        guard !status.running else { throw DeviceError(message: "請先停止執行。") }
        let loaded = try await client.load(slot: id)
        _ = try await client.request("run/selection", method: "PUT", object: ["profiles": [id]])
        slot = id; profile = loaded; savedProfile = loaded; schedules = String(id); message = "已選擇「\(loaded.name)」。"
    }
    private func reload() async throws {
        profiles = try await client.savedProfiles()
        let raw = try await client.request("run/selection")
        if let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: [Int]], let ids = object["profiles"], let first = ids.first {
            slot = first; schedules = ids.map(String.init).joined(separator: ",")
            if !dirty { profile = try await client.load(slot: first); savedProfile = profile }
        } else if profiles.isEmpty {
            slot = 0; schedules = ""; profile = ClickProfile(); savedProfile = profile; image = nil
        }
        status = try await client.runStatus(); mouseOutput = status.output; statusAvailable = true
    }
    private func watchStatus() async {
        if savedProfile == nil { savedProfile = profile }
        if MockMode.on {
            if ProcessInfo.processInfo.arguments.contains("-target-portrait-fixture") {
                setImage(UIGraphicsImageRenderer(size: CGSize(width: 440, height: 956)).image { context in
                    UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 440, height: 956))
                    UIColor.white.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 120, y: 378, width: 200, height: 200))
                })
            }
            profiles = [SavedClickProfile(id: 3, name: "Business Empire 快速", points: 1), SavedClickProfile(id: 4, name: "Business Empire 穩定", points: 1)]
            slot = 3; schedules = "3"; status = ClickerRunStatus(running: false, releasing: false, clicks: 300, loops: 300, active: 0, point: 0, late: 0, output_cps: 43.7, requested_cps: 50, output: "bluetooth", mouse_connected: true, profile: "Business Empire 快速", network: "off"); statusAvailable = true
            return
        }
        statusAvailable = false
        guard board.connected else { return }
        var profilesLoaded = false
        while !Task.isCancelled && board.connected {
            if !busy && scenePhase == .active {
                do {
                    // A new BLE link may still be negotiating its MTU. Retry the complete
                    // initial load instead of leaving the dashboard with an empty list.
                    if !profilesLoaded {
                        try await reload()
                        // Send only once per link, after MTU and encryption are ready.
                        // Optional for backward compatibility with older firmware.
                        _ = try? await client.request("device/label", method: "PUT", object: ["name": UIDevice.current.name])
                        profilesLoaded = true
                    }
                    else { status = try await client.runStatus(); statusAvailable = true }
                }
                catch { statusAvailable = false; message = "狀態更新失敗：\(error.localizedDescription)" }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
    private func stop() {
        stopping = true
        Task { @MainActor in
            defer { stopping = false }
            do { _ = try await client.request("run/stop", method: "POST"); message = "已要求停止並放開按鍵。"; Haptics.stop() }
            catch { message = "停止指令未送達，請按開發板 BOOT：\(error.localizedDescription)" }
        }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; progress = 0
        Task { @MainActor in defer { busy = false }; do { try await work() } catch { message = error.localizedDescription } }
    }
}

private struct PulseStrip: View {
    var active: Bool
    var color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !active)) { timeline in
            Canvas { context, size in
                let phase = active ? timeline.date.timeIntervalSinceReferenceDate : 0
                for i in 0..<36 {
                    let height = active ? 5 + (sin(Double(i) * 0.55 + phase * 3) + 1) * 10 : 4
                    let rect = CGRect(x: Double(i) * size.width / 36, y: (size.height - height) / 2, width: max(2, size.width / 36 - 4), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(active ? 0.8 : 0.3)))
                }
            }
        }
    }
}

struct ClickProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var profile: ClickProfile
    init(profile: ClickProfile) { self.profile = profile }
    init(configuration: ReadConfiguration) throws { profile = try JSONDecoder().decode(ClickProfile.self, from: configuration.file.regularFileContents ?? Data()); try profile.validate() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: try JSONEncoder().encode(profile)) }
}
