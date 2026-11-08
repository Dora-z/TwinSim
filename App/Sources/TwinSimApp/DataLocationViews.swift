import AppKit
import SwiftUI
import TwinSimAgentProtocol

/// Settings section: where devices, Simulator data, imported apps and downloaded engines live.
struct DataLocationSection: View {
    @Environment(AppStore.self) private var store
    @State private var usage: Int64?
    @State private var request: MoveRequest?
    @State private var error: String?

    struct MoveRequest: Identifiable {
        let id = UUID()
        var destination: String
        var existingData: Bool
        var bytes: Int64
        var toDefault: Bool
    }

    var body: some View {
        Section {
            LabeledContent("位置") {
                HStack {
                    Text(store.dataDirectory).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.dataDirectory) } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless).help("在 Finder 中显示")
                }
            }
            if let volume = DataLocation.volume(of: store.dataDirectory) {
                LabeledContent("磁盘") {
                    Text("\(volume.name) · \(volume.format.uppercased()) · 可用 \(Labels.bytes(volume.freeBytes))" + (volume.isRemovable ? " · 外置" : ""))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("已用空间") {
                Text(usage.map(Labels.bytes) ?? "计算中…").foregroundStyle(.secondary)
            }
            if store.dataDirectoryLockedByEnvironment {
                Text("当前由环境变量 TWINSIM_HOME 指定，不能在这里更改。").font(.caption).foregroundStyle(.orange)
            } else {
                HStack {
                    Button("移动到其他位置…") { chooseDestination() }
                    if !store.dataDirectoryIsDefault {
                        Button("移回默认位置…") { prepare(AgentProtocol.defaultDataDirectory, toDefault: true) }
                    }
                }
                .disabled(isMigrating || !store.isConnected)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        } header: {
            Text("数据位置")
        } footer: {
            Text("包含 Android 设备（AVD、快照、TwinSim 管理的 SDK）、iOS Simulator 设备、导入的应用和下载的引擎，可放在 APFS 或 Mac OS 扩展格式的外置硬盘上。iOS Simulator runtime 由 Xcode 管理，不在此目录；使用自有 Android SDK 时，其位置由上面的 ANDROID_HOME 决定。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: store.dataDirectory) { await refreshUsage() }
        .sheet(item: $request) { request in
            MoveDataSheet(request: request) { self.request = nil; Task { await refreshUsage() } }
        }
    }

    private var isMigrating: Bool { if case .migrating = store.connection { return true }; return false }

    private func refreshUsage() async {
        usage = nil
        let path = store.dataDirectory
        usage = await Task.detached(priority: .utility) { DataLocation.size(of: path) }.value
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择存放 TwinSim 数据的文件夹（例如外置硬盘）。数据会放在其中的 TwinSim 文件夹里。"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A folder that already holds TwinSim data is used as is; otherwise data goes into <folder>/TwinSim.
        let chosen = url.standardizedFileURL.path
        if DataLocation.hasData(chosen) { prepare(chosen, toDefault: false) }
        else if DataLocation.hasData(chosen + "/TwinSim") { prepare(chosen + "/TwinSim", toDefault: false) }
        else { prepare(url.lastPathComponent == "TwinSim" ? chosen : chosen + "/TwinSim", toDefault: false) }
    }

    private func prepare(_ destination: String, toDefault: Bool) {
        error = nil
        Task {
            let source = store.dataDirectory
            let bytes = await Task.detached(priority: .userInitiated) { DataLocation.size(of: source) }.value
            let existing = DataLocation.hasData(destination)
            do {
                try DataLocation.validate(destination: destination, current: source, requiredBytes: bytes)
                request = MoveRequest(destination: destination, existingData: existing, bytes: bytes, toDefault: toDefault)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct MoveDataSheet: View {
    @Environment(AppStore.self) private var store
    let request: DataLocationSection.MoveRequest
    let done: () -> Void
    @State private var deleteOld = true

    private var running: [Instance] { store.instances.filter { ["ready", "starting", "unknown"].contains($0.state) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.existingData ? "使用已有的 TwinSim 数据" : "移动 TwinSim 数据").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("当前").foregroundStyle(.secondary); Text(store.dataDirectory).font(.caption.monospaced()) }
                GridRow { Text("新位置").foregroundStyle(.secondary); Text(request.destination).font(.caption.monospaced()) }
                if !request.existingData {
                    GridRow { Text("数据量").foregroundStyle(.secondary); Text(Labels.bytes(request.bytes)) }
                }
            }
            if request.existingData {
                Text("新位置已经有 TwinSim 数据。切换后将使用那里的设备和应用；当前位置的数据保持不变，可以随时切换回来。")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("将停止后端，把设备、Simulator 数据、导入的应用和下载的引擎复制到新位置，并更新 Android 设备配置中的路径，然后从新位置重新启动。复制失败时继续使用当前位置。")
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("后端在新位置启动成功后，删除当前位置的数据（释放 \(Labels.bytes(request.bytes))）", isOn: $deleteOld)
            }
            if !running.isEmpty {
                Label("以下设备会先停机：\(running.map(\.displayName).joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { done() }.keyboardShortcut(.cancelAction)
                Button(request.existingData ? "切换" : "开始移动") {
                    let r = request
                    let delete = deleteOld
                    done()
                    Task {
                        if r.existingData {
                            await store.switchDataDirectory(to: r.toDefault ? nil : r.destination)
                        } else {
                            await store.moveData(to: r.destination, deleteOld: delete)
                        }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// Confirmation before permanently deleting a device.
struct DeleteDeviceConfirmation: ViewModifier {
    @Environment(AppStore.self) private var store
    @Binding var instance: Instance?

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(get: { instance != nil }, set: { if !$0 { instance = nil } }),
                                   titleVisibility: .visible, presenting: instance) { target in
            Button("删除", role: .destructive) {
                Task { _ = await store.deleteInstance(target.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text(message(target))
        }
    }

    private var title: String { "删除「\(instance?.displayName ?? "")」？" }

    private func message(_ target: Instance) -> String {
        if target.isVPhone { return "只从 TwinSim 中移除该设备，vphone 虚拟机文件保留在 vphone 机器库中。" }
        var text = "设备会先停机，然后删除设备及其全部数据（已安装的应用、应用数据、快照），无法恢复。"
        if target.isAppWorkspace { text += "下次打开应用时会重新创建工作区并重新安装。" }
        return text
    }
}

extension View {
    func deleteDeviceConfirmation(_ instance: Binding<Instance?>) -> some View {
        modifier(DeleteDeviceConfirmation(instance: instance))
    }
}
