import AppKit
import SwiftUI

/// Research tools, shown according to the instance capabilities reported by the backend.
struct ToolsPanel: View {
    @Environment(AppStore.self) private var store
    let instance: Instance

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("研究工具").font(.title3.bold())
                if let uid = instance.guestUid {
                    Text("客体 UID \(uid)\(instance.selinux.map { " · SELinux \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CapabilityGrid(instance: instance)
                section("windowsTools") { WindowsTools(instance: instance) }
                section("guestShell") { ShellTool(instance: instance) }
                section("guestRoot") { RootTool(instance: instance) }
                section("writableSystem") { WritableSystemTool(instance: instance) }
                section("snapshot") { SnapshotTool(instance: instance) }
                section("guestFiles") { FileTransferTool(instance: instance) }
                section("portForward") { PortForwardTool(instance: instance) }
            }
            .padding(14)
        }
    }

    /// Supported capabilities get a section; blocked ones are shown disabled with their reason.
    @ViewBuilder private func section<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        if let cap = instance.capability(key), cap.isSupported {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if !cap.isAvailable {
                        Text(Labels.reason(cap.reasonCode) ?? cap.reasonCode ?? "暂不可用")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    content().disabled(!cap.isAvailable)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                Text(Labels.capability(key)).font(.headline)
            }
        }
    }
}

struct ShellTool: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var command = "id"
    @State private var output = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("命令", text: $command).textFieldStyle(.roundedBorder).font(.body.monospaced())
                    .onSubmit(run)
                Button(action: run) { running ? AnyView(ProgressView().controlSize(.small)) : AnyView(Text("运行")) }
                    .disabled(running || command.isEmpty)
            }
            Text(instance.isWindows ? "通过 Wine 的 cmd /c 执行。" : "通过 /system/bin/sh -c 执行，参数以 argv 传给后端。")
                .font(.caption2).foregroundStyle(.secondary)
            if !output.isEmpty {
                ScrollView {
                    Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func run() {
        running = true
        let argv = instance.isWindows ? ["cmd", "/c", command] : [instance.isAndroid ? "sh" : "/bin/sh", "-c", command]
        Task {
            if let op = await store.run(instance.id, "shell", body: ["argv": argv]) {
                let r = op.result ?? [:]
                if let guest = r["guestResult"] {
                    output = guest
                } else {
                    output = (r["stdout"] ?? "") + ((r["stderr"]?.isEmpty ?? true) ? "" : "\n[stderr]\n" + r["stderr"]!)
                        + "\n[exit \(r["exitCode"] ?? "?")]"
                }
            }
            running = false
        }
    }
}

struct RootTool: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var result: String?
    @State private var running = false

    var body: some View {
        HStack {
            Button("验证客体 root") {
                running = true
                Task {
                    let op = await store.run(instance.id, "root")
                    result = op.map { "UID \($0.result?["uid"] ?? "?")" }
                    running = false
                }
            }
            .disabled(running)
            if running { ProgressView().controlSize(.small) }
            if let result { Text(result).font(.callout.monospaced()) }
        }
    }
}

struct WritableSystemTool: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("启用后会重启客体并挂载 OverlayFS。关闭后恢复只读系统分区。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("启用可写") { toggle("on") }
                Button("恢复只读") { toggle("off") }
                if running { ProgressView().controlSize(.small) }
            }
            .disabled(running)
        }
    }

    private func toggle(_ value: String) {
        running = true
        Task { await store.run(instance.id, "writable-system", body: ["value": value]); running = false }
    }
}

struct SnapshotTool: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var name = "baseline"
    @State private var running = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("快照名称", text: $name).textFieldStyle(.roundedBorder)
                Button("保存") { act("snapshot-save") }
                Button("恢复") { act("snapshot-load") }
                if running { ProgressView().controlSize(.small) }
            }
            .disabled(running)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Text("名称限字母、数字、- 和 _，最长 48 个字符。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func act(_ action: String) {
        guard name.range(of: "^[A-Za-z0-9_-]{1,48}$", options: .regularExpression) != nil else {
            message = "名称无效。"; return
        }
        running = true
        Task {
            if await store.run(instance.id, action, body: ["snapshot": name]) != nil {
                message = action == "snapshot-save" ? "已保存「\(name)」" : "已恢复「\(name)」"
            }
            running = false
        }
    }
}

