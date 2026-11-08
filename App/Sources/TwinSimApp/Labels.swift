import Foundation

/// Human-readable labels for backend identifiers. Unknown identifiers fall back to the raw value.
enum Labels {
    static func engine(_ id: String) -> String {
        switch id {
        case "android-emulator": "Android 模拟器"
        case "ios-simulator": "iOS Simulator"
        case "ios-vphone": "iOS 研究虚拟机 (vphone)"
        default: id
        }
    }

    static func profile(_ id: String) -> String {
        switch id {
        case "android-aosp": "Android AOSP"
        case "android-research": "Android 研究 (adb root)"
        case "android-magisk": "Android Magisk"
        case "android-google-apis": "Android Google APIs (研究)"
        case "ios-development": "iOS 开发 (Simulator)"
        case "ios-research": "iOS 研究 (vphone)"
        default: id
        }
    }

    static func state(_ id: String) -> String {
        switch id {
        case "creating": "创建中"
        case "stopped": "已停机"
        case "starting": "启动中"
        case "ready": "运行中"
        case "stopping": "停机中"
        case "failed": "失败"
        case "unknown": "状态未知"
        default: id
        }
    }

    static func component(_ id: String) -> String {
        switch id {
        case "android-engine": "Android 引擎 (Jidr)"
        case "android-display": "Android 实时画面 (scrcpy 服务端)"
        case "android-runtime": "Android AOSP ARM64 运行环境"
        case "android-google-apis": "Android Google APIs 运行环境"
        case "ios-simulator-runtime": "iOS Simulator runtime"
        case "ios-vphone": "iOS 研究虚拟机 (vphone)"
        default: id
        }
    }

    static func componentDetail(_ id: String) -> String {
        switch id {
        case "android-engine": "管理 Android SDK、AVD 与 ADB 的无界面引擎。创建 Android 设备前需要。"
        case "android-display": "提供 Android 实时 H.264 画面。未安装时使用截图。"
        case "android-runtime": "AOSP ARM64 系统镜像、Emulator 与 platform-tools，用于普通、adb root 与 Magisk 配置。"
        case "android-google-apis": "API 34 Google APIs ARM64 镜像，用于 Google APIs 研究配置。"
        case "ios-simulator-runtime": "运行 Simulator .app 需要完整 Xcode 和 iOS Simulator runtime。"
        case "ios-vphone": "运行真机 IPA 的研究虚拟机，由上游 vphone Launchpad 配置。"
        default: ""
        }
    }

    static func componentStatus(_ status: String) -> String {
        switch status {
        case "ready": "已就绪"
        case "downloadable": "可安装"
        case "needsConsent": "需确认许可"
        case "blocked": "暂不可用"
        case "externalSetup": "需外部配置"
        default: status
        }
    }

    static func artifactKind(_ kind: String) -> String {
        switch kind {
        case "apk": "Android APK"
        case "ipa": "iOS 真机 IPA"
        case "simulatorApp": "iOS Simulator .app"
        default: kind
        }
    }

    static func action(_ id: String) -> String {
        switch id {
        case "install-component": "安装组件"
        case "create": "创建设备"
        case "open-app": "打开应用"
        case "start": "启动"
        case "stop": "停机"
        case "install": "安装应用"
        case "launch": "启动应用"
        case "uninstall": "卸载应用"
        case "root": "验证 root"
        case "writable-system": "系统分区可写"
        case "snapshot-save": "保存快照"
        case "snapshot-load": "恢复快照"
        case "tap": "触控"
        case "key": "按键"
        case "shell": "客体 shell"
        case "guest-push": "传入文件"
        case "forward": "端口转发"
        case "unforward": "取消转发"
        default: id
        }
    }

    static func stage(_ id: String?) -> String? {
        guard let id else { return nil }
        switch id {
        case "downloading-engine": return "下载 Android 引擎"
        case "verifying-engine": return "校验 Android 引擎"
        case "downloading-display": return "下载 scrcpy 服务端"
        case "checking-licenses": return "检查许可"
        case "installing-android-packages": return "安装 Android SDK 组件"
        case "xcode-runtime": return "通过 Xcode 下载 iOS runtime"
        default: return id
        }
    }

    static func capability(_ id: String) -> String {
        switch id {
        case "input": "触控与按键"
        case "guestShell": "客体 shell"
        case "guestRoot": "root"
        case "writableSystem": "系统分区可写"
        case "snapshot": "快照"
        case "guestFiles": "文件传输"
        case "portForward": "端口转发"
        case "screenshot": "截图"
        case "liveVideo": "实时画面"
        case "logs": "日志"
        case "frida": "Frida"
        case "installApk": "安装 APK"
        case "installSimulatorApp": "安装 Simulator .app"
        case "installDeviceIpa": "安装 IPA"
        default: id
        }
    }

    /// Explanations for reason and error codes that need a user-facing next step.
    static func reason(_ code: String?) -> String? {
        guard let code else { return nil }
        switch code {
        case "RESEARCH_GUESTS_DISABLED":
            return "本机未启用 Research Guests。需在 macOS 恢复环境中运行 `csrutil allow-research-guests enable` 并重启，然后按上游说明完成 vphone 宿主机配置。"
        case "VPHONE_LAUNCHPAD_MISSING":
            return "未找到 vphone Launchpad。请安装 vphone-launchpad.app 及其 Core Bundle。"
        case "VPHONE_PREFLIGHT_REQUIRED":
            return "vphone 宿主机预检未通过。请在 Launchpad 中完成宿主机设置。"
        case "VPHONE_FIRMWARE_REQUIRED":
            return "需要先在 vphone 中准备虚拟机，或为后端配置 Core Bundle 与固件路径。"
        case "XCODE_MISSING":
            return "未找到完整 Xcode。请安装 Xcode，或在设置中指定 DEVELOPER_DIR。"
        case "IOS_RUNTIME_MISSING":
            return "未安装 iOS Simulator runtime。请在「组件」页安装。"
        case "ANDROID_ENGINE_MISSING":
            return "需要先安装 Android 引擎。"
        case "ANDROID_DISPLAY_MISSING":
            return "未安装 Android 实时画面组件，当前使用截图。"
        case "INSTANCE_NOT_READY":
            return "设备未运行。"
        case "LICENSE_CONSENT_REQUIRED":
            return "需要确认 SDK 许可。"
        case "COMPONENT_REQUIRED":
            return "缺少所需组件，请在「组件」页安装后重试。"
        case "ANDROID_ENGINE_UPGRADE_REQUIRED":
            return "当前 Android 引擎不支持系统分区可写。"
        case "BACKEND_RESTARTED":
            return "后端在操作完成前重启，可以重试。"
        case "RESOURCE_BUSY":
            return "该设备正在执行其他操作，请稍后重试。"
        case "TOOL_TIMEOUT":
            return "后端调用的工具超时。iOS Simulator 刚启动时读取日志较慢，可稍后重试。"
        case "OUTPUT_LIMIT":
            return "工具输出超过后端上限（32 MB）。iOS Simulator 刚启动时日志量很大，可稍后重试。"
        case "APP_PLATFORM_MISMATCH":
            return "应用与所选设备的平台不匹配。"
        default:
            return nil
        }
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
