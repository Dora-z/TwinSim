# 让 AI 使用 TwinSim

TwinSim 为 AI 提供四种接入方式，底层是同一组工具（共 31 个）。

| 方式 | 适用 | 入口 |
| --- | --- | --- |
| MCP 服务器 | Claude Code、Claude Desktop、Cursor、Windsurf、VS Code Copilot、Codex CLI、Gemini CLI 等支持 MCP 的客户端 | `twinsim mcp`（stdio） |
| 命令行 | 能运行 shell 命令的编码代理（Claude Code、Codex、Aider 等）、脚本、CI | `twinsim <tool> --参数 值`，`twinsim call <tool> '<json>'` |
| 函数调用定义 | 自己写的 AI 程序：OpenAI / Anthropic / Gemini 函数调用、LangChain、LlamaIndex 等框架 | `twinsim tools --format openai\|anthropic\|gemini\|mcp` 导出定义，`twinsim call` 执行 |
| 技能与指令文件 | Claude Code 技能，以及 AGENTS.md、CLAUDE.md、Cursor rules、Copilot instructions | `ai/skills/twinsim/SKILL.md`、`ai/AGENTS.md` |

`twinsim` 位于 `TwinSim.app/Contents/Helpers/twinsim`。在 TwinSim「设置 > AI 集成」中可以：

- 把它链接到 `~/.local/bin/twinsim`
- 安装 Claude Code 技能
- 复制各客户端的 MCP 配置，路径已填好

## 工作原理

```
AI 客户端 ──stdio/MCP 或命令行──▶ twinsim ──Unix 套接字（仅当前用户）──▶ TwinSim.app ──HTTP + 令牌──▶ twinsimd
```

- `twinsim` 不保存后端令牌。它连接正在运行的 TwinSim.app 的本机套接字 `<数据目录>/agent.sock`（权限 0600，应用会校验对端 UID），由应用转发请求时附上令牌。
- TwinSim 未运行时，`twinsim` 会通过 `open -g -j` 在后台启动它，并等待后端就绪。经 LaunchServices 启动能保证 iOS Simulator 可以启动。
- AI 发起的操作与界面操作是同一批后端操作，会出现在 TwinSim 的「活动」和设备状态中。`open_app` 和 `show_device` 会打开画面窗口，用户可以看到 AI 在做什么。
- 关闭「设置 > AI 集成 > 允许 AI 工具连接 TwinSim」即可禁止所有 AI 连接。
- 设置了 `TWINSIM_HOME` 时，`twinsim` 会连接对应数据目录的实例，与应用使用同一规则。

## 配置 MCP 客户端

下文的 `<cli>` 指 `/Applications/TwinSim.app/Contents/Helpers/twinsim`，或「设置 > AI 集成」中显示的实际路径。

**Claude Code**

```bash
claude mcp add --scope user twinsim -- "/Applications/TwinSim.app/Contents/Helpers/twinsim" mcp
```

