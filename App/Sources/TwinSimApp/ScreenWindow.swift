import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Device or single-application window: live picture with input, plus optional side panels for
/// logs and research tools.
struct ScreenWindow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: ScreenTarget
    @State private var session: ScreenSession?
    @State private var panel: Panel?
    @State private var text = ""

    enum Panel: String, Identifiable { case logs, tools; var id: String { rawValue } }

    private var instance: Instance? { store.instance(target.instanceId) }
    private var artifact: Artifact? { target.artifactId.flatMap(store.artifact) }
    private var title: String {
        if let artifact { return artifact.name }
        return instance?.displayName ?? "设备"
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                screen
                statusBar
            }
            .frame(minWidth: 280)
            if let panel, let instance {
                Divider()
                Group {
                    switch panel {
                    case .logs: LogsView(instanceId: instance.id, compact: false)
                    case .tools: ToolsPanel(instance: instance)
                    }
                }
                .frame(width: 380)
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .onAppear {
            // SwiftUI may disappear/reappear the window when it is brought forward again; keep
            // one session per window and only re-activate it.
            let session = self.session ?? ScreenSession(instanceId: target.instanceId, store: store)
            self.session = session
            store.register(session)
            session.activate()
        }
        .onDisappear { session?.deactivate() }
        .onChange(of: instance?.state) { _, _ in session?.instanceChanged() }
        .onChange(of: instance?.capabilities) { _, _ in session?.instanceChanged() }
    }

    private var subtitle: String {
        guard let instance else { return "" }
        if artifact != nil { return "\(Labels.profile(instance.profileId)) · 后台实例" }
        return "\(Labels.profile(instance.profileId)) · \(Labels.state(instance.state))"
    }

    @ViewBuilder private var screen: some View {
        ZStack {
            Color.black
            if let session {
                ScreenCanvas(session: session, interactive: instance?.can("input") == true)
                    .aspectRatio(session.contentSize.map { $0.width / max($0.height, 1) }, contentMode: .fit)
                overlay(session)
            }
        }
    }

    @ViewBuilder private func overlay(_ session: ScreenSession) -> some View {
        if let instance, !instance.isReady {
            VStack(spacing: 12) {
                if instance.isTransitioning { ProgressView().controlSize(.large).tint(.white) }
                Text("设备\(Labels.state(instance.state))").foregroundStyle(.white)
                if instance.state == "stopped" || instance.state == "failed" || instance.state == "unknown" {
                    Button("启动") { Task { await store.run(instance.id, "start") } }.buttonStyle(.borderedProminent)
                }
            }
        } else if session.contentSize == nil {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(session.status).foregroundStyle(.white.opacity(0.85)).font(.callout)
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let session {
                HStack(spacing: 8) {
                    Image(systemName: session.source == .video ? "dot.radiowaves.left.and.right" : "photo")
                        .foregroundStyle(session.source == .video && session.fps > 0 ? .green : .secondary)
                    Text(session.status).lineLimit(1)
                    Spacer()
                    if session.source == .video {
                        Text("\(Int(session.fps)) fps").monospacedDigit()
                        if let hw = session.hardwareDecoding { Text(hw ? "硬件解码" : "软件解码").foregroundStyle(hw ? .green : .orange) }
                    }
                    if let size = session.guestSize { Text("\(Int(size.width))×\(Int(size.height))").monospacedDigit() }
                    if session.liveInput { Image(systemName: "hand.tap.fill").foregroundStyle(.green).help("快速输入通道已连接") }
                    if session.pendingInputs > 0 { ProgressView().controlSize(.mini) }
                }
                if let error = session.videoError {
                    HStack {
                        Text(error).foregroundStyle(.orange).lineLimit(2)
                        Spacer()
                        if instance?.can("liveVideo") == true {
                            Button("重试实时画面") { session.retryVideo() }.controlSize(.small)
                        }
                    }
                }
                if let error = session.lastInputError {
                    Text("输入失败：\(error)").foregroundStyle(.red).lineLimit(2)
                }
                if (instance?.isAndroid == true && instance?.can("guestShell") == true) || (instance?.isWindows == true && instance?.can("input") == true) {
                    HStack {
                        TextField("向客体输入文本", text: $text).textFieldStyle(.roundedBorder)
                            .onSubmit { session.typeText(text); text = "" }
                        Button("发送") { session.typeText(text); text = "" }.disabled(text.isEmpty)
                    }
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if let instance, instance.can("input"), instance.isWindows {
                Button { session?.key("escape") } label: { Label("Esc", systemImage: "escape") }.help("Esc")
                Button { session?.key("enter") } label: { Label("回车", systemImage: "return") }.help("回车")
            }
            if let instance, instance.can("input"), !instance.isWindows {
                Button { session?.key("KEYCODE_BACK") } label: { Label("返回", systemImage: "chevron.backward") }
                    .help("返回")
                Button { session?.key("KEYCODE_HOME") } label: { Label("主屏幕", systemImage: "circle") }
                    .help("主屏幕")
                if instance.isAndroid {
                    Button { session?.key("KEYCODE_APP_SWITCH") } label: { Label("最近任务", systemImage: "square.on.square") }
                        .help("最近任务")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let artifact, let instance {
                Button {
                    Task { await store.run(instance.id, "launch", body: ["bundleId": artifact.bundleId]) }
                } label: { Label("重新启动应用", systemImage: "arrow.clockwise") }
                .help("在后台实例中重新启动该应用")
                .disabled(!instance.isReady)
            }
            if let session, instance?.can("liveVideo") == true {
                Button {
                    session.setPreferScreenshots(session.source == .video)
                } label: {
                    Label(session.source == .video ? "切换到截图" : "切换到实时画面",
                          systemImage: session.source == .video ? "photo" : "video")
                }
                .help(session.source == .video ? "切换到截图模式" : "切换到实时画面")
            }
            Button { saveScreenshot() } label: { Label("保存截图", systemImage: "camera") }
                .help("保存截图")
                .disabled(instance?.isReady != true)
            Button { panel = panel == .logs ? nil : .logs } label: { Label("日志", systemImage: "text.alignleft") }
                .help("日志")
            Button { panel = panel == .tools ? nil : .tools } label: { Label("研究工具", systemImage: "wrench.and.screwdriver") }
                .help("研究工具")
            if let instance, artifact == nil {
                Button {
                    Task { await store.run(instance.id, instance.isReady ? "stop" : "start") }
                } label: {
                    Label(instance.isReady ? "停机" : "启动", systemImage: instance.isReady ? "stop.fill" : "play.fill")
                }
                .help(instance.isReady ? "停机" : "启动")
                .disabled(instance.isTransitioning)
            }
        }
    }

    private func saveScreenshot() {
        guard let session else { return }
        Task {
            guard let image = await session.captureScreenshot(updateDisplay: false) else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(title)-\(Int(Date().timeIntervalSince1970)).png"
            guard panel.runModal() == .OK, let url = panel.url,
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
