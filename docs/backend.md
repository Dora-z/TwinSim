# TwinSim 后端对接

`twinsimd` 是 Apple Silicon 本地进程。运行 `bash scripts/package-backend.sh` 生成可复制到应用包的 `Contents/Helpers/twinsimd` 和 `Contents/Resources/BackendNotices`。生产打包使用 `TWINSIM_SIGN_IDENTITY` 对 helper 签名，随后由应用打包流程签名及公证整个应用和 DMG。

需要系统分区可写时，可用固定上游源码构建 Jidr 无界面 helper，再随应用打包。已发布的 Jidr 0.3.1 下载包提供 adb-root 和快照，系统写入能力由后端探测并单独上报。以下命令在构建机使用 Rust 和 protoc，运行端使用编译后的 helper。 [Jidr 源码](https://github.com/AbdurahmanAlmehdi/jidr/tree/728475ece48a40e120806ca03546e4fa3a8f2876)

```bash
bash scripts/build-android-helper.sh
TWINSIM_JIDR_PAYLOAD="$PWD/.build/jidr-target/release/jidr" \
TWINSIM_JIDR_NOTICES="$PWD/.build/upstream/jidr" \
bash scripts/package-backend.sh
```

## 启动与认证

前端用当前用户启动 helper，从标准输出读取一行 JSON，字段为 `url` 和 `token`。只把它们保存在前端会话中。HTTP 请求都携带 `Authorization: Bearer <token>`。浏览器或 WebView 前端可在启动时通过 `TWINSIM_ORIGIN` 声明唯一允许的 Origin。默认使用系统分配的回环端口，可通过 `TWINSIM_PORT` 指定。后端接受 SIGTERM 和 SIGINT。

默认数据目录为 `~/Library/Application Support/TwinSim`。设置 `TWINSIM_HOME` 可创建测试环境，同一目录只允许一个后端进程。Jidr 使用私有设备目录和 ADB 服务，可以读取已安装的 Android SDK。已启动的设备由引擎管理，退出前端时可逐台提交 `stop`。已提交但未完成的操作在后端重启后标记为 `BACKEND_RESTARTED`，再次读取实例会与引擎核对状态。

## 首次运行

1. 请求 `GET /v1/components`。安装 `android-engine` 后刷新列表。Jidr 0.3.1 可由后端从固定上游版本下载并校验，也可通过 `TWINSIM_JIDR` 指定测试用 CLI。
2. 安装 `android-runtime` 取得 AOSP ARM64 运行环境，或选择 `android-google-apis`。组件状态为 `needsConsent` 时展示返回的许可原文，用户确认后提交 `{"acceptLicenses":{"<id>":"<sha256>"}}`。Jidr 负责安装 Google SDK 包并处理其下载缓存。
3. 如需 Android 实时画面，安装 `android-display`。该组件是经 SHA-256 校验的 scrcpy 4.0 服务端。
4. iOS 开发使用完整 Xcode 和 iOS Simulator runtime。Xcode 可从默认位置、`xcode-select` 或 `DEVELOPER_DIR` 选择。runtime 缺失时 `POST /v1/components/ios-simulator-runtime/install` 调用 Xcode 的下载工具。
5. iOS 研究实例使用上游 vphone Launchpad。先通过组件预检。在 `POST /v1/instances` 中传 `externalName` 可注册准备好的 VM。也可在启动 helper 时指定 `TWINSIM_VPHONE_BUNDLE`、`TWINSIM_VPHONE_IPSW`、`TWINSIM_VPHONE_CLOUDOS`，通过上游 Launchpad 创建实例。非默认安装位置可用 `TWINSIM_VPHONE_LAUNCHPAD` 和 `TWINSIM_VPHONE_MACHINES` 指定。 [上游宿主机设置](https://lakr233.github.io/vphone-cli/get-started/host-setup.html)

## API

| 路径 | 说明 |
| --- | --- |
| `GET /v1/health`、`GET /v1/engines`、`GET /v1/components` | 服务、引擎、配置和组件状态 |
| `POST /v1/components/{component}/install` | 发起组件安装，返回操作 ID |
| `POST /v1/artifacts/import` | JSON `{"path":"/absolute/path"}` 导入 APK、IPA 或 Simulator `.app` |
| `POST /v1/artifacts` | 发送 APK 或 IPA 二进制及 `X-Filename`。128 MB 以上使用本地路径导入 |
| `GET /v1/artifacts`、`POST /v1/artifacts/{id}/launch` | 列出或打开应用。打开时可传 `profileId` 或 `instanceId`，省略时复用同配置的应用实例 |
| `GET /v1/instances`、`GET /v1/instances/{id}` | 实例状态与能力 |
| `POST /v1/instances` | JSON `engineId`、`profileId`、`name` 创建设备 |
| `POST /v1/instances/{id}/actions/{action}` | `start`、`stop`、`install`、`launch`、`uninstall` 或按能力提供的客体操作 |
| `GET /v1/instances/{id}/screenshot`、`GET /v1/instances/{id}/logs?lines=200` | 画面和近期日志 |
| `GET /v1/instances/{id}/guest-file?path=...` | 下载 Android 或 vphone 客体中的普通文件，单文件上限 128 MB |
| `GET /v1/instances/{id}/video` | Android 实时 Annex B H.264 字节流，单实例单订阅。前端使用流式解码 |
| `GET /v1/operations/{id}`、`GET /v1/events` | 查询操作或订阅 SSE。SSE 使用带授权头的 fetch，按 `Last-Event-ID` 重连，收到 `reset` 后重读列表 |

长操作返回 HTTP 202 和 `operationId`。同一 JSON 请求可以复用 `Idempotency-Key`，不同请求复用同一个键返回 409。失败记录包含 `code`、`message`、`retryable`。安装用 `artifactId`，启动和卸载用 `bundleId`。Android 支持 `tap`、`key`、`shell`、`root`、`writable-system`、`snapshot-save`、`snapshot-load`。客体 shell 以 `{"argv":["id","-u"]}` 传参。

`android-aosp` 是普通配置，`android-research` 是 AOSP adb-root 配置，`android-magisk` 是 AOSP Magisk 配置，`android-google-apis` 对应 API 34 Google APIs 研究配置。iOS 配置为 `ios-development` 和 `ios-research`。应用模式默认复用已有安装和数据。Android 实时画面是当前客体显示器，应用窗口的呈现由前端负责。

开发工具可通过 `guest-push` 传入客体，参数为 `localPath` 与 `remotePath`。Android 的 `forward` 接收 `guestPort` 并返回分配的回环端口，`unforward` 接收 `localPort`。Frida 客户端可使用该端口连接用户启动的客体 Frida server。带 root 的 Android 配置还可用 `frida-start` / `frida-stop` 启停应用包内置的 frida-server（结果含 `host`、`localPort`、`pid`、`version`），详见 [frontend.md](frontend.md)。 [Frida Android 文档](https://frida.re/docs/android/)

## 本地验证入口

```bash
swift build
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer .build/debug/twinsimd
```

提供一份包含 launcher activity 的 ARM64 或纯 Java APK 和一份 ARM64 iOS Simulator `.app` 后，可以运行 `scripts/backend-smoke.py`。它通过 HTTP 验证鉴权、组件、导入、启动、幂等性、截图、日志、重复打开、卸载和停机。Android 使用 `android-google-apis` 时还验证客体 UID 0。可选参数包括 `--video`、`--writable-system` 和 `--frida-server /path/to/frida-server`。Frida 测试使用与客体服务端版本匹配的 Python 客户端。测试应使用专用 `TWINSIM_HOME`。
