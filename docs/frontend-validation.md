# TwinSim 前端联调记录

验证日期 2026-11-08。宿主为 Apple M6、macOS 27.2，Xcode 27.2，Android SDK 位于 `/Volumes/External/Android`。被测对象是打包后的 `dist/TwinSim.app`（内置 `twinsimd` 与 `jidr`），通过 LaunchServices（`open -W -n --env …`）启动，与 Finder 双击时处于同一用户 GUI 会话。每轮使用全新的独立 `TWINSIM_HOME`（`.build/e2e/home`）。`ANDROID_HOME` 和 `DEVELOPER_DIR` 只写入应用设置（`com.twinsim.app` 偏好），由前端传给 helper，启动 shell 不导出这两个变量。

自测（`scripts/frontend-e2e.sh`）在应用内运行，使用界面所用的 `AppStore`、真实画面窗口、VideoToolbox 解码器和触控换算代码，结果写入 `.build/e2e/report/report.md`。最终一轮 **44/44 通过**，总耗时 313 秒。样本由 `scripts/make-test-samples.sh` 生成。

## 通用

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| 启动 helper、读取握手、Bearer 令牌 | 通过 | stdout 单行 JSON。令牌只在内存中 |
| SSE 订阅与 `reset` | 通过 | 首个事件为 `reset`，前端重读全部列表。后端每 60 秒关流，前端按 `Last-Event-ID` 续订 |
| 组件列表与安装进度 | 通过 | 新数据目录中 `android-display` 为 `downloadable`。前端发起安装，显示阶段和字节进度（如 20 KB / 732 KB），完成后刷新为 `ready` |
| 许可确认界面 | 已显示，未提交 | `android-runtime` 为 `needsConsent`，界面显示后端返回的许可原文和指纹，勾选后才能安装。未提交，避免下载约 10 GB 的 AOSP 镜像 |
| `externalSetup` | 通过 | `ios-vphone` 显示 `RESEARCH_GUESTS_DISABLED` 原因、上游配置链接和「配置完成，重新检查」 |
| helper 意外退出 | 通过 | 对 helper 发 SIGKILL，前端 1 秒后重启（新 PID），重新握手和订阅，实例状态从 `unknown` 核对回 `ready`，画面窗口自动重连 |
| 正常退出 | 通过 | 通过 Apple Event 退出应用后 helper 随之退出，无残留进程 |

## Android（`android-google-apis`，API 34，客体 720×1280）

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| 导入 APK | 通过 | `org.twinsim.touchprobe`，重复导入返回同一 ID |
| 单应用模式打开 | 通过 | `/v1/artifacts/{id}/launch`，新建应用工作区、启动、安装并启动应用，约 28 秒。AOSP 运行环境未安装，前端自动选择已就绪的 Google APIs 配置 |
| 实时画面 | 通过 | `/video` Annex B 流经 VideoToolbox 解码。解码错误 0，空闲刷出尾部 NAL 6 次 |
| 触控 | 通过 | 点击画面中 (0.5,0.5)、(0.2,0.8)、(0.85,0.3)，客体记录的坐标分别为 (360,640)、(144,1024)、(612,384)，与换算结果一致，画面随后更新 |
| 再次打开 | 通过 | 复用同一实例和已有安装，约 1.4 秒 |
| 断线重连 | 通过 | 模拟视频连接中断后自动重连。旧订阅未释放时收到 `RESOURCE_BUSY`，等待后恢复 |
| 截图回退 | 通过 | 切换到截图模式显示 720×1280 PNG，再切回实时画面 |
| 停机 | 通过 | 约 4 秒，窗口显示「设备已停机」和「启动」按钮 |
| 「设备」页创建、启动、画面 | 通过 | 创建约 1 秒，启动约 34 秒，打开设备窗口 |
| 研究工具 | 通过 | root 返回 UID 0。shell `id -u; getprop ro.product.cpu.abi` 返回 `0 arm64-v8a`。端口转发分配 127.0.0.1 端口后取消 |
| 日志 | 通过 | logcat |

截图：[应用窗口](images/frontend/04-android-window.png)、[触控后解码帧](images/frontend/05-android-after-taps.png)、[设备窗口](images/frontend/10-device-android.png)

