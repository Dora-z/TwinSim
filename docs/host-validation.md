# TwinSim 本机验证

验证日期 2026-11-08。宿主为 Apple M6、16 GB 内存、macOS 27.2 (26B123)。测试使用现有工具链和临时实例。

## 后端实现阶段

- release arm64 `twinsimd` 和固定源码版本的 Jidr helper 已生成，两个可执行文件通过本地签名验证。应用打包入口及 API 见 [后端对接文档](backend.md)。
- 空数据目录中验证了 Jidr 0.3.1 和 scrcpy 4.0 的下载、校验和安装。Android SDK 包缺少许可确认时返回 `LICENSE_CONSENT_REQUIRED`。Android 应用端到端测试复用了现有 API 34 Google APIs SDK 镜像。
- Android 样本通过真实 HTTP 接口完成导入、启动、截图、H.264 流、日志、再次打开、卸载和停机。使用 adb-root 配置验证 UID 0。快照保存和恢复通过。固定源码构建的 Jidr 验证了可写模式启用、在 `/system` 创建及删除文件、关闭可写模式、再打开原 APK。
- Android 通过客体上传、下载和回环端口转发接入 Frida 17.26.2，成功附加测试 APK 进程并执行脚本，返回 `arm64`。普通和研究实例继续使用独立 ADB 端口。
- 已安装 iOS 27.2 Simulator runtime。ARM64 Simulator 样本通过 HTTP 接口完成导入、启动、主屏 PNG 截图、日志、再次打开、卸载和停机。另构建了一份 device IPA，确认正确识别为 IPA 并返回 `RESEARCH_GUESTS_DISABLED`。
- 后续实测项目包括 AOSP 镜像首次下载与 Magisk 配置、iOS Simulator 实时触控和视频、vphone 真机固件虚拟机及其高权限调试。宿主原生应用运行属于独立实验范围。

以下为实现前的宿主探测记录。

## Android

- Android SDK 在 `/Volumes/External/Android`。使用 Emulator 37.2.13.0 (16740729)、ADB 37.0.1 (15733141)、Build Tools 35.0.0 和 JDK 21。镜像是 `system-images;android-34;google_apis;arm64-v8a`，修订 14，构建类型 `userdebug`。
- `emulator -accel-check` 返回 0 并报告 Hypervisor.Framework。Pixel 6 配置、2048 MB、`-accel on -gpu host`、无窗口和无快照的单次完整探测，约 20 秒到 `sys.boot_completed=1`。图形日志报告 OpenGL ES 3.0，经 Metal 渲染。这个时间是本机样本。
- ADB shell 初始 UID 为 2000。运行 `adb root` 后确认 UID 变为 0。APK 安装和启动成功，日志出现 `ACTIVITY_READY`，截图为 1080 × 2400 PNG，之后成功卸载样本。
- 在临时 `-writable-system` 实例执行 `disable-verity`、重启、重新获取 root、`remount`。OverlayFS 的 scratch 分配从 `/data` 回退到 super 的可用空间。最终 remount 成功，并在 `/system` 创建及删除临时文件。SELinux 报告 `Enforcing`。
- ADB 初次探测遇到服务端崩溃，崩溃线程为 `libadbmdns_zero_config_driver`，栈包含 `_Unwind_Backtrace`。专用服务进程使用 `ADB_MDNS=0` 后完成全流程。Google 将该 M6 问题的修复列在 ADB 37.0.2 Canary。现有 5037 ADB 服务在探测后仍为原进程。 [Platform Tools 发行说明](https://developer.android.com/tools/releases/platform-tools) · [Android OverlayFS 说明](https://android.googlesource.com/platform/system/core/+/refs/heads/main/fs_mgr/README.overlayfs.md)

待测项目包括 AOSP `default` 镜像、原生 ARM64 APK、分包、Frida、双实例、快照恢复和持续视频。探测脚本支持指定已安装的 AOSP 镜像。现有命令行工具 12.0 读取 SDK XML 时发出版本警告，但成功创建了测试 AVD。

## iOS Simulator

- 完整 Xcode 27.2 (27B52) 位于 `/Volumes/External/Applications/Xcode.app`。全局 `xcode-select` 指向 Command Line Tools，项目命令用 `DEVELOPER_DIR` 选择完整 Xcode。
- 两个 SDK 都能编译 arm64 Mach-O，`vtool -show-build` 分别显示 `IOSSIMULATOR` 和 `IOS`。`simctl list -j runtimes` 返回空列表。安装匹配的 iOS runtime 后，才能验证 boot、安装、运行和截图。 [Xcode runtime 安装说明](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)

## iOS 研究 VM

- 本机报告 SIP 已启用、Research Guests 已禁用。已核对上游宿主机要求、M6 签名工具架构说明、固件兼容性和 IPA API。本轮未安装 vphone 或引导客体，iOS device IPA、客体 root 和 Frida 均待本机验证。 [vphone 宿主机要求](https://lakr233.github.io/vphone-cli/get-started/host-setup.html) · [M6 兼容记录](https://lakr233.github.io/vphone-cli/research/Host/macos27_m6_amfi.html) · [vphone API 参考](https://lakr233.github.io/vphone-cli/research/vphoned_http_api.html)
