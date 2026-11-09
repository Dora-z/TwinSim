import Foundation

typealias ProgressUpdate = @Sendable (String, Int64?, Int64?) async -> Void

struct Android: Sendable {
    static let version = "0.3.1"
    static let downloadSize: Int64 = 22_500_543
    static let source = "https://github.com/AbdurahmanAlmehdi/jidr/releases/download/v0.3.1/Jidr-0.3.1-arm64.dmg"
    static let checksum = "67ec0516b65801743192a29e74e36a6508b72ef4707135691604e227b91fe402"
    let config: Configuration
    let scratch: URL

    var directory: URL { config.root.appendingPathComponent("runtime/jidr-\(Self.version)") }
    var executable: String? {
        let bundled = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("jidr").path
        return [config.jidrOverride, bundled, directory.appendingPathComponent("jidr").path]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var environment: [String: String] {
        var env = config.environment
        env["JIDR_HOME"] = config.root.appendingPathComponent("jidr").path
        env["ANDROID_ADB_SERVER_PORT"] = String(config.adbPort)
        env["ADB_MDNS"] = "0"
        env["ADB_SERVER_SOCKET"] = nil
        env["ANDROID_ADB_SERVER_ADDRESS"] = nil
        env["ADB_VENDOR_KEYS"] = nil
        env["ANDROID_AVD_HOME"] = nil
        env["ANDROID_USER_HOME"] = nil
        env["ANDROID_EMULATOR_HOME"] = nil
        return env
    }

    func setup(_ update: @escaping ProgressUpdate) async throws {
        if executable != nil { return }
        try Files.directory(directory)
        let archive = directory.appendingPathComponent("jidr.dmg.partial")
        let curl = ["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                    "--connect-timeout", "15", "--max-time", "90", "--retry", "2", "--retry-max-time", "250"]
        if Files.size(archive) != Self.downloadSize {
            await update("downloading-engine", Files.size(archive), Self.downloadSize)
            _ = try await Command(curl[0], Array(curl.dropFirst()) + ["--continue-at", "-", "--output", archive.path, Self.source],
                                  timeout: 270).run(in: scratch, heartbeat: {
                await update("downloading-engine", Files.size(archive), Self.downloadSize)
            })
        }
        await update("verifying-engine", Files.size(archive), Self.downloadSize)
        guard Files.size(archive) == Self.downloadSize, try Files.sha256(archive) == Self.checksum else {
            try? FileManager.default.removeItem(at: archive)
            throw BackendError("CHECKSUM_MISMATCH", "The downloaded Jidr release does not match the pinned checksum.", retryable: true)
        }
        let stage = try Files.scratch(in: scratch)
        let mount = stage.appendingPathComponent("disk")
        try Files.directory(mount)
        _ = try await Command("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, archive.path]).run(in: scratch)
        do {
            let source = mount.appendingPathComponent("Jidr.app/Contents/Helpers/jidr")
            _ = try await Command("/usr/bin/codesign", ["--verify", "--strict", source.path]).run(in: scratch)
            try FileManager.default.copyItem(at: source, to: stage.appendingPathComponent("jidr"))
            _ = try await Command("/usr/bin/hdiutil", ["detach", mount.path]).run(in: scratch)
            try FileManager.default.moveItem(at: stage.appendingPathComponent("jidr"), to: directory.appendingPathComponent("jidr"))
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: stage)
        } catch {
            _ = try? await Command("/usr/bin/hdiutil", ["detach", mount.path]).run(in: scratch)
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    func cli(_ args: [String], timeout: TimeInterval = 60) async throws -> Any {
        guard let executable else {
            throw BackendError("ANDROID_ENGINE_MISSING", "Install the Android engine component first.")
        }
        let output = try await Command(executable, ["--json"] + args, environment: environment, timeout: timeout)
            .run(in: scratch, check: false)
        guard let response = try? JSONSerialization.object(output.data) else {
            throw BackendError("ANDROID_TOOL_FAILED", String((output.stderr.isEmpty ? output.text : output.stderr).prefix(1000)))
        }
        guard response["ok"] as? Bool == true, output.code == 0 else {
            let error = response["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "tool_failed"
            let message = error?["message"] as? String ?? "The Android engine returned an error."
            throw BackendError("ANDROID_" + code.uppercased(), message, retryable: ["busy", "boot_timeout", "sdk"].contains(code))
        }
        return response["result"] ?? NSNull()
    }

    func sdkStatus() async throws -> [String: Any] {
        try await cli(["sdk", "status"]) as? [String: Any] ?? [:]
    }

    func isReady(_ profile: Profile) async throws -> Bool {
        guard executable != nil else { return false }
        let status = try await sdkStatus()
        return status["tools_sdk"] is String && (status["installed_images"] as? [String] ?? []).contains(profile.image)
    }

    func packages(_ profile: Profile) -> [String] { ["emulator", "platform-tools", profile.image] }

    func licenses(_ profile: Profile) async throws -> [LicenseText] {
        let list = try await cli(["sdk", "licenses"] + packages(profile))
        return try JSONDecoder().decode([LicenseText].self, from: JSONSerialization.data(withJSONObject: list))
    }

    func installRuntime(_ profile: Profile, consent: [String: String], update: ProgressUpdate) async throws {
        guard executable != nil else { throw BackendError("ANDROID_ENGINE_MISSING", "Install the Android engine first.") }
        if try await isReady(profile) { return }
        await update("checking-licenses", nil, nil)
        let pending = try await licenses(profile)
        guard pending.allSatisfy({ consent[$0.id] == $0.sha256 }) else {
            throw BackendError("LICENSE_CONSENT_REQUIRED", "Review and accept the exact SDK license shown by the component endpoint.")
        }
        for license in pending {
            let data = try JSONSerialization.string(["id": license.id, "sha256": license.sha256])
            _ = try await cli(["call", "sdk.accept_license", data])
        }
        await update("installing-android-packages", nil, nil)
        _ = try await cli(["sdk", "install"] + packages(profile), timeout: 3600)
        guard try await isReady(profile) else {
            throw BackendError("ANDROID_RUNTIME_INCOMPLETE", "The installed SDK did not pass the runtime probe.")
        }
    }

    func create(_ device: Device) async throws -> String {
        guard try await isReady(device.profileId) else {
            throw BackendError("COMPONENT_REQUIRED", "Install \(device.profileId.component) first.")
        }
        if let existing = try await devices().first(where: { $0["name"] as? String == device.driverName }),
           let id = existing["id"] as? String { return id }
        let result = try await cli(["device", "create", device.driverName, "--image", device.profileId.image,
                                    "--profile", "agent-lean", "--root", device.profileId.rootMode,
                                    "--cpus", String(hardware(device).cpus), "--ram", String(hardware(device).ramMB)], timeout: 300)
        guard let id = (result as? [String: Any])?["id"] as? String else {
            throw BackendError("INVALID_TOOL_RESPONSE", "Jidr did not return a device identifier.")
        }
        return id
    }

    func devices() async throws -> [[String: Any]] {
        try await cli(["device", "list"]) as? [[String: Any]] ?? []
    }

    func start(_ id: String) async throws {
        _ = try await cli(["device", "start", id, "--timeout", "180"], timeout: 205)
    }

    func stop(_ id: String) async throws {
        _ = try await cli(["device", "stop", id], timeout: 120)
    }

    func supportsWritableSystem() async -> Bool {
        guard let methods = try? await cli(["commands"]) as? [[String: Any]] else { return false }
        return methods.contains { $0["id"] as? String == "root.writable_system" }
    }

    func adb(_ id: String, _ args: [String], timeout: TimeInterval = 60) async throws -> Command.Output {
        try await adbCommand(id, args, timeout: timeout).run(in: scratch)
    }

    func adbCommand(_ id: String, _ args: [String], timeout: TimeInterval) async throws -> Command {
        let result = try await cli(["device", "connect-info", id])
        guard let info = result as? [String: Any], let path = info["adb_path"] as? String,
              let serial = info["adb_serial"] as? String, serial.hasPrefix("emulator-") else {
            throw BackendError("ANDROID_TRANSPORT", "The device has no managed ADB transport.", retryable: true)
        }
        return Command(path, ["-H", "127.0.0.1", "-P", String(config.adbPort), "-s", serial] + args,
                       environment: environment, timeout: timeout)
    }

    func install(_ id: String, _ path: URL) async throws {
        _ = try await cli(["install", id, path.path], timeout: 300)
    }

    func launch(_ id: String, bundle: String) async throws {
        let resolved = try await adb(id, ["shell", "cmd", "package", "resolve-activity", "--brief",
                                           "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", bundle])
        guard let component = resolved.text.split(whereSeparator: \.isNewline).last.map(String.init),
              component.hasPrefix(bundle + "/"), component.range(of: "^[A-Za-z0-9_.$/]+$", options: .regularExpression) != nil else {
            throw BackendError("APP_HAS_NO_LAUNCHER", "Android did not resolve a launcher activity for \(bundle).")
        }
        let output = try await adb(id, ["shell", "am", "start", "-W", "-n", Self.quote(component)])
        guard output.text.contains("Status: ok") else { throw BackendError("APP_LAUNCH_FAILED", output.text) }
    }

    /// Emulator resources. The guest's video encoder is software-only, so it needs cores of its own.
    /// Automatic: half the host's cores (2...6) and 3 GB (4 GB on hosts with 32 GB or more).
    static let tuningLevel = 1
    static var autoCpus: Int { min(6, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) }
    static var autoRamMB: Int { ProcessInfo.processInfo.physicalMemory >= 32 << 30 ? 4096 : 3072 }
    static var maxCpus: Int { max(1, ProcessInfo.processInfo.activeProcessorCount) }
    /// Leave at least 4 GB to macOS.
    static var maxRamMB: Int { max(2048, Int(ProcessInfo.processInfo.physicalMemory >> 20) - 4096) }

    /// Default for devices without their own values: Settings (TWINSIM_ANDROID_CPUS / _RAM_MB) or automatic.
    var defaultCpus: Int {
        Int(config.environment["TWINSIM_ANDROID_CPUS"] ?? "").flatMap { $0 > 0 ? min($0, Self.maxCpus) : nil } ?? Self.autoCpus
    }
    var defaultRamMB: Int {
        Int(config.environment["TWINSIM_ANDROID_RAM_MB"] ?? "").flatMap { $0 > 0 ? min(max($0, 1024), Self.maxRamMB) : nil } ?? Self.autoRamMB
    }
    var cpus: Int { defaultCpus }
    var ramMB: Int { defaultRamMB }

    func hardware(_ device: Device) -> (cpus: Int, ramMB: Int) {
        (device.cpus ?? defaultCpus, device.ramMB ?? defaultRamMB)
    }

    /// Writes CPU/RAM to a stopped device.
    func tune(_ id: String, cpus: Int, ramMB: Int) async throws {
        _ = try await cli(["device", "edit", id, "--cpus", String(cpus), "--ram", String(ramMB)], timeout: 60)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
