# TwinSim macOS 前端

前端是 `App/` 下独立的 Swift Package（SwiftUI 为主，画面窗口用 AppKit 与 VideoToolbox），不依赖 Vapor。打包脚本把它与 `twinsimd`、`jidr` 和后端许可声明组装成 Apple Silicon 的 `TwinSim.app`。

## 目录

| 文件 | 内容 |
| --- | --- |
| `App/Sources/TwinSimApp/BackendProcess.swift` | 以当前用户启动内置 `twinsimd`，读取 stdout 一行 JSON 握手，保留 stderr 尾部用于诊断，SIGTERM→SIGKILL 退出，记录 PID 以便下次启动时回收崩溃遗留的 helper |
| `APIClient.swift` | 带 `Authorization: Bearer` 的 HTTP 客户端，错误体解析为 `code`/`message`/`retryable`，长操作附 `Idempotency-Key` |
| `EventStream.swift` | `/v1/events` SSE：增量解析，按 `Last-Event-ID` 重连，后端约每 60 秒关闭一次流 |
| `AppStore.swift` | 连接状态、组件/引擎/实例/应用缓存、操作跟踪（SSE + 轮询兜底）、helper 意外退出后的退避重启 |
| `H264.swift` | Annex B 解析（跨网络分块的起始码、尾随零、4 MB 缓冲上限后重同步）、访问单元组装、VideoToolbox 解码 |
| `VideoStream.swift` | `/video` 订阅（URLSession 数据回调，串行队列解码），空闲 45 ms 刷出尾部 NAL，等待关键帧过久时重连 |
| `ScreenSession.swift` | 画面来源选择（实时/截图）、重连与回退、客体尺寸、触控坐标换算、串行输入队列 |
| `ScreenCanvas.swift` / `ScreenWindow.swift` | AppKit 画面视图（IOSurface → CALayer）、点击/拖动、设备与单应用窗口 |
| `ComponentsView.swift` | 首次使用：组件状态、安装阶段与字节进度、许可原文确认、外部配置入口与重新检查 |
| `DevicesView.swift` / `AppsView.swift` | 「设备」「应用」两个入口 |
| `ToolsPanel.swift` / `LogsView.swift` | 按能力显示的研究工具、日志 |
| `SettingsView.swift` | `ANDROID_HOME`、`DEVELOPER_DIR` 可选设置，后端状态与输出 |
| `SelfTest.swift` | 联调自测，仅在设置 `TWINSIM_SELF_TEST` 时启用 |
| `AgentBridge.swift` / `AISettingsView.swift` | AI 接入：仅当前用户可连的本机套接字，以及设置中的「AI 集成」页 |
| `App/Sources/twinsimctl/` | `twinsim` 命令：MCP 服务器、命令行和函数调用定义导出，详见 [AI 接入](ai.md) |
| `App/Sources/TwinSimAgentProtocol/` | 应用与 `twinsim` 共用的套接字协议 |

## 与后端的约定

- **启动与认证**：令牌只保存在内存中的 `APIClient`，不写入磁盘或日志。不向子进程传递 `TWINSIM_TOKEN`、`TWINSIM_ORIGIN`、`TWINSIM_PORT`。设置中的 `ANDROID_HOME`（同时导出 `ANDROID_SDK_ROOT`）与 `DEVELOPER_DIR` 非空时写入子进程环境，修改后重启后端。应用自身环境中的 `TWINSIM_HOME` 等变量原样传给 helper，可用于隔离测试。
- **意外退出**：helper 退出后 1/2/4/8 秒退避重启，2 分钟内超过 4 次则停下并显示后端输出。重启后重新握手、重订阅 SSE、重读列表，实例的 `unknown` 状态由后端与引擎核对。打开的画面窗口自动重连。
- **长操作**：所有 202 请求都带新的 `Idempotency-Key`，网络错误时用同一个键重发。操作状态来自 SSE `operation` 事件，同时每 1.5–4 秒查询 `/v1/operations/{id}` 兜底。`instance` 事件不含能力，前端收到后重新读取该实例。收到 `reset` 时重读组件、实例、应用并核对未完成操作。
- **输入**：后端对同一实例串行执行操作，前端把触控、按键、文本与滑动排成队列逐个提交，遇到 `RESOURCE_BUSY` 稍后重试。拖动映射为 `input swipe`，文本映射为 `input text`，两者都需要客体 shell 能力。
- **画面**：Android 优先使用 `/video`（scrcpy 输出最长边 1280），失败时退避重连，同一实例被占用时等待旧订阅释放，连续失败后回退截图。触控按截图得到的客体真实分辨率换算（例如 1080×2400），不按视频分辨率。iOS Simulator 使用截图轮询，不显示触控入口。
- **单应用模式**：「应用」页的「打开」调用 `/v1/artifacts/{id}/launch`，后台复用应用工作区实例和已有安装，完成后打开独立应用窗口。APK 在 AOSP 运行环境就绪时使用 `android-aosp`，否则使用已就绪的 `android-google-apis`。IPA 在 `ios-vphone` 处于 `externalSetup` 时直接显示宿主机阻塞原因和上游配置链接，不提交启动。
- **退出**：仍有运行中的设备时询问「停机后退出」或「保持运行并退出」，之后向 helper 发 SIGTERM。

