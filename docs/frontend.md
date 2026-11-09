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
- **数据位置**：设置中的「数据位置」决定 `TWINSIM_HOME`，包括 Android 设备（AVD、快照、TwinSim 管理的 SDK）、Simulator 设备集、导入的应用和下载的引擎，可放在 APFS 或 HFS+ 格式的外置硬盘上，exFAT/FAT/NTFS 会被拒绝。「移动到其他位置」的流程：先停止设备和后端，并停止该目录的 Jidr 守护进程；再用 `ditto` 复制（保留权限、扩展属性和稀疏文件），改写 AVD `.ini` 中的绝对路径；然后从新位置启动后端，确认成功后才删除原数据，任一步失败都回到原位置。选中的文件夹里已有 TwinSim 数据时，直接切换过去。启动时如果自定义位置不存在（例如外置硬盘未连接），不会启动后端，以免在 `/Volumes` 下创建空目录，并提供重试和改用默认位置两个选项。
- **Windows 程序（Wine）**：组件 `windows-wine` 下载并校验固定版本的 WineHQ 上游 macOS 构建（Gcenx `wine-staging 11.21`，SHA-256 固定，不依赖 CrossOver），安装到数据目录的 `runtime/`。程序经 Rosetta 2 转译运行；Wine 采用新 WoW64 模式，32 位程序无需 32 位宿主库；Wine Mono 与 Gecko 已随包附带。一台 Windows 设备就是一个 Wine 前缀（`wine/prefixes/<设备>`）。启动时以常驻模式运行 `wineserver -p`；是否在运行，通过查找 `WINEPREFIX` 指向该前缀的 Wine 进程判断。导入的 `.exe` 会复制到 `C:\TwinSim\Apps\<id>\` 再运行，`.msi` 用 `msiexec /i` 安装。程序以原生 Mac 窗口显示，单应用模式不再另开 TwinSim 画面窗口。截图用 `screencapture -l` 截取该前缀最前面的窗口，需要录屏权限；点击、按键、文本用 CGEvent，需要辅助功能权限。默认性能设置：`WINEDEBUG=fixme-all`（只保留错误输出）、`ROSETTA_ADVERTISE_AVX=1`、禁用 `winemenubuilder`（不在宿主创建菜单和文件关联）、Retina 模式加 192 DPI、关闭崩溃对话框。可选组件 `windows-dxvk`（DXVK-macOS 1.10.3 async，builtin 版）按设备开启，通过 `WINEDLLPATH_PREPEND` 和 `DXVK_ASYNC=1` 生效，不修改前缀和 Wine 运行时；没开启时，Direct3D 走 Wine 的 Vulkan 渲染 → MoltenVK → Metal。设置 `TWINSIM_WINE` 可指定其他 Wine，设置 `TWINSIM_WINEDEBUG` 可调整日志级别。
- **Android 应用窗口**：在「应用」中打开 APK 时，只显示应用本身。窗口是独立的 Mac 窗口，没有 Android 状态栏和导航栏，可调整大小；关闭窗口即关闭应用，多个应用可以同时打开。后端为每个窗口启动一个 scrcpy 服务端，通过 `new_display=<宽>x<高>/<dpi>`、`flex_display=true`、`vd_system_decorations=false` 和 `vd_destroy_content=true` 创建虚拟显示器，并经控制通道发送 `START_APP`，让应用在该显示器上启动。前端与后端之间用 WebSocket `/v1/instances/{id}/app-session` 传输：出方向是 H.264，入方向是 scrcpy 控制消息，后端只放行触控、滚动、按键、文本、粘贴、返回和调整显示器大小这几类。1 dp 对应 1 个 Mac 点；画面密度可在设置中选择：清晰 2×、均衡 1.5×（默认）、流畅 1×。鼠标即手指，触控板和滚轮用于滚动，键盘和输入法可直接输入（非 ASCII 文本通过剪贴板粘贴），Esc 或右键为返回，⌘V 粘贴 Mac 剪贴板。可在设置中关闭此功能，或在应用菜单中选择「在完整设备视图中打开」。部分银行、支付类应用（例如招商银行）会把运行在非主显示器上视为屏幕共享，弹出警告并拒绝使用。这类应用可在窗口工具栏点「改用设备视图」，或在应用菜单中勾选「总是在设备视图中打开」；TwinSim 按包名记住选择（`deviceViewPackages`）。TwinSim 不修改虚拟显示器的标识来绕过这类检测。
- **Android 性能**：
  - 模拟器只有软件视频编码器（`c2.android.avc.encoder`），因此 CPU 核心和内存可以自定义：
    - **默认值**：「设置 > Android 模拟器资源」，自动为一半宿主核心（2–6 个）和 3 GB（宿主内存 ≥32 GB 时为 4 GB），也可固定为指定值。经 `TWINSIM_ANDROID_CPUS`、`TWINSIM_ANDROID_RAM_MB` 传给后端，修改后重启后端。
    - **单台设备**：创建时可单独设置；设备页「硬件」可修改或恢复默认（动作 `hardware`，参数 `cpus`、`ramMB`、`useDefault`）。已停机的设备立即通过 `jidr device edit` 写入；运行中的设备标记为待生效，下次启动前写入，并提供「重启设备以应用」。
    - **记录**：设备保存目标值和已写入的值（`appliedHardware`）；`GET /v1/instances` 中的 `hardware` 给出当前值、是否单独设置、是否待生效，以及本机上限（全部核心；内存为本机总量减 4 GB）。
    - **内存下限**：低于镜像最低要求的内存会被模拟器自动提高；API 34 镜像实测为 2.5 GB。
  - 编码使用 baseline profile、无 B 帧、实时优先级；设备视图上限 60 fps。
  - Mac 端强制使用 VideoToolbox 硬件解码（失败时才回退软件），输出原生 4:2:0 YUV，经 `AVSampleBufferDisplayLayer` 显示，不做逐帧颜色转换，窗口显示「硬件解码」状态。
  - 设备视图的输入改走仅含控制通道的 scrcpy 会话（WebSocket `/v1/instances/{id}/control-session`），替代 `adb shell input`：点击按住 40 ms 并依次串行，拖动连续发送，滚轮、按键和文本都走这条通道。
- **Apple D3DMetal**：可选组件 `windows-d3dmetal` 下载 Gcenx 发行的 Game Porting Toolkit 3.0-3（由 Apple 开源的 GPTK 源码构建的 Wine，加 Apple 的 D3DMetal，SHA-256 固定）。D3DMetal 受 Apple 许可约束：后端下载 Apple 的 `License.pdf`（SHA-256 固定），用 PDFKit 读出原文，在组件页完整显示，用户勾选同意并提交原文指纹后才下载。TwinSim 仓库和应用包中不含任何 Apple 文件。「Windows 游戏（D3DMetal）」设备记录自己使用 GPTK 运行时（`wine64`，32/64 位），Direct3D 11/12 由 D3DMetal 转为 Metal，并开启 `WINEMSYNC`；DXVK 不适用于这类设备。
- **删除应用**：应用卡片的「…」菜单和右键菜单中有「删除…」，调用后端 `POST /v1/artifacts/{id}/delete`。可以选择同时从安装过它的设备卸载：Android 和 iOS 设备需在运行；Windows 设备会删除 `C:\TwinSim\Apps\<id>`，`.msi` 先运行 `msiexec /x`。然后删除存储的副本和应用库条目。
- **删除设备**：设备列表右键菜单、设备详情「…」菜单或 Delete 键，确认后调用后端 `delete` 操作。设备会先停机，再删除 AVD 或 Simulator 设备及其数据。vphone 虚拟机只取消登记，不删除其文件。
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

- 本机长期使用：运行一次 `bash scripts/create-local-signing-identity.sh`，在登录钥匙串中创建自签名代码签名证书 “TwinSim Local Signing”（不修改信任设置）。之后 `package-app.sh` 会自动用它签名。签名要求固定为“bundle ID + 证书”，macOS 的隐私授权（如访问可移除宗卷上的文件）在重新构建后仍然有效。ad hoc 签名每次构建身份都会变化，因此会反复弹出授权请求。
- 未设置 `TWINSIM_SIGN_IDENTITY` 且没有本地证书时，helper 和应用使用 ad hoc 签名并启用 hardened runtime，适合本机使用。其他 Mac 上 Gatekeeper 会拒绝，需要右键打开或移除隔离属性。
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
