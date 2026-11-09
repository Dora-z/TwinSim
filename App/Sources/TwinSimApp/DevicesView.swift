import SwiftUI

struct DevicesView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?
    @State private var creating = false
    @State private var deleting: Instance?

    private var devices: [Instance] { store.instances.filter { !$0.isAppWorkspace } }
    private var workspaces: [Instance] { store.instances.filter(\.isAppWorkspace) }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                if store.instances.isEmpty {
                    ContentUnavailableView {
                        Label("还没有设备", systemImage: "iphone.slash")
                    } description: {
                        Text("创建一台 Android 或 iOS 设备，或在「应用」中直接打开 APK / .app。")
                    } actions: {
                        Button("创建设备…") { creating = true }
                    }
                }
                if !devices.isEmpty {
                    Section("设备") {
                        ForEach(devices) { DeviceRow(instance: $0, onDelete: { deleting = $0 }).tag($0.id) }
                    }
                }
                if !workspaces.isEmpty {
                    Section("应用工作区（后台）") {
                        ForEach(workspaces) { DeviceRow(instance: $0, onDelete: { deleting = $0 }).tag($0.id) }
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            .onDeleteCommand { if let id = selection { deleting = store.instance(id) } }
            Group {
                if let id = selection, store.instance(id) != nil {
                    DeviceDetailView(instanceId: id).id(id)
                } else {
                    Text("选择一台设备").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem {
                Button { creating = true } label: { Label("创建设备", systemImage: "plus") }
            }
            ToolbarItem {
                Button { Task { await store.reloadInstances() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .deleteDeviceConfirmation($deleting)
        .onChange(of: store.instances.map(\.id)) { _, ids in
            if let id = selection, !ids.contains(id) { selection = ids.first }
        }
        .sheet(isPresented: $creating) {
            CreateDeviceSheet { id in selection = id }
        }
        .onAppear { if selection == nil { selection = store.instances.first?.id } }
    }
}

struct DeviceRow: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    var onDelete: (Instance) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: instance.isWindows ? "pc" : instance.isAndroid ? "smartphone" : "iphone")
                .font(.title2).foregroundStyle(instance.isReady ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(Labels.profile(instance.profileId)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if store.operations.values.contains(where: { $0.instanceId == instance.id && !$0.isTerminal && $0.action != "tap" }) {
                ProgressView().controlSize(.small)
            }
            StatusBadge.instance(instance.state)
        }
        .padding(.vertical, 3)
        .contextMenu { DeviceActions(instance: instance, onDelete: onDelete) }
    }
}

/// Lifecycle actions shared by the row menu and the detail view.
struct DeviceActions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let instance: Instance
    var onDelete: (Instance) -> Void = { _ in }

    var body: some View {
        Button("启动") { Task { await store.run(instance.id, "start") } }
            .disabled(instance.isReady || instance.isTransitioning)
        Button("停机") { Task { await store.run(instance.id, "stop") } }
            .disabled(instance.state == "stopped" || instance.state == "creating")
        Divider()
        Button("查看画面") { openWindow(value: ScreenTarget(instanceId: instance.id)) }
            .disabled(!instance.isReady)
        Divider()
        Button("删除设备…", role: .destructive) { onDelete(instance) }
            .disabled(instance.isTransitioning)
    }
}

struct DeviceDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let instanceId: UUID
    @State private var installTarget: UUID?
    @State private var deleting: Instance?

    var body: some View {
        if let instance = store.instance(instanceId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(instance)
                    if let op = currentOperation {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(Labels.action(op.action))：\(Labels.stage(op.stage) ?? (op.state == "queued" ? "排队中" : "进行中"))")
                                .foregroundStyle(.secondary)
                        }
                    } else if let failure = lastFailure {
                        Label("\(Labels.action(failure.action))失败：\(failure.error.map { Labels.reason($0.code) ?? $0.message } ?? "")",
                              systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                    GroupBox("信息") { info(instance).padding(4) }
                    if instance.hardware != nil {
                        GroupBox("硬件") { HardwareEditor(instance: instance).padding(4) }
                    }
                    GroupBox("能力") { CapabilityGrid(instance: instance).padding(4) }
                    GroupBox("应用") { installSection(instance).padding(4) }
                    GroupBox("日志") {
                        LogsView(instanceId: instance.id, compact: true).frame(height: 260)
                    }
                }
                .padding(20)
            }
            .deleteDeviceConfirmation($deleting)
        }
    }

    private var currentOperation: BackendOperation? {
        store.operationOrder.lazy.compactMap { store.operations[$0] }
            .first { $0.instanceId == instanceId && !$0.isTerminal && !["tap", "key", "shell"].contains($0.action) }
    }

    private var lastFailure: BackendOperation? {
        guard let op = store.operationOrder.lazy.compactMap({ store.operations[$0] })
            .first(where: { $0.instanceId == instanceId && !["tap", "key", "shell"].contains($0.action) }),
              op.state == "failed" else { return nil }
        return op
    }

    private func header(_ instance: Instance) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(instance.displayName).font(.title.bold())
                HStack { StatusBadge.instance(instance.state); Text(Labels.engine(instance.engineId)).foregroundStyle(.secondary) }
            }
            Spacer()
            if instance.isReady {
                Button { openWindow(value: ScreenTarget(instanceId: instance.id)) } label: { Label("查看画面", systemImage: "rectangle.on.rectangle") }
                    .buttonStyle(.borderedProminent)
                Button { Task { await store.run(instance.id, "stop") } } label: { Label("停机", systemImage: "stop.fill") }
                    .disabled(instance.isTransitioning)
            } else {
                Button { Task { await store.run(instance.id, "start") } } label: { Label("启动", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(instance.isTransitioning || currentOperation != nil)
                if instance.state == "unknown" || instance.state == "failed" {
                    Button { Task { await store.run(instance.id, "stop") } } label: { Label("停机", systemImage: "stop.fill") }
                }
            }
            Menu {
                Button("删除设备…", role: .destructive) { deleting = instance }
                    .disabled(instance.isTransitioning)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("更多操作")
        }
    }

    private func info(_ instance: Instance) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { Text("配置").foregroundStyle(.secondary); Text(Labels.profile(instance.profileId)) }
            GridRow { Text("用途").foregroundStyle(.secondary); Text(instance.isAppWorkspace ? "应用工作区（单应用模式复用）" : "完整设备") }
            if let uid = instance.guestUid {
                GridRow { Text("客体 UID").foregroundStyle(.secondary); Text("\(uid)").monospaced() }
            }
            if let selinux = instance.selinux {
                GridRow { Text("SELinux").foregroundStyle(.secondary); Text(selinux) }
            }
            GridRow { Text("ID").foregroundStyle(.secondary); Text(instance.id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func installSection(_ instance: Instance) -> some View {
        let compatible = store.artifacts.filter { $0.engineId == instance.engineId }
        if compatible.isEmpty {
            Text("「应用」中没有适用于该设备的应用。").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(compatible) { artifact in
                    HStack {
                        Text(artifact.name).lineLimit(1)
                        Text(artifact.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("安装并打开") {
                            Task { await store.open(artifact, instanceId: instance.id) }
                        }
                        .disabled(!instance.isReady || store.launching.contains(artifact.id))
                        Button("卸载") {
                            Task { await store.run(instance.id, "uninstall", body: ["bundleId": artifact.bundleId]) }
                        }
                        .disabled(!instance.isReady)
                    }
                }
            }
        }
    }
}

struct CapabilityGrid: View {
    let instance: Instance
    private let order = ["liveVideo", "screenshot", "input", "logs", "guestShell", "guestRoot", "writableSystem",
                         "snapshot", "guestFiles", "portForward", "frida", "installApk", "installSimulatorApp", "installDeviceIpa"]

    var body: some View {
        let keys = order.filter { instance.capabilities[$0] != nil } + instance.capabilities.keys.filter { !order.contains($0) }.sorted()
        let supported = keys.filter { instance.capabilities[$0]?.isSupported == true }.map(Labels.capability)
        if !instance.isReady, !keys.isEmpty,
           keys.allSatisfy({ instance.capabilities[$0]?.availability != "available" }) {
            VStack(alignment: .leading, spacing: 4) {
                Text("设备运行后可用：").foregroundStyle(.secondary)
                Text(supported.joined(separator: "、")).font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if keys.isEmpty {
            Text("正在读取能力…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    let cap = instance.capabilities[key]!
                    HStack(spacing: 6) {
                        Image(systemName: icon(cap)).foregroundStyle(color(cap))
                        Text(Labels.capability(key)).foregroundStyle(cap.isSupported ? .primary : .secondary)
                    }
                    .font(.callout)
                    .help(cap.reasonCode.map { Labels.reason($0) ?? $0 } ?? Labels.componentStatus(cap.availability))
                }
            }
        }
    }

    private func icon(_ c: Capability) -> String {
        switch c.availability {
        case "available": "checkmark.circle.fill"
        case "blocked": "pause.circle.fill"
        default: "minus.circle"
        }
    }
    private func color(_ c: Capability) -> Color {
        switch c.availability {
        case "available": .green
        case "blocked": .orange
        default: .secondary
        }
    }
}

struct CreateDeviceSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onCreated: (UUID) -> Void
    @State private var engineId = "android-emulator"
    @State private var profileId = "android-google-apis"
    @State private var name = ""
    @State private var externalName = ""
    @State private var working = false
    @State private var startAfter = true
    @State private var customHardware = false
    @State private var cpus = BackendSettings.load().androidCpus > 0 ? BackendSettings.load().androidCpus : BackendSettings.autoCpus
    @State private var ramMB = BackendSettings.load().androidRamMB > 0 ? BackendSettings.load().androidRamMB : BackendSettings.autoRamMB

    private var engine: EngineInfo? { store.engines.first { $0.engineId == engineId } }
    private var missing: [Component] {
        guard let engine else { return [] }
        let needed = engine.componentIds.filter { id in
            id != "android-display" && id != "windows-dxvk" && (id == "android-engine" || id == "ios-vphone" || id == "ios-simulator-runtime" ||
                                        id == (profileId == "windows-d3dmetal" ? "windows-d3dmetal" : "windows-wine") ||
                                        id == (profileId == "android-google-apis" ? "android-google-apis" : "android-runtime"))
        }
        return needed.compactMap { store.component($0) }.filter { !$0.isReady }
    }

    var body: some View {
        Form {
            Picker("引擎", selection: $engineId) {
                ForEach(store.engines) { Text(Labels.engine($0.engineId)).tag($0.engineId) }
            }
            .onChange(of: engineId) { _, new in
                profileId = store.engines.first { $0.engineId == new }?.profiles.first ?? ""
                if new == "android-emulator" { profileId = "android-google-apis" }
            }
            Picker("配置", selection: $profileId) {
                ForEach(engine?.profiles ?? [], id: \.self) { Text(Labels.profile($0)).tag($0) }
            }
            TextField("名称", text: $name, prompt: Text("例如 Pixel 研究机"))
            if engineId == "ios-vphone" {
                TextField("已准备的 VM 名称（可选）", text: $externalName, prompt: Text("vphone 机器库中的名称"))
            }
            if engineId == "android-emulator" {
                Toggle("单独设置 CPU 和内存", isOn: $customHardware)
                if customHardware {
                    Picker("CPU 核心", selection: $cpus) {
                        ForEach(1...BackendSettings.hostCpus, id: \.self) { Text("\($0) 核").tag($0) }
                    }
                    Picker("内存", selection: $ramMB) {
                        ForEach(HardwareChoices.ram(max: BackendSettings.maxAndroidRamMB), id: \.self) { Text(HardwareChoices.label($0)).tag($0) }
                    }
                }
            }
            Toggle("创建后启动", isOn: $startAfter)
            if !missing.isEmpty {
                Section {
                    ForEach(missing) { component in
                        Label {
                            VStack(alignment: .leading) {
                                Text("\(Labels.component(component.id))：\(Labels.componentStatus(component.status))")
                                if let reason = Labels.reason(component.reasonCode) {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                    Text("请先在「组件」页完成安装或配置。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    working = true
                    Task {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let custom = customHardware && engineId == "android-emulator"
                        let id = await store.createInstance(engineId: engineId, profileId: profileId, name: trimmed,
                                                            externalName: externalName.isEmpty ? nil : externalName,
                                                            cpus: custom ? cpus : nil, ramMB: custom ? ramMB : nil)
                        working = false
                        if let id {
                            onCreated(id)
                            dismiss()
                            if startAfter { await store.run(id, "start") }
                        }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("创建") }
                }
                .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || profileId.isEmpty)
            }
        }
        .onAppear {
            if let first = store.engines.first, !store.engines.contains(where: { $0.engineId == engineId }) {
                engineId = first.engineId; profileId = first.profiles.first ?? ""
            }
        }
    }
}


enum HardwareChoices {
    static func ram(max: Int) -> [Int] {
        [2048, 2560, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768].filter { $0 <= max }
    }
    static let note = "低于系统镜像最低要求的内存会被模拟器自动提高（API 34 镜像实测约 2.5 GB）。"

    static func label(_ mb: Int) -> String { mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024) }
}

/// Android device hardware (CPU cores, RAM): own values or the default from Settings.
struct HardwareEditor: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var cpus = 0
    @State private var ramMB = 0
    @State private var working = false
    @State private var message: String?

    var body: some View {
        if let hw = instance.hardware {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Label("\(hw.cpus) 核", systemImage: "cpu")
                    Label(HardwareChoices.label(hw.ramMB), systemImage: "memorychip")
                    Text(hw.custom ? "本设备单独设置" : "使用默认设置").foregroundStyle(.secondary)
                    Spacer()
                }
                if hw.pending {
                    Label(instance.isReady ? "设备正在以原配置运行，新配置将在下次启动时生效。" : "下次启动时应用新配置。",
                          systemImage: "clock.arrow.circlepath").font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Picker("CPU", selection: $cpus) {
                        ForEach(1...max(1, hw.maxCpus), id: \.self) { Text("\($0) 核").tag($0) }
                    }
                    .frame(maxWidth: 160)
                    Picker("内存", selection: $ramMB) {
                        ForEach(HardwareChoices.ram(max: hw.maxRamMB), id: \.self) { Text(HardwareChoices.label($0)).tag($0) }
                    }
                    .frame(maxWidth: 180)
                    Button("保存") { apply(["cpus": cpus, "ramMB": ramMB]) }
                        .disabled(working || (cpus == hw.cpus && ramMB == hw.ramMB && hw.custom))
                    if hw.custom { Button("恢复默认") { apply(["useDefault": true]) }.disabled(working) }
                    if working { ProgressView().controlSize(.small) }
                }
                if hw.pending && instance.isReady {
                    Button("重启设备以应用") {
                        working = true
                        Task {
                            if await store.run(instance.id, "stop") != nil { await store.run(instance.id, "start") }
                            working = false
                        }
                    }
                    .disabled(working)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text(HardwareChoices.note).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { cpus = hw.cpus; ramMB = HardwareChoices.ram(max: hw.maxRamMB).last { $0 <= hw.ramMB } ?? hw.ramMB }
            .onChange(of: hw) { _, new in cpus = new.cpus; ramMB = HardwareChoices.ram(max: new.maxRamMB).last { $0 <= new.ramMB } ?? new.ramMB }
        }
    }

    private func apply(_ body: [String: Any]) {
        working = true
        Task {
            if let op = await store.run(instance.id, "hardware", body: body) {
                message = op.result?["applied"] == "now" ? "已应用。" : "已保存，将在下次启动时生效。"
            }
            await store.refreshInstance(instance.id)
            working = false
        }
    }
}