## iOS Simulator（iOS 27.2 runtime，客体 1206×2622）

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| 导入 Simulator `.app` | 通过 | ARM64 `IOSSIMULATOR` 样本 |
| 单应用模式打开 | 通过 | 约 47 秒（含创建并启动 Simulator） |
| 截图 | 通过 | 窗口为截图模式，1206×2622 |
| 触控 | 不提供 | 后端报告 `input` 为 `unsupported`，界面不显示触控和按键入口 |
| 日志 | 通过（需重试） | 刚启动后首次请求返回 `OUTPUT_LIMIT`：后端 `log show --last 30s` 的输出超过 32 MB 上限，可能需要 20–55 秒。界面显示原因，重试后成功 |
| 再次打开 | 通过 | 复用同一实例 |
| 停机 | 通过 | 约 4 秒 |
| 「设备」页创建、启动、画面、停机 | 通过 | |

截图：[应用窗口](images/frontend/07-ios-window.png)

## iOS 真机 IPA

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| 导入 | 通过 | 识别为 device IPA |
| 宿主机阻塞提示 | 通过 | 本机 Research Guests 已禁用。点「打开」时前端不提交启动，直接显示原因、处理步骤和 vphone 上游配置链接（[截图](images/frontend/08-ipa-blocked.png)） |
| 后端路径 | 通过 | 强制提交启动后，操作以 `RESEARCH_GUESTS_DISABLED` 失败。测试数据目录会留下一条失败的 vphone 应用工作区 |

## 未覆盖或受限的项目

- vphone 研究虚拟机未运行：本机未启用 Research Guests。
- 以下界面已实现，但本轮未自动化：拖拽和文件选择导入（与自测使用同一 `importFiles` 路径）、Finder「打开方式」打开 `.apk`/`.ipa`、拖动映射的 `input swipe`、文本输入、系统分区可写、快照、客体文件传入和导出、有运行中设备时的退出确认。系统分区可写、快照和文件传输的后端实测见 [host-validation.md](host-validation.md)。
- 未下载 AOSP 运行环境，`android-aosp`、`android-research` 和 `android-magisk` 配置未在前端实测。
- 前端必须在用户 GUI 会话中运行，iOS Simulator 才能启动。从无 GUI 会话的 shell 直接执行应用二进制时，`simctl boot` 报 `launchd_sim: could not bind to session`。

## 签名状态

