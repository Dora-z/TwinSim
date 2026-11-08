import AppKit
import SwiftUI
import TwinSimAgentProtocol

/// Settings tab for AI integration: agent bridge switch, CLI install, MCP client configuration.
struct AISettingsView: View {
    @Environment(AppStore.self) private var store
    @AppStorage(AgentBridge.enabledKey) private var enabled = true
    @State private var message: String?
    @State private var tick = 0

    private var cli: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/twinsim").path }
    private var cliExists: Bool { FileManager.default.isExecutableFile(atPath: cli) }
    private var home: String? { ProcessInfo.processInfo.environment["TWINSIM_HOME"] }
    private var skillSource: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AI/skills/twinsim") }

    var body: some View {
        Form {
            Section {
                Toggle("允许 AI 工具连接 TwinSim", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on { store.agentBridge?.start() } else { store.agentBridge?.stop() }
                        tick += 1
                    }
                LabeledContent("状态") { Text(bridgeStatus).foregroundStyle(.secondary).id(tick) }
                LabeledContent("套接字") {
                    Text(AgentProtocol.socketPath()).font(.caption.monospaced()).textSelection(.enabled)
                }
            } header: {
                Text("本机连接")
            } footer: {
                Text("MCP 服务器和 twinsim 命令通过仅当前用户可访问的 Unix 套接字连接正在运行的 TwinSim，后端令牌不会离开本应用。AI 的操作会显示在「活动」中。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("命令行工具") {
                LabeledContent("twinsim") {
                    HStack {
                        Text(cliExists ? cli : "开发构建中没有内置 CLI").font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                        if cliExists { copyButton(cli) }
                    }
                }
                HStack {
                    Button("安装到 ~/.local/bin/twinsim") { installCLI() }.disabled(!cliExists)
                    Button("安装 Claude Code 技能") { installSkill() }
                        .disabled(!FileManager.default.fileExists(atPath: skillSource.path))
                    Button("复制 AGENTS.md 片段") { copy(agentsSnippet) }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }

            Section {
                configRow("Claude Code", claudeCode)
                configRow("Claude Desktop / Cursor / Windsurf / Gemini CLI（mcpServers JSON）", mcpServersJSON)
                configRow("VS Code（.vscode/mcp.json）", vscodeJSON)
                configRow("Codex CLI（~/.codex/config.toml）", codexTOML)
            } header: {
                Text("MCP 客户端配置")
            } footer: {
                Text("其他框架（OpenAI、Anthropic、Gemini 函数调用，LangChain 等）：`twinsim tools --format openai|anthropic|gemini` 输出工具定义，`twinsim call <tool> '<json>'` 执行调用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var bridgeStatus: String {
        guard let bridge = store.agentBridge else { return "未启动" }
        if bridge.isListening { return "正在监听 · \(bridge.connectedClients) 个连接" }
        return bridge.lastError.map { "未监听：\($0)" } ?? (enabled ? "未监听" : "已关闭")
    }

    private func configRow(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                copyButton(text)
            }
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button { copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "已复制。"
    }

    // MARK: Snippets

    private var envJSON: String { home.map { ", \"env\": {\"TWINSIM_HOME\": \"\($0)\"}" } ?? "" }

    private var claudeCode: String {
        let env = home.map { " -e TWINSIM_HOME=\"\($0)\"" } ?? ""
        return "claude mcp add --scope user\(env) twinsim -- \"\(cli)\" mcp"
    }

    private var mcpServersJSON: String {
        "{\n  \"mcpServers\": {\n    \"twinsim\": { \"command\": \"\(cli)\", \"args\": [\"mcp\"]\(envJSON) }\n  }\n}"
    }

    private var vscodeJSON: String {
        "{\n  \"servers\": {\n    \"twinsim\": { \"type\": \"stdio\", \"command\": \"\(cli)\", \"args\": [\"mcp\"]\(envJSON) }\n  }\n}"
    }

    private var codexTOML: String {
        var text = "[mcp_servers.twinsim]\ncommand = \"\(cli)\"\nargs = [\"mcp\"]"
        if let home { text += "\nenv = { TWINSIM_HOME = \"\(home)\" }" }
        return text
    }

    private var agentsSnippet: String {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AI/AGENTS.md")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "Use the `twinsim` CLI (`twinsim help`) to run and test mobile apps on this Mac."
    }

    // MARK: Install

    private func installCLI() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = dir.appendingPathComponent("twinsim")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil || FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: cli)
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            message = "已创建 \(link.path) → \(cli)。" + (path.contains(dir.path) ? "" : " 如终端找不到 twinsim，请把 ~/.local/bin 加入 PATH。")
        } catch {
            message = "安装失败：\(error.localizedDescription)"
        }
    }

    private func installSkill() {
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/twinsim")
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: skillSource, to: target)
            message = "技能已安装到 \(target.path)。Claude Code 下次启动时会加载。"
        } catch {
            message = "安装失败：\(error.localizedDescription)"
        }
    }
}