struct FileTransferTool: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var remoteDir = "/data/local/tmp"
    @State private var pullPath = "/data/local/tmp/"
    @State private var running = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("客体目录", text: $remoteDir).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                Button("传入文件…", action: push)
            }
            HStack {
                TextField("客体文件路径", text: $pullPath).textFieldStyle(.roundedBorder).font(.callout.monospaced())
                Button("导出…", action: pull)
            }
            if running { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("单个文件上限 128 MB。").font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(running)
        .onAppear {
            if instance.isWindows { remoteDir = #"C:\users\Public"#; pullPath = #"C:\users\Public\"# }
            else if !instance.isAndroid { remoteDir = "/var/root"; pullPath = "/var/root/" }
        }
    }

    private func push() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let separator = instance.isWindows ? "\\" : "/"
        let remote = (remoteDir.hasSuffix(separator) ? remoteDir : remoteDir + separator) + url.lastPathComponent
        running = true
        Task {
            if await store.run(instance.id, "guest-push", body: ["localPath": url.path, "remotePath": remote]) != nil {
                message = "已传入 \(remote)"
            }
            running = false
        }
    }

    private func pull() {
        let absolute = instance.isWindows ? pullPath.count > 3 && pullPath.dropFirst().hasPrefix(":\\") : pullPath.hasPrefix("/")
        guard absolute, !pullPath.hasSuffix("/"), !pullPath.hasSuffix("\\") else { message = "请输入完整的客体文件路径。"; return }
        running = true
        Task {
            defer { running = false }
            do {
                guard let client = store.client else { throw APIError.disconnected }
                let data = try await client.guestFile(instance.id, path: pullPath)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = URL(fileURLWithPath: pullPath.replacingOccurrences(of: "\\", with: "/")).lastPathComponent
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url)
                message = "已导出 \(Labels.bytes(Int64(data.count))) 到 \(url.path)"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

struct PortForwardTool: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var guestPort = "27042"
    @State private var forwards: [(local: Int, guest: Int)] = []
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("客体 TCP 端口", text: $guestPort).textFieldStyle(.roundedBorder).frame(width: 120)
                Button("转发") { forward() }.disabled(Int(guestPort) == nil || running)
                if running { ProgressView().controlSize(.small) }
            }
            ForEach(forwards, id: \.local) { item in
                HStack {
                    Text("127.0.0.1:\(String(item.local)) → 客体 \(String(item.guest))").font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("127.0.0.1:\(item.local)", forType: .string)
                    }
                    Button("取消") { unforward(item.local) }
                }
            }
            Text("可用于 Frida 等客户端连接客体中由你启动的服务。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func forward() {
        guard let port = Int(guestPort), (1...65535).contains(port) else { return }
        running = true
        Task {
            if let op = await store.run(instance.id, "forward", body: ["guestPort": port]),
               let local = op.result?["localPort"].flatMap(Int.init) {
                forwards.append((local, port))
            }
            running = false
        }
    }

    private func unforward(_ local: Int) {
        Task {
            if await store.run(instance.id, "unforward", body: ["localPort": local]) != nil {
                forwards.removeAll { $0.local == local }
            }
        }
    }
}

/// Windows (Wine) device tools: built-in Windows utilities, graphics and display settings.
struct WindowsTools: View {
    @Environment(AppStore.self) private var store
    let instance: Instance
    @State private var message: String?
    @State private var running = false

    private let tools: [(String, String, String)] = [
        ("winecfg", "Wine 设置", "gearshape"), ("explorer", "文件管理器", "folder"), ("regedit", "注册表编辑器", "list.bullet.indent"),
        ("taskmgr", "任务管理器", "chart.bar"), ("cmd", "命令提示符", "terminal"), ("control", "控制面板", "slider.horizontal.3"),
        ("uninstaller", "卸载程序", "trash"), ("notepad", "记事本", "doc.text"),
    ]

    private var driveC: URL {
        URL(fileURLWithPath: store.dataDirectory)
            .appendingPathComponent("wine/prefixes/twinsim-\(instance.id.uuidString.lowercased())/drive_c")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(tools, id: \.0) { tool in
                    Button { act("wine-tool", tool.0) } label: { Label(tool.1, systemImage: tool.2) }
                        .disabled(!instance.isReady || running)
                }
            }
            Button { NSWorkspace.shared.open(driveC) } label: { Label("在 Finder 中打开 C 盘", systemImage: "externaldrive") }
                .disabled(!FileManager.default.fileExists(atPath: driveC.path))
            Divider()
            HStack {
                Text("图形加速（DXVK）")
                Spacer()
                Button("开启") { act("dxvk", "on") }.disabled(instance.capability("dxvk")?.isAvailable != true || running)
                Button("关闭") { act("dxvk", "off") }.disabled(!instance.isReady || running)
            }
            if let reason = instance.capability("dxvk")?.reasonCode {
                Text(Labels.reason(reason) ?? reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("显示")
                Spacer()
                Button("Retina 清晰") { act("display", "retina") }.disabled(!instance.isReady || running)
                Button("标准 96 DPI") { act("display", "standard") }.disabled(!instance.isReady || running)
            }
            Text("Retina 模式按 192 DPI 渲染，文字清晰；个别老程序界面过大或错位时改用标准模式。设置对之后启动的程序生效。")
                .font(.caption2).foregroundStyle(.secondary)
            if running { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func act(_ action: String, _ value: String) {
        running = true
        Task {
            if let op = await store.run(instance.id, action, body: ["value": value]) {
                message = op.result?["note"] ?? "已完成"
            }
            running = false
        }
    }
}