本机没有 Developer ID 证书（`security find-identity -p codesigning` 返回 0 个），所以交付本地签名包：`TwinSim.app`、`twinsimd` 和 `jidr` 都使用 ad hoc 签名并启用 hardened runtime，`codesign --verify --deep --strict` 通过。`spctl --assess` 结果为 rejected，属 ad hoc 签名的预期结果。未公证。提供 `TWINSIM_SIGN_IDENTITY` 和 `TWINSIM_NOTARY_PROFILE` 后，`scripts/package-app.sh` 会完成 Developer ID 签名、公证和 staple，见 [前端文档](frontend.md#签名与公证)。

## AI 集成

`python3 scripts/agent-e2e.py` 以 MCP 客户端身份（stdio JSON-RPC）驱动打包后的 `Contents/Helpers/twinsim mcp`，再测试命令行。测试使用独立的 `TWINSIM_HOME`，开始时 TwinSim 未运行，`TWINSIM_MAX_EDGE=640`。最终一轮 **36/36 通过**，耗时 266 秒。

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| MCP `initialize`、`tools/list` | 通过 | 31 个工具，返回使用说明 |
| 自动启动应用 | 通过 | 首次调用通过 `open -g -j` 在后台启动 TwinSim，约 5 秒连上后端 |
| 安装组件 | 通过 | `android-display` |
| `open_app` APK | 通过 | 自动选择已就绪的 Google APIs 配置，约 28 秒。再次打开复用同一设备 |
| 截图缩放与坐标换算 | 通过 | 客体 720×1280，返回 360×640 图片。点击图片坐标 (180,320)，客体记录 (360,640) |
| `ui_tree`、`tap_element`、`wait_for_text` | 通过 | 在系统设置中，`tap_element "Display"` 自动滚动一次后找到并进入，出现 “Dark theme” |
| `type_text`、`press_key`、`swipe` | 通过 | 点开设置搜索框，输入 “dark theme” 并显示在输入框中 |
| `logs` 过滤 | 通过 | Android 上在客体中对整个 logcat 缓冲区执行 grep |
| `verify_root`、`shell`、端口转发 | 通过 | UID 0 |
| 命令行 | 通过 | 可用设备 ID 前缀。截图为原始分辨率。`call` 返回 JSON。`tools --format openai/anthropic/gemini/mcp` 均输出 31 个定义。错误时退出码为 1 并附提示 |
| iOS Simulator | 通过 | 打开约 84 秒（首次创建设备），截图正常。`tap` 返回 `CAPABILITY_UNSUPPORTED` |
| 真机 IPA | 通过 | `open_app` 返回 `RESEARCH_GUESTS_DISABLED`，并附宿主机配置链接 |
| 许可确认 | 通过 | `install_component android-runtime` 只返回许可原文，未传 `acceptLicenses=true` 时不会安装 |
| `show_device`、`stop_device` | 通过 | |

另一轮紧接重新打包之后运行时，后台启动失败：`open` 没有启动应用，套接字也没有出现，原因未确认。之后命令行改为检查 `open` 的退出状态并重试启动，再次紧接打包运行时通过。改动后用 `TWINSIM_SELF_TEST_PLATFORMS=android,ipa` 回归 GUI 自测，25/25 通过，并确认应用内的 AI 连接正在监听（[设置页截图](images/frontend/12-ai-settings.png)）。

未在真实客户端中验证：未在 Claude Code、Claude Desktop、Cursor、VS Code、Codex、Gemini CLI 中实际加载配置，本机未安装这些 CLI。协议层面已由上面的 MCP 客户端测试覆盖。

## 内置 frida-server（0.4.3）

`TWINSIM_SELF_TEST_PLATFORMS=frida`，在打包后的应用中新建 `android-google-apis` 设备：**11/11 通过**。`TWINSIM_SELFTEST_FRIDA_PYTHON` 指向装有 Frida 17.26.2 客户端的 Python 时，还会做一次真实附加。

| 检查 | 结果 |
| --- | --- |
| 能力 `frida` | `available` |
| `frida-start`（含推送 85 MB frida-server） | 约 2 秒，返回 `127.0.0.1:<端口>`、客体 pid、版本 17.26.2 |
| 客体进程 | `pidof twinsim-frida-server` 有结果，root shell |
| 本机端口 | frida-server 以 HTTP 404 应答（说明转发后有服务在监听，不只是 ADB 接受连接） |
| 实例 `frida` 字段 | `running`，端口与返回值一致 |
| 再次 `frida-start` | 返回同一端口 |
| Frida 17.26.2 Python 客户端附加 SystemUI | `arm64`，pid 一致，读到 326 个模块 |
| `twinsim frida_server --action stop`（与 MCP 同一路径） | 进程结束，转发移除，实例显示未运行 |

[工具面板截图](images/frontend/14-frida-tools.png)。附加脚本最初引用了 `Java.available`，在 Frida 17 中报错：Frida 17 的脚本运行时不再内置 Java 桥。

## Android 模拟器资源自定义（0.4.1）

`TWINSIM_SELF_TEST_PLATFORMS=hardware`：**11/11 通过**，在客体内读取 `/proc/cpuinfo` 和 `MemTotal` 核对。

| 操作 | 客体实际 |
| --- | --- |
| 创建时设 3 核、2 GB | 3 核，MemTotal 2478 MB（模拟器把 2 GB 提高到最低 2.5 GB） |
| 运行中改为 4 核、3 GB | 标记为待生效；重启后为 4 核，2981 MB |
| 已停机时用 `twinsim set_device_hardware` 改为 2 核、2 GB | 立即写入；启动后为 2 核，2478 MB |
| 恢复默认（自动） | 6 核，2981 MB |
| 设为 999 核 | 拒绝，`INVALID_HARDWARE` |

## Android 应用窗口与性能（0.4.0）

本节两次运行均使用独立的 `TWINSIM_HOME`：

- `TWINSIM_SELF_TEST_PLATFORMS=appwindow,perf`：**30/30 通过**。
- 加上 android、ios 和 library 的回归：**42/43 通过**。唯一失败是连续三次无间隔点击被合并，已改为串行点击，复测 android 和 perf 共 30/30。

| 项目 | 结果 |
| --- | --- |
| 应用独立窗口（虚拟显示器，无系统栏） | 首帧 3–5 秒（设备已启动时），画面尺寸等于窗口像素 |
| 应用窗口触控坐标 | 发送 (309,660)，应用收到 (309,660) |
| 应用窗口拖动帧率（均衡 1.5×） | 优化前 38 fps，优化后 **53 fps**。清晰 2× 优化前 24 fps，流畅 1× 优化前 41 fps |
| 调整窗口大小 | 700×1000 精确生效；宽度超过 1024 时被编码器限制为 1024 |
| 模拟器资源 | 6 核、3 GB（原为 2 核、2 GB） |
| 硬件解码 | 设备视图和应用窗口均确认使用硬件解码器 |
| 设备视图点击 | adb 每次约 **365 ms**；控制通道约 40 ms（手指按住时长），10 次快速点击坐标全部准确 |
| 设备视图拖动帧率（720×1280） | 优化前 ≤30 fps，优化后 **44 fps** |

## 删除应用与 D3DMetal 许可确认

`TWINSIM_SELF_TEST_PLATFORMS=library bash scripts/frontend-e2e.sh`：**12/12 通过**（独立 `TWINSIM_HOME`，不运行 Wine）。

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| D3DMetal 许可确认 | 通过 | 组件状态为 `needsConsent`，显示 Apple `License.pdf` 原文（约 16,400 字符，运行时从 PDF 读取） |
| 导入 apk、Simulator .app、Windows .exe | 通过 | .exe 为仅含文件头的样本，不会运行 |
| 删除 APK 并从运行中的设备卸载 | 通过 | 1.3 秒。删除后客体中查不到该包 |
| 删除 .app 和 .exe | 通过 | 存储的副本被删除，服务端应用库为空 |
| 删除后重新导入 | 通过 | |

## Windows（Wine）

0.3.0 已加入 Windows 程序支持，通过编译、后端单元测试（PE 识别、进程环境读取、`C:\` 路径映射）和不运行 Wine 的回归测试，组件页正确显示 `windows-wine` 与 `windows-dxvk`。**尚未实际运行 Wine**：下载的 Wine 二进制需要用户自行执行实测。实测命令：

```bash
TWINSIM_APP=/Applications/TwinSim.app TWINSIM_SELF_TEST_PLATFORMS=windows bash scripts/frontend-e2e.sh
```

测试使用 Wine 自带的 32 位扫雷和 64 位记事本，覆盖打开程序、窗口截图、`cmd`、文件传输、在记事本中输入、DXVK、显示模式、停机和删除。

## 数据位置与删除设备

`bash scripts/data-e2e.sh`：从内置磁盘的数据目录（`~/TwinSimMoveTest/TwinSim`）开始，其中有一台 Android AVD（含快速启动状态）和一台 iOS Simulator 设备，共 6.62 GB。该位置通过应用设置指定，不使用 `TWINSIM_HOME`。测试由应用内自测执行，结果 **22/22 通过**。

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| 移动到外置 APFS 硬盘 | 通过 | 86 秒。Android 设备运行中，先停机。进度到 100%，后端从新位置启动 |
| 原位置删除、设备保留 | 通过 | 两台设备 ID 不变 |
| AVD 路径改写 | 通过 | `.ini` 中的 `path=` 指向新位置 |
| 从新位置启动 | 通过 | Android 7 秒（快速启动），iOS 20 秒，截图正常 |
| `twinsim` 找到新位置 | 通过 | 未设置 `TWINSIM_HOME`，按应用设置连接 |
| 外置硬盘未连接 | 通过 | 不启动后端，也不在 `/Volumes` 下创建目录。恢复后重新连接 |
| 删除运行中的 Android 设备 | 通过 | 25 秒。先停机，AVD 目录和 `.ini` 被删除 |
| 删除运行中的 iOS Simulator 设备 | 通过 | 4 秒。设备集中的目录被删除，重新同步后不再出现 |