## 构建

需要 Apple Silicon、macOS 15 或更高版本，以及 Swift 6 工具链（完整 Xcode 或 Command Line Tools）。

```bash
# 前端调试构建与单元测试
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer swift build --package-path App
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer swift test --package-path App

# 打包（后端载荷缺失时会先运行 scripts/package-backend.sh）
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer bash scripts/package-app.sh
```

输出 `dist/TwinSim.app` 和 `dist/TwinSim.dmg`。应用包结构：

```
TwinSim.app/Contents/
  MacOS/TwinSim                    前端
  Helpers/twinsimd                 后端
  Helpers/jidr                     Android 引擎 helper
  Helpers/twinsim                  AI 接入：MCP 服务器与命令行
  Resources/AI/                    Claude Code 技能与 AGENTS.md 片段
  Resources/BackendNotices/        第三方许可声明
  Resources/AppIcon.icns
  Info.plist                       注册 .apk / .ipa 为可打开类型（Alternate）
```

调试构建（`swift run --package-path App`）会向上查找 `.build/backend-payload/Contents/Helpers/twinsimd`，也可用 `TWINSIM_DAEMON=/path/to/twinsimd` 指定。

## 签名与公证

- 未设置 `TWINSIM_SIGN_IDENTITY` 时，helper 和应用使用 ad hoc 签名并启用 hardened runtime，适合本机使用。其他 Mac 上 Gatekeeper 会拒绝，需要右键打开或移除隔离属性。
- 发行时：

```bash
xcrun notarytool store-credentials twinsim-notary --apple-id <id> --team-id <team>
TWINSIM_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAM>)" \
TWINSIM_NOTARY_PROFILE=twinsim-notary \
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer bash scripts/package-app.sh
```

脚本先以 hardened runtime 和时间戳签名 `Helpers/*`，再签名应用和 DMG，提交公证，完成后对 DMG 和应用 staple，并运行 `spctl --assess`。

## 联调

```bash
ANDROID_HOME=/Volumes/External/Android \
DEVELOPER_DIR=/Volumes/External/Applications/Xcode.app/Contents/Developer \
bash scripts/make-test-samples.sh .build/test-samples
bash scripts/frontend-e2e.sh
```

`frontend-e2e.sh` 通过 `open -W -n --env …` 启动应用，使其与 Finder 双击时一样运行在用户 GUI 会话中。从无 GUI 会话的 shell 直接执行二进制时，iOS Simulator 无法启动。`TWINSIM_SELF_TEST_PLATFORMS` 可选 `android,ios,ipa,device` 的子集，`device` 覆盖「设备」页的创建、启动、设备窗口、研究工具、日志和停机。

`make-test-samples.sh` 生成三份样本：会绘制并记录每次触控坐标的 `TouchProbe.apk`、ARM64 Simulator `TouchProbe.app`、device `TouchProbeDevice.ipa`。`frontend-e2e.sh` 用独立的 `TWINSIM_HOME` 启动打包后的应用，自测通过真实窗口、解码器和输入换算执行导入、启动、画面、触控、再次打开、断线重连、截图回退、helper 崩溃恢复和停机，结果写入 `.build/e2e/report/report.md` 及截图。主机路径通过应用设置（`defaults write com.twinsim.app androidHome|developerDir`）传入，与用户在设置中填写的路径相同。
