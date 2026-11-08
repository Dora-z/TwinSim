import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var androidHome = ""
    @State private var developerDir = ""
    @State private var applying = false

    private var draft: BackendSettings { BackendSettings(androidHome: androidHome, developerDir: developerDir) }

    var body: some View {
        Form {
            Section {
                pathField("ANDROID_HOME", text: $androidHome, prompt: "使用 TwinSim 管理的 SDK",
                          check: androidCheck)
                pathField("DEVELOPER_DIR", text: $developerDir, prompt: "自动选择 Xcode",
                          check: xcodeCheck)
            } header: {
                Text("宿主工具链")
            } footer: {
                Text("留空时由后端自动选择。修改后会重新启动后端，已运行的设备继续由引擎管理并重新核对状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DataLocationSection()
            Section("后端") {
                LabeledContent("状态") { Text(statusText) }
                if let path = store.helperPath {
                    LabeledContent("Helper") { Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
                }
                if let home = ProcessInfo.processInfo.environment["TWINSIM_HOME"] {
                    LabeledContent("TWINSIM_HOME") { Text(home).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if !store.backendDiagnostics.isEmpty {
                    DisclosureGroup("后端输出") {
                        ScrollView {
                            Text(store.backendDiagnostics).font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 120)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("还原") { load() }.disabled(draft == store.settings)
                Button {
                    applying = true
                    Task { await store.applySettings(draft); applying = false }
                } label: {
                    if applying { ProgressView().controlSize(.small) } else { Text("应用并重启后端") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(applying || draft == store.settings)
            }
            .padding()
        }
        .onAppear(perform: load)
    }

    private var statusText: String {
        switch store.connection {
        case .connected: "已连接"
        case .failed(let message, _): "不可用：\(message)"
        case .restarting: "重启中"
        case .migrating(let progress, _): "正在移动数据 \(Int(progress * 100))%"
        default: "启动中"
        }
    }

    private func load() {
        androidHome = store.settings.androidHome
        developerDir = store.settings.developerDir
    }

    private func pathField(_ label: String, text: Binding<String>, prompt: String, check: (String) -> String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(label, text: text, prompt: Text(prompt)).font(.body.monospaced())
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.treatsFilePackagesAsDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
                }
            }
            if !text.wrappedValue.isEmpty, let warning = check(text.wrappedValue) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func androidCheck(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return "目录不存在。" }
        return fm.fileExists(atPath: path + "/platform-tools") || fm.fileExists(atPath: path + "/emulator")
            ? nil : "未找到 platform-tools 或 emulator，可能不是 Android SDK 目录。"
    }

    private func xcodeCheck(_ path: String) -> String? {
        if path.hasSuffix(".app") { return "请指向 Xcode.app/Contents/Developer。" }
        return FileManager.default.isExecutableFile(atPath: path + "/usr/bin/simctl") ? nil : "未找到 usr/bin/simctl，需要完整 Xcode 的 Contents/Developer 目录。"
    }
}

struct ActivityView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let ops = store.operationOrder.compactMap { store.operations[$0] }.filter { !["tap", "key"].contains($0.action) }
        Group {
            if ops.isEmpty {
                ContentUnavailableView("没有活动", systemImage: "clock", description: Text("安装、创建、启动等耗时操作会显示在这里。"))
            } else {
                Table(ops) {
                    TableColumn("操作") { op in Text(Labels.action(op.action)) }.width(min: 80, ideal: 100)
                    TableColumn("对象") { op in
                        Text(op.instanceId.flatMap { store.instance($0)?.displayName } ?? store.componentOps[op.id].map(Labels.component) ?? "—")
                    }
                    TableColumn("状态") { op in
                        HStack(spacing: 6) {
                            switch op.state {
                            case "succeeded": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                            default: ProgressView().controlSize(.mini)
                            }
                            if let fraction = op.fraction, !op.isTerminal {
                                Text("\(Labels.stage(op.stage) ?? "") \(Int(fraction * 100))%")
                            } else {
                                Text(op.error.map { "\($0.code)\($0.retryable ? "（可重试）" : "")" } ?? Labels.stage(op.stage) ?? op.state)
                            }
                        }
                        .help(op.error?.message ?? "")
                    }
                    TableColumn("ID") { op in Text(op.id.uuidString.prefix(8)).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        .width(80)
                }
            }
        }
        .navigationTitle("活动")
    }
}
