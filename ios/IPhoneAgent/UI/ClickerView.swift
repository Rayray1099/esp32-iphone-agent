import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ClickerView: View {
    @ObservedObject var app: AppModel
    @State private var profile = ClickProfile()
    @State private var slot = 0
    @State private var schedules = "0"
    @State private var image: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var message = "Place targets, save to the board, then run without keeping this app open."
    @State private var progress = 0.0
    @State private var busy = false
    @State private var bulkDelay = 5000
    @State private var requestedCPS = 150
    @State private var importing = false
    @State private var exporting = false
    @State private var zoom = 1.0
    @State private var spanX = ""
    @State private var spanY = ""
    @State private var mouseOutput = "usb"
    @State private var networkJSON = "{\"mode\":\"apsta\",\"ssid\":\"eduroam\",\"eap\":{\"method\":\"peap\",\"username\":\"\",\"identity\":\"\",\"password\":\"\",\"server\":\"\",\"ca\":\"\"}}"
    private var client: ClickerClient { ClickerClient(channel: app.board.commands) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("clickerMessage")
                    if busy { ProgressView(value: progress) }
                    canvas
                    HStack {
                        PhotosPicker("Import screenshot", selection: $photo, matching: .images)
                        Button("Freeze mirror") { if let data = app.feed.frame { image = UIImage(data: data) } }
                        Button("Add target") { addTarget() }
                    }.buttonStyle(.bordered)
                    HStack { Text("Zoom"); Slider(value: $zoom, in: 1...2) }
                    GroupBox("Saved profile") {
                        VStack(spacing: 12) {
                            TextField("Profile name", text: $profile.name).textFieldStyle(.roundedBorder)
                            TextField("Device calibration ID", text: Binding(get: { profile.device ?? "default" }, set: { profile.device = $0 })).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Picker("Slot", selection: $slot) { ForEach(0..<32) { Text("Slot \($0)").tag($0) } }
                            Toggle("Landscape", isOn: $profile.landscape)
                            number("Repeats (0 = forever)", value: $profile.repeats)
                            HStack {
                                Button("Load from board") { perform { profile = try await client.load(slot: slot); message = "Loaded saved board profile." } }
                                Button("Import JSON") { importing = true }
                                Button("Export JSON") { exporting = true }
                                Button("Save to board") { perform { try await client.save(profile, slot: slot) { progress = $0 }; message = "Saved and verified on the board." } }
                            }.buttonStyle(.bordered)
                        }.padding(8)
                    }
                    GroupBox("Targets and microsecond timing") {
                        LazyVStack(spacing: 12) {
                            number("Delay for all (µs)", value: $bulkDelay)
                            Button("Apply to all targets") { for i in profile.points.indices { profile.points[i].delay_us = bulkDelay } }
                            number("Requested repeat CPS", value: $requestedCPS)
                            Button("Set fast repeat timing") {
                                guard (1...500).contains(requestedCPS) else { return }
                                for i in profile.points.indices { profile.points[i].press_us = 1000; profile.points[i].delay_us = max(1, 1_000_000 / requestedCPS - 1000) }
                            }
                            Text("1 µs settings are accepted. USB polling and iOS determine actual taps. Moving between targets takes longer.").font(.caption).foregroundStyle(.secondary)
                            ForEach($profile.points) { $target in
                                VStack(alignment: .leading) {
                                    let index = profile.points.firstIndex(where: { $0.id == target.id }) ?? 0
                                    HStack {
                                        Text("Target \(index + 1)").bold()
                                        Toggle("Enabled", isOn: $target.enabled).labelsHidden()
                                        Spacer()
                                        Button("↑") { move(index, -1) }.accessibilityLabel("Move target up")
                                        Button("↓") { move(index, 1) }.accessibilityLabel("Move target down")
                                    }
                                    HStack { number("X", value: $target.x); number("Y", value: $target.y) }
                                    HStack { number("Press µs", value: $target.press_us); number("Delay µs", value: $target.delay_us) }
                                    HStack {
                                        Button("Duplicate") { if profile.points.count < 1000 { var copy = target; copy.id = UUID(); profile.points.insert(copy, at: index + 1) } }
                                        Button("Delete", role: .destructive) { if profile.points.count > 1 { profile.points.removeAll { $0.id == target.id } } }
                                    }.buttonStyle(.bordered)
                                    Divider()
                                }.padding(.vertical, 5)
                            }
                        }.padding(8)
                    }
                    GroupBox("Board execution") {
                        VStack(spacing: 14) {
                            Picker("Mouse output", selection: $mouseOutput) {
                                Text("USB").tag("usb")
                                Text("Bluetooth wireless").tag("bluetooth")
                            }
                            Button("Apply mouse output") { perform {
                                _ = try await client.request("input/output", method: "PUT", object: ["output": mouseOutput])
                                message = mouseOutput == "bluetooth" ? "Pair ESP32 Agent in iPhone Bluetooth settings and enable AssistiveTouch. Bluetooth CPS counts host submissions; verify received taps separately." : "USB mouse selected."
                            } }
                            TextField("Concurrent slots: 0,1,2", text: $schedules).textFieldStyle(.roundedBorder)
                            Button("Start saved profiles") { perform {
                                let ids = try scheduleIDs()
                                try await client.start(slots: ids); message = "Running from board memory. BOOT stops the clicker."
                            } }.buttonStyle(.borderedProminent)
                            Button("Stop", role: .destructive) { perform { _ = try await client.request("run/stop", method: "POST"); message = "Stop requested." } }.buttonStyle(.bordered)
                            Button("Switch board to offline mode") { perform {
                                let ids = try scheduleIDs()
                                _ = try await client.request("run/selection", method: "PUT", object: ["profiles": ids])
                                _ = try await client.request("mode/offline", method: "POST");message = "Board restarting with Wi-Fi off. Bluetooth stays on when selected. Hold BOOT 1s to start; hold 4s while idle for setup."
                            } }
                        }.padding(8)
                    }
                    calibration
                    GroupBox("Enterprise Wi-Fi configuration") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Use the hotspot controller for the full eduroam form, or import a JSON configuration here. CA and server validation are required. School credentials stay on the board.").font(.callout)
                            TextEditor(text: $networkJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 180).privacySensitive()
                            Button("Upload network settings") { perform {
                                guard var object = try JSONSerialization.jsonObject(with: Data(networkJSON.utf8)) as? [String: Any] else { throw DeviceError(message: "Invalid JSON") }
                                object["unix_time"] = Int(Date().timeIntervalSince1970)
                                try await client.upload(JSONSerialization.data(withJSONObject: object), path: "network") { progress = $0 }
                                networkJSON = "{}";message = "Network configuration uploaded."
                            } }
                        }.padding(8)
                    }
                    Text("Based on ESP32 iPhone Agent by Henry Yuan.").font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            .navigationTitle("Offline clicker")
            .disabled(busy)
            .onChange(of: photo) { _, item in Task { if let data = try? await item?.loadTransferable(type: Data.self) { image = UIImage(data: data) } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { let url = try result.get();let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url);guard data.count <= 196608 else { throw DeviceError(message: "Profile too large") }
                    let imported = try JSONDecoder().decode(ClickProfile.self, from: data);try imported.validate();profile = imported
                } catch { message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: ClickProfileDocument(profile: profile), contentType: .json, defaultFilename: "clicker-profile") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemBackground))
                if let image { Image(uiImage: image).resizable().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                ForEach(Array(profile.points.enumerated()), id: \.element.id) { index, target in
                    Text("\(index + 1)").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34)
                        .background(target.enabled ? Color.green : Color.gray, in: Circle()).foregroundStyle(.black)
                        .position(x: Double(target.x) / 10000 * geometry.size.width, y: Double(target.y) / 10000 * geometry.size.height)
                        .gesture(DragGesture(coordinateSpace: .named("targets")).onChanged { value in
                            guard profile.points.indices.contains(index) else { return }
                            profile.points[index].x = min(10000, max(0, Int(value.location.x / geometry.size.width * 10000)))
                            profile.points[index].y = min(10000, max(0, Int(value.location.y / geometry.size.height * 10000)))
                        })
                        .accessibilityLabel("Target \(index + 1)")
                }
            }.coordinateSpace(name: "targets").clipped()
        }.aspectRatio(profile.landscape ? 16 / 9 : 9 / 16, contentMode: .fit).frame(maxHeight: 600 * zoom)
    }

    private var calibration: some View {
        GroupBox("Calibration for this device and orientation") {
            VStack(spacing: 12) {
                Text("Run the app’s touch calibration, then copy its measured span. A different device or orientation needs its own calibration.").font(.callout)
                Button("Use current app calibration") {
                    if let span = app.pointer.span { spanX = String(span.w);spanY = String(span.h) }
                    else { message = "Complete touch calibration in Agent setup first." }
                }
                TextField("Measured horizontal HID span", text: $spanX).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                TextField("Measured vertical HID span", text: $spanY).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                Button("Save calibration to board") { perform {
                    guard let x = Int(spanX), let y = Int(spanY), (1...32000).contains(x), (1...32000).contains(y) else { throw DeviceError(message: "Enter both measured spans.") }
                    _ = try await client.request("calibration", method: "PUT", object: ["device": profile.device ?? "default", "span_x": x, "span_y": y, "landscape": profile.landscape]);message = "Board calibration saved."
                } }
            }.padding(8)
        }
    }

    private func number(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, value: value, format: .number).keyboardType(.numberPad).textFieldStyle(.roundedBorder) }
    }
    private func scheduleIDs() throws -> [Int] {
        let parts = schedules.split(separator: ",", omittingEmptySubsequences: false)
        let ids = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard ids.count == parts.count, (1...16).contains(ids.count), ids.allSatisfy({ (0..<32).contains($0) }) else {
            throw DeviceError(message: "Choose 1–16 saved slots from 0 to 31.")
        }
        return ids
    }
    private func addTarget() { if profile.points.count < 1000 { profile.points.append(ClickTarget()) } }
    private func move(_ i: Int, _ direction: Int) { let j = i + direction;if profile.points.indices.contains(j) { profile.points.swapAt(i, j) } }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true;progress = 0
        Task { @MainActor in defer { busy = false };do { try await work() } catch { message = error.localizedDescription } }
    }
}

struct ClickProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var profile: ClickProfile
    init(profile: ClickProfile) { self.profile = profile }
    init(configuration: ReadConfiguration) throws {
        profile = try JSONDecoder().decode(ClickProfile.self, from: configuration.file.regularFileContents ?? Data());try profile.validate()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: try JSONEncoder().encode(profile)) }
}
