import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let androidPackage = UTType(filenameExtension: "apk", conformingTo: .data) ?? .data
    static let iosPackage = UTType(filenameExtension: "ipa", conformingTo: .data) ?? .data
    static let windowsProgram = UTType(filenameExtension: "exe", conformingTo: .data) ?? .data
    static let windowsInstaller = UTType(filenameExtension: "msi", conformingTo: .data) ?? .data
}

struct AppsView: View {
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var busy = false
    @State private var recentlyImported: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dropZone
                if store.artifacts.isEmpty {
                    Text("导入的应用会出现在这里。点击「打开」会在后台实例中安装并启动，再显示独立的应用窗口。")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(store.artifacts) { artifact in
                            ArtifactCard(artifact: artifact, highlighted: recentlyImported.contains(artifact.id))
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("应用")
        .toolbar {
            ToolbarItem {
                Button { importing = true } label: { Label("导入应用", systemImage: "plus") }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.androidPackage, .iosPackage, .applicationBundle, .windowsProgram, .windowsInstaller],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { importURLs(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .twinsimImport)) { _ in importing = true }
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter { ["apk", "ipa", "app", "exe", "msi"].contains($0.pathExtension.lowercased()) }
            guard !accepted.isEmpty else { return false }
            importURLs(accepted)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var dropZone: some View {
        HStack(spacing: 16) {
            Image(systemName: busy ? "hourglass" : "square.and.arrow.down.on.square")
                .font(.system(size: 30)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(busy ? "正在导入…" : "拖入 APK、IPA、Simulator .app 或 Windows .exe/.msi").font(.headline)
                Text("APK 在 Android 模拟器中运行；Simulator .app 在 iOS Simulator 中运行；Windows 程序通过 Wine 在 Mac 上以原生窗口运行；真机 IPA 需要 iOS 研究虚拟机。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("选择文件…") { importing = true }.disabled(busy)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                 style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    private func importURLs(_ urls: [URL]) {
        busy = true
        Task {
            var scoped: [URL] = []
            for url in urls where url.startAccessingSecurityScopedResource() { scoped.append(url) }
            let imported = await store.importFiles(urls)
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            recentlyImported = Set(imported.map(\.id))
            busy = false
        }
    }
}

struct ArtifactCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let artifact: Artifact
    var highlighted = false

    @State private var confirmingDelete = false
    @State private var deleting = false

    private var launching: Bool { store.launching.contains(artifact.id) }
    private var workspace: Instance? {
        store.instances.first { $0.isAppWorkspace && $0.engineId == artifact.engineId }
    }
    private var blocker: UserNotice? { store.launchBlocker(for: artifact) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.name).font(.headline).lineLimit(2)
                    Text(artifact.bundleId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        .textSelection(.enabled)
                    Text(Labels.artifactKind(artifact.kind)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let blocker {
                Label(blocker.code == nil ? blocker.message : "本机暂不支持：\(blocker.code!)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    .help(blocker.message)
            } else if let op = launchOperation, !op.isTerminal {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(Labels.stage(op.stage) ?? "正在准备实例、安装并启动…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let workspace, workspace.isReady {
                Text(artifact.isWindows ? "Windows 环境运行中，程序窗口直接显示在桌面上" : "后台实例运行中，打开时复用已有安装与数据")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    Task { await store.open(artifact) }
                } label: {
                    if launching { ProgressView().controlSize(.small) } else { Label("打开", systemImage: "play.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(launching)
                Spacer()
                Menu {
                    let devices = store.instances.filter { $0.engineId == artifact.engineId && !$0.isAppWorkspace }
                    if devices.isEmpty { Text("没有同平台的设备") }
                    ForEach(devices) { device in
                        Button("在「\(device.displayName)」中打开") { Task { await store.open(artifact, instanceId: device.id) } }
                    }
                    if artifact.isWindows {
                        Divider()
                        Button("用 Windows 桌面（Wine）打开") { Task { await store.open(artifact, profileId: "windows-desktop") } }
                        Button("用 Windows 游戏（D3DMetal）打开") { Task { await store.open(artifact, profileId: "windows-d3dmetal") } }
                            .disabled(store.component("windows-d3dmetal")?.isReady != true)
                    }
                    if artifact.kind == "apk" {
                        Divider()
                        Button("在完整设备视图中打开") { Task { await store.open(artifact, forceDeviceView: true) } }
                        Divider()
                        ForEach(["android-aosp", "android-research", "android-magisk", "android-google-apis"], id: \.self) { profile in
                            Button("用 \(Labels.profile(profile)) 工作区打开") {
                                Task { await store.open(artifact, profileId: profile) }
                            }
                        }
                    }
                    Divider()
                    Button("复制 Bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(artifact.bundleId, forType: .string)
                    }
                    Text("SHA-256 \(artifact.sha256.prefix(12))…")
                    Divider()
                    Button("删除…", role: .destructive) { confirmingDelete = true }
                        .disabled(launching || deleting)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await store.open(artifact) } }
        .contextMenu {
            Button("打开") { Task { await store.open(artifact) } }
            Divider()
            Button("删除…", role: .destructive) { confirmingDelete = true }
        }
        .opacity(deleting ? 0.4 : 1)
        .overlay { if deleting { ProgressView() } }
        .alert("删除「\(artifact.name)」？", isPresented: $confirmingDelete) {
            Button("删除并从设备卸载", role: .destructive) { delete(uninstall: true) }
            Button("仅从应用库删除", role: .destructive) { delete(uninstall: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text(artifact.isWindows
                 ? "从应用库删除导入的文件。「删除并从设备卸载」会把它从 Windows 设备的 C:\\TwinSim\\Apps 中移除；.msi 安装包会先运行卸载程序（设备需在运行）。通过安装程序装进 Windows 的软件，请用设备研究工具里的「卸载程序」移除。"
                 : "从应用库删除导入的文件。「删除并从设备卸载」还会在运行中的设备上卸载它及其数据；未运行的设备会保留已安装的应用。")
        }
    }

    private func delete(uninstall: Bool) {
        deleting = true
        Task {
            await store.deleteArtifact(artifact, uninstall: uninstall)
            deleting = false
        }
    }

    private var launchOperation: BackendOperation? {
        guard launching else { return nil }
        return store.operationOrder.lazy.compactMap { store.operations[$0] }.first { $0.action == "open-app" }
    }

    private var icon: some View {
        let (symbol, color): (String, Color) = switch artifact.kind {
        case "apk": ("app.badge", .green)
        case "ipa": ("lock.iphone", .purple)
        case "windowsExe", "windowsMsi": ("pc", .cyan)
        default: ("iphone.gen3", .blue)
        }
        return Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