**Claude Desktop**：编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`。**Cursor**：编辑 `~/.cursor/mcp.json`。**Windsurf**：编辑 `~/.codeium/windsurf/mcp_config.json`。**Gemini CLI**：编辑 `~/.gemini/settings.json`。它们使用同一格式：

```json
{ "mcpServers": { "twinsim": { "command": "<cli>", "args": ["mcp"] } } }
```

**VS Code**（`.vscode/mcp.json` 或用户配置）：

```json
{ "servers": { "twinsim": { "type": "stdio", "command": "<cli>", "args": ["mcp"] } } }
```

**Codex CLI**（`~/.codex/config.toml`）：

```toml
[mcp_servers.twinsim]
command = "<cli>"
args = ["mcp"]
```

MCP 服务器在 `initialize` 中返回使用说明，包括推荐流程、坐标规则、平台限制和许可确认规则。客户端会把这些说明提供给模型。工具带有 `readOnlyHint` 和 `destructiveHint` 标注。

## 工具

| 类别 | 工具 |
| --- | --- |
| 概览 | `status`、`list_components`、`list_devices`、`list_apps` |
| 组件 | `install_component`（需要许可时先返回原文，`acceptLicenses=true` 只能在用户明确同意后使用） |
| 设备 | `create_device`、`start_device`、`stop_device`、`show_device` |
| 应用 | `import_app`、`open_app`（可直接传文件路径，复用后台实例和已有安装）、`launch_app`、`uninstall_app` |
| 观察 | `screenshot`、`ui_tree`（Android 控件树：文本、resource-id、content-desc、可点击、中心点）、`wait_for_text`、`logs` |
| 操作 | `tap`、`tap_element`（按文本、ID 或描述点击）、`swipe`、`type_text`、`press_key` |
| 研究 | `shell`、`verify_root`、`set_writable_system`、`snapshot`、`push_file`、`pull_file`、`port_forward`、`remove_port_forward` |
| 长操作 | `wait_operation` |

设备参数可以是完整 ID、唯一的 ID 前缀或设备名。应用参数可以是 ID、bundle ID 或名称。出错时返回 `isError` 及错误码，并在 `Hint:` 一行给出下一步建议，例如 vphone 宿主机未配置时提示告诉用户、不要重试。

### 坐标

视觉模型会缩小过大的图片，像素坐标因此会错位。所以 MCP 返回的截图把长边缩放到 `TWINSIM_MAX_EDGE`（默认 1280）。`tap`、`swipe` 和 `ui_tree` 都使用这张图的像素坐标，由 TwinSim 换算回客体像素。例如客体 1080×2400、截图 576×1280 时，点击 (288,640) 实际点在客体 (540,1200)。传 `coordinateSpace: "guest"` 可直接使用客体像素。命令行默认返回原始分辨率，坐标即客体像素。

### 平台能力

- Android：全部工具可用。`android-research` 和 `android-google-apis` 配置提供 adb root、系统可写和快照。
- iOS Simulator：截图、日志、打开和停止应用。后端不支持输入，`tap` 等工具会返回 `CAPABILITY_UNSUPPORTED`。
- iOS 真机 IPA：需要 vphone 研究虚拟机。宿主机未配置时，`open_app` 返回 `RESEARCH_GUESTS_DISABLED` 等原因。

## 命令行示例

```bash
twinsim status
twinsim open_app --path ~/build/app-debug.apk          # 返回设备 id
twinsim screenshot --device 1a9b --output /tmp/s.png   # id 前缀即可
twinsim ui_tree --device 1a9b
twinsim tap_element --device 1a9b --text "登录"
twinsim type_text --device 1a9b --text "hello world"
twinsim press_key --device 1a9b --key enter
twinsim logs --device 1a9b --filter MyApp --lines 500
twinsim shell --device 1a9b --command "dumpsys activity top | head -30"
twinsim stop_device --device 1a9b
twinsim call tap '{"device":"1a9b","x":540,"y":1200}' --json
```

退出码：0 表示成功，1 表示工具报错（输出中包含错误码和提示），2 表示参数错误。加 `--json` 输出结构化结果，图片写入 `--output` 指定的路径。

## 在自己的程序中使用函数调用

```python
import json, subprocess
CLI = "/Applications/TwinSim.app/Contents/Helpers/twinsim"
tools = json.loads(subprocess.check_output([CLI, "tools", "--format", "anthropic"]))  # 或 openai / gemini

def run_tool(name, arguments):
    r = subprocess.run([CLI, "call", name, json.dumps(arguments), "--json"], capture_output=True, text=True)
    return json.loads(r.stdout)   # {"isError": bool, "content": [{"type":"text",...} | {"type":"image","path":...}]}
```

把 `tools` 传给模型。模型发出工具调用时执行 `run_tool`，再把结果作为工具结果回传。图片会写入临时文件，结果中给出路径，可读取后以图片内容回传。

## 技能与指令文件

- Claude Code 技能：在「设置 > AI 集成」点「安装 Claude Code 技能」，或执行 `cp -R ai/skills/twinsim ~/.claude/skills/`。技能说明了何时使用 TwinSim 以及命令行流程。
- 其他代理：把 `ai/AGENTS.md` 的内容加入项目的 `AGENTS.md`（Codex、Jules 等）、`CLAUDE.md`、`.cursor/rules` 或 `.github/copilot-instructions.md`。

## 验证

`python3 scripts/agent-e2e.py` 以 MCP 客户端身份驱动打包后的应用，使用独立的 `TWINSIM_HOME`，且不预先启动应用。实测结果见 [前端联调记录](frontend-validation.md#ai-集成)。
