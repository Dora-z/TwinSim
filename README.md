# TwinSim

在 Apple Silicon Mac 上运行 Android 模拟器、iOS Simulator 和 Windows 程序：导入 APK、Simulator `.app`、IPA 或 Windows `.exe`/`.msi` 一键打开，查看画面并操作，配合日志、客体 shell、root 等研究工具，并可通过 MCP 或命令行交给 AI 操作。设备、运行环境和应用数据可以放在外置硬盘上。Windows 程序通过 WineHQ 上游 Wine 运行，不依赖 CrossOver。

## 安装

1. 从 [Releases](https://github.com/Dora-z/TwinSim/releases) 下载 `TwinSim.dmg`，把 `TwinSim.app` 拖入「应用程序」。需要 Apple Silicon 和 macOS 15 或更高版本。
2. 当前发行包为本地签名（ad hoc），未经 Apple 公证。首次打开时在 Finder 中右键点 TwinSim →「打开」，或执行 `xattr -dr com.apple.quarantine /Applications/TwinSim.app`。
3. 首次启动后按「组件」页提示安装所需引擎。iOS Simulator 需要完整 Xcode 和 iOS runtime。

AI 接入（MCP、`twinsim` 命令、函数调用）见 [docs/ai.md](docs/ai.md)。从源码构建见 [docs/frontend.md](docs/frontend.md)。本项目以 [MIT 许可](LICENSE) 开源。应用内置的第三方组件（Vapor、Jidr 等）保留各自许可，声明位于 `TwinSim.app/Contents/Resources/BackendNotices`。

TwinSim 是独立安装的 Apple Silicon macOS 应用。用户安装 `TwinSim.app` 后，可以创建完整的虚拟设备，也可以导入应用并从应用库打开。运行所需的镜像和大型组件在首次用到时准备。本文覆盖后端、安装交付和前端对接，界面由独立开发者实现。

当前实现的启动方式、组件和 HTTP 接口见 [后端对接文档](docs/backend.md)。macOS 前端的源码结构、构建、打包、签名和联调方法见 [前端文档](docs/frontend.md)，实测结果见 [前端联调记录](docs/frontend-validation.md)。AI 可通过 MCP、`twinsim` 命令行或函数调用定义控制 TwinSim，见 [AI 接入](docs/ai.md)。下文保留产品方案与开发范围。

## 独立安装与按需下载

- **安装包。** 通过经 Developer ID 签名和 Apple 公证的 DMG 发行 `TwinSim.app`。应用内置 `twinsimd` 和运行它所需的组件，启动应用即可启动后端。后端按当前用户运行，前端通过启动握手获得回环地址和会话令牌。 [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- **Android 运行包。** 首次创建 Android 设备或打开 APK 时，后端准备固定版本的 ARM64 引擎、ADB 和一份 AOSP 镜像。普通使用流程以无需 Android Studio、JDK、Homebrew 或终端为验收条件。开发用探测脚本的 JDK 和 SDK 编译依赖与发行版分开。
- **iOS 开发包。** 检测用户安装的完整 Xcode 和对应 Simulator runtime。缺失时引导通过 Apple 安装，安装后重检。用单进程的 `DEVELOPER_DIR` 选择工具链。 [Apple runtime 安装说明](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- **iOS 研究包。** 作为可选组件，固定 vphone 版本及固件配对，由上游工具负责准备。宿主机先通过 Research Guests 和 entitlement 预检。需要进入 macOS 恢复环境、重启或批准上游 helper 时，向前端返回明确的人工步骤，之后可在原任务里复检。 [vphone 安装流程](https://lakr233.github.io/vphone-cli/get-started/quick-start.html) · [宿主机设置](https://lakr233.github.io/vphone-cli/get-started/host-setup.html)

运行包按版本安装在用户目录，实例数据单独存放。下载前显示来源、下载体积、解包后的空间需求和适用条款。下载中支持进度、取消和断点续传，校验后原子启用。旧实例继续引用创建时验证过的引擎和镜像。更新失败时可继续用原版本，清理组件前检查是否仍被实例引用。Google SDK 下载和再分发条件按用途及组件逐项核对。Google Play 服务、Apple 固件及 Xcode runtime 由相应上游渠道提供。 [Google SDK 条款](https://developer.android.com/studio#terms)

## 用户如何运行应用

| 模式 | 用户操作 | 后端行为 |
| --- | --- | --- |
| 完整设备 | 创建设备并打开设备窗口 | 启动选定的 Android AVD 或 iOS 研究 VM，提供整个设备的桌面、输入和调试能力。iOS Simulator 作为独立开发配置 |
| 单应用 | 在应用库点开已导入的 APK 或兼容 IPA | 选择相应引擎，复用指定实例或创建并启动实例，安装后直接启动目标应用。Android 逐步接入独立应用画面，遇到应用不支持虚拟显示时提供设备视图。兼容 IPA 在 iOS 研究 VM 就绪后可走同样的导入流程，独立画面待验证 |
| 宿主直接运行 | 打开可在 macOS 上运行的 iPhone 或 iPad 应用 | 使用 macOS 的系统能力启动经 Mac App Store 安装的兼容应用。自有 IPA 的 PlayCover 路线和 Android 的 Mac.apk 路线分别作为实验项。此模式只有宿主应用权限 |

单应用模式的 APK 和 IPA 仍在各自引擎中运行，所以可以保留原引擎的调试能力。对用户提供导入和文件打开入口，文件关联由前端应用注册。每条路径按包类型、平台、架构和当前能力选择。 [Apple Silicon 上的 iPhone 和 iPad 应用](https://support.apple.com/en-gb/guide/app-store/fird2c7092da/mac) · [PlayCover 的 IPA 导入说明](https://docs.playcover.io/getting_started/download_ipa)

## 引擎选择

| 引擎 | 复用方案 | 应用与权限 | 当前状态 |
| --- | --- | --- | --- |
| `android-emulator` | Jidr + Google Android Emulator、AVD、ADB。ARM64 客体通过 Hypervisor.framework 加速 | ARM64 或纯 Java/Kotlin APK。研究配置按镜像验证 `adb root` 和系统分区写权限。Google Play 镜像用于服务兼容性测试 | 本机 API 34 Google APIs 镜像已通过后端 API 验证 APK、客体 root、截图、日志、H.264 和快照恢复 |
| `ios-simulator` | Xcode Simulator + `simctl`。交互画面和触控评估 Meta idb | iOS Simulator 目标构建的 `.app`。可检查应用容器并用 LLDB 调试开发构建 | iOS 27.2 runtime 已安装，后端 API 已通过样本安装、启动、截图、日志和停机 |
| `ios-vphone` | vphone-cli + PCC research VM。用上游 Launchpad CLI 管生命周期与客体操作 | 目标是运行兼容的 iOS device IPA，提供越狱客体 shell、文件和 Frida。由固件、签名、客体状态和实测结果决定可用能力 | 已接入 adapter。本机 Research Guests 关闭，已验证 IPA 分类与宿主机阻塞原因 |

Android 研究配置以 AOSP ARM64 为默认目标，并保留 Google APIs 作为独立的兼容性配置。Google Play 镜像、Android root、系统分区可写和 Frida attach 各自独立标记。现有镜像在拿到 `uid=0` 后仍可保持 SELinux enforcing，启动成功也不代表支持 ARM32、x86 专用 APK 或依赖硬件证明的应用。 [Android 虚拟设备与镜像](https://developer.android.com/studio/run/managing-avds) · [VM 与图形加速](https://developer.android.com/studio/run/emulator-acceleration)

iOS 分开提供两个引擎。两种 arm64 Mach-O 可分别标记为 `IOS` 和 `IOSSIMULATOR`，上传时检查主程序及内嵌二进制的平台和架构。device IPA 进研究引擎的兼容性检查，Simulator `.app` 进开发引擎。研究引擎的安装、启动和注入分别验收，IPA 加密状态、签名或 entitlement、硬件依赖和特定应用兼容性分别报告。 [Apple 的设备和模拟器运行说明](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [vphone 固件兼容性](https://lakr233.github.io/vphone-cli/firmware/compatibility.html) · [vphone 自动化 API](https://lakr233.github.io/vphone-cli/machines/automation-api.html)

vphone 通过外部组件接入。上游要求在宿主机启用 Research Guests，并让 macOS 接受带 Apple 私有 entitlement 的 VM 进程。M6 还需要核对上游构建中的 `arm64e.x1` 支持。研究引擎上线前，以固定的 vphone 版本、macOS 版本、机型、iOS IPSW 和 cloudOS IPSW 组合做验证。当前建议先复现上游报告的 `iPhone17,3 / iOS 26.6.2 (23G90) / cloudOS 26.4 (23E5207q)`。 [宿主机要求](https://lakr233.github.io/vphone-cli/get-started/host-setup.html) · [M6 兼容记录](https://lakr233.github.io/vphone-cli/research/Host/macos27_m6_amfi.html) · [固件配对](https://lakr233.github.io/vphone-cli/firmware/compatibility.html)

### 优先复用的实现

| 项目 | 用途 | 验证门槛 |
| --- | --- | --- |
| [Jidr](https://github.com/AbdurahmanAlmehdi/jidr/tree/728475ece48a40e120806ca03546e4fa3a8f2876) | 优先验证直接使用 Apache-2.0 的无界面 CLI 和 daemon 管理 Android SDK、镜像、AVD、`adb root` 和 Magisk。上游提供 JSON 输出和 JSON-RPC，GUI 单独采用 GPL-3.0-only | 在干净 Mac 验证独立数据目录、许可确认、下载恢复、进程重启、设备归属和卸载。适配层继续保留已跑通的 Emulator 与 ADB 调用路径 |
| [Avo](https://github.com/nizwar/avo/tree/08096b2a3cfa93f1ba924870e2ed18ac0b309f7a) | 参考单应用虚拟显示、安装即用流程和帧传输。它另有基于 Hypervisor.framework、AOSP Cuttlefish 和 gfxstream 的引擎，主体 Apache-2.0，HVF crates 为 BSD-3-Clause | 先验证现有 Emulator 配合 scrcpy 的虚拟显示能否覆盖单应用需求。若要采用 Avo 引擎，另测客体权限、调试、设备视图、恢复能力和图形性能 |
| [Mac.apk](https://github.com/kksimp/Mac.apk/tree/57c99122f9a164c9ddcc97cfaf5d14dde89d7152) | 单独评估真正无 VM 的 Android 兼容层。上游提供 AGPL-3.0 和商业授权路径 | 按应用测试兼容性、宿主权限边界和分发条件后再决定是否接入 |

## 后端边界

- 首版采用 Swift Package Manager 构建本地 arm64 服务 `twinsimd`。Swift 负责实例管理、能力探测和工具适配，虚拟化、图形、应用调试由上游引擎执行。先用 CLI 管低频操作，持续日志、视频和触控走长期连接。
- 每个实例有独立数据目录、端口和引擎标识。默认只管理 TwinSim 创建的实例。Android 明确指定 ADB server 和 serial，iOS Simulator 使用专用 device set 和设备 UDID，vphone 使用自己的 VM 目录和控制通道。
- 持久化实例配置和操作记录，实际状态以引擎为准。启动成功要求引擎进程存活、客体完成启动、控制通道可用。重启服务时重新确认实例归属和状态。每个实例串行执行启动、关机、恢复和安装等变更操作。
- 控制服务仅监听回环地址，校验会话令牌、Host 与允许的 Origin。客体 shell、文件导出和 instrumentation 限定到实例。签名应用包、外部运行包和实例数据分别管理。
- Android 首版截图用 ADB，实时画面优先验证 scrcpy，Emulator gRPC 作为备选。直接接 scrcpy 的协议时固定配对版本。iOS Simulator 首版用 `simctl io` 截图，实时视频和输入通过 idb 单独验证 Xcode 兼容性。vphone 复用 `apps.install`、`apps.launch`、`screen.screenshot` 和上游输入能力，实时视频另行验证。 [scrcpy 开发文档](https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md) · [idb 的画面和输入接口](https://github.com/meta/idb/tree/main/FBSimulatorControl) · [vphone API 参考](https://lakr233.github.io/vphone-cli/research/vphoned_http_api.html)
- 首轮调试工具复用 ADB/logcat、LLDB 和 Frida。后续增加端口转发、文件传输和按实例保存的 PCAP。APK 静态分析可通过独立 JADX、apktool 工具接入。 [Frida Android](https://frida.re/docs/android/) · [Frida iOS](https://frida.re/docs/ios/)

可复用组件的许可分别核对。Android Emulator 的发行二进制声明为 GPLv2，scrcpy 为 Apache-2.0，idb 和 vphone-cli 为 MIT。PlayCover 和 Inferno 分别作为宿主 IPA 兼容与特定旧版固件研究的候选。 [Android Emulator 源码](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-master-dev) · [PlayCover](https://github.com/PlayCover/PlayCover) · [Inferno](https://github.com/ChefKissInc/Inferno)

## 给前端的接口草案

第一阶段提供本地 HTTP JSON 控制面和 SSE 状态事件。以下是设计约定，供前端做 mock。

| 请求 | 返回或行为 |
| --- | --- |
| `GET /v1/engines` | 引擎、可创建的配置、依赖检查、能力与阻塞原因 |
| `GET /v1/components` | 获取运行包版本、体积、安装状态和下一步操作。可安装项附许可文本及版本指纹，需人工安装的项附上游入口 |
| `POST /v1/components/{id}/install` | 安装选定版本。需要许可时提交用户确认过的指纹，返回操作 ID，通过 SSE 报告阶段和字节进度 |
| `GET /v1/instances` / `GET /v1/instances/{id}` | 实例、实时状态和按实例探测的能力 |
| `POST /v1/instances` | 按 `engineId`、`profileId` 创建实例，返回操作 ID |
| `POST /v1/artifacts` | 上传本地样本，返回 `artifactId`、SHA-256 和检测到的格式。后端在托管目录内检查包结构、解包限额及路径 |
| `POST /v1/artifacts/{id}/launch` | 打开应用模式，可指定目标实例。缺少依赖时返回所需的组件 ID 和下一步操作，准备好后重试 |
| `POST /v1/instances/{id}/actions/{action}` | 发起 `start`、`stop`、`install`、`launch` 等操作。安装参数引用 `artifactId` |
| `GET /v1/operations/{id}` | 查询异步操作进度、结果与错误 |
| `GET /v1/events` | SSE，推送实例和操作变化。浏览器通过带授权头的 `fetch` 读取，按事件 ID 重连，历史失效时重新读取列表 |
| `GET /v1/instances/{id}/screenshot` | 获取截图，按引擎返回 `image/png` 或 `image/jpeg` |

```json
{
  "id": "inst_123",
  "engineId": "ios-vphone",
  "profileId": "ios-research",
  "state": "stopped",
  "capabilities": {
    "installDeviceIpa": {
      "availability": "blocked",
      "reasonCode": "RESEARCH_GUESTS_DISABLED"
    },
    "installSimulatorApp": {
      "availability": "unsupported"
    }
  }
}
```

- 能力状态为 `available`、`blocked`、`unsupported`。客体 root、系统可写、应用调试、Frida、输入、截图、实时视频和快照分别上报。实例另行报告已探测的 UID 和 SELinux 状态。前端根据能力显示入口。
- 实例状态为 `creating`、`stopped`、`starting`、`ready`、`stopping`、`failed`。耗时变更返回 HTTP 202 和 `operationId`。同一请求使用同一 `Idempotency-Key` 重试时返回原操作 ID，复用键提交不同参数时返回 409。错误体含 `code`、`message`、`retryable`。操作超时后先确认引擎状态，再决定是否重试。
- 持续画面和输入走独立会话。第一版先固定截图和离散操作，画面编码、帧元数据、旋转后的坐标映射和触控时延经实测后再定。

## 开发顺序与验收

1. **Android 先做到装完即可使用。** 在没有 Android Studio、JDK 或 Homebrew 的测试环境，从签名安装包启动后端，完成镜像下载和重试、启动完整设备、导入并打开 APK。验证同一应用再次打开时复用原安装及数据。对 AOSP ARM64 单独验收系统写入、分包 APK、Frida、重启恢复和双实例隔离。
2. **接入 iOS Simulator。** 安装匹配的 runtime，用自建 Simulator `.app` 验证独立设备集、启动、安装、容器路径、日志、截图和关机。核对 device 二进制的错误回包，单独验收 idb 的输入与流媒体。
3. **验证 iOS 研究引擎。** 在具备研究配置的 Mac 上，先跑上游预检。固定一组固件，连续两次冷启动后分别验证受控 IPA 安装、启动、客体 UID、文件导出、Frida attach、截图和恢复。逐项记录哪些能力可以向前端开放。
4. **做性能与回归基线。** 同一镜像、分辨率、配置和样本下比较 TwinSim 与直调上游。记录冷启动、快照启动、安装延迟、宿主内存压力、视频帧率、丢帧与输入延迟。普通 AVD 单独验证快照，研究 AVD 单独验证 writable-system 与回滚。不同引擎分别说明恢复的是磁盘状态还是运行状态。

## 在本机复验

Android 探测使用现有 SDK、JDK 17+、Python 3、Build Tools 35.0.0 和 SDK Platform 35。脚本临时生成一个测试 APK，启动独立的 AVD 和 ADB server，验证客体 root、应用启动、日志、截图和系统写入，退出时清理实例。

```bash
ANDROID_HOME=/Volumes/External/Android bash scripts/probe-android.sh

# 安装对应 AOSP 镜像后，复用同一探测流程
TWINSIM_ANDROID_IMAGE='system-images;android-34;default;arm64-v8a' bash scripts/probe-android.sh

DEVELOPER_DIR=/Volumes/External/Applications/Xcode.app/Contents/Developer bash scripts/probe-ios.sh
```

详见 [本机验证记录](docs/host-validation.md)。
