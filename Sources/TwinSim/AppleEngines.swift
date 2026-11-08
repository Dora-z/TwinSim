import Foundation

struct Simulator: Sendable {
    let config: Configuration
    let scratch: URL

    var set: URL { config.root.appendingPathComponent("simulators") }
    var available: Bool {
        guard let dir = config.developerDir else { return false }
        return FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/simctl")
    }

    var environment: [String: String] {
        var env = config.environment
        env["DEVELOPER_DIR"] = config.developerDir
        return env
    }

    func call(_ args: [String], timeout: TimeInterval = 60, global: Bool = false) async throws -> Command.Output {
        guard available else { throw BackendError("XCODE_MISSING", "A full Xcode installation is required.") }
        try Files.directory(set)
        let prefix = global ? ["simctl"] : ["simctl", "--set", set.path]
        return try await Command("/usr/bin/xcrun", prefix + args, environment: environment, timeout: timeout).run(in: scratch)
    }

    func runtimes() async throws -> [[String: Any]] {
        let output = try await call(["list", "-j", "runtimes"], global: true)
        let items = try JSONSerialization.object(output.data)["runtimes"] as? [[String: Any]] ?? []
        return items.filter { ($0["isAvailable"] as? Bool) == true &&
            ($0["identifier"] as? String ?? "").hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-") }
    }

    func devices() async throws -> [[String: Any]] {
        let result = try await call(["list", "-j", "devices"])
        let groups = try JSONSerialization.object(result.data)["devices"] as? [String: [[String: Any]]] ?? [:]
        return groups.values.flatMap { $0 }
    }

    func create(_ device: Device) async throws -> String {
        if let existing = try await devices().first(where: { $0["name"] as? String == device.driverName }),
           let id = existing["udid"] as? String { return id }
        let ordered = try await runtimes().sorted {
            let comparison = ($0["version"] as? String ?? "").compare($1["version"] as? String ?? "", options: .numeric)
            if comparison == .orderedSame {
                return ($0["supportedDeviceTypes"] as? [Any] ?? []).count > ($1["supportedDeviceTypes"] as? [Any] ?? []).count
            }
            return comparison == .orderedDescending
        }
        guard let runtime = ordered.first, let id = runtime["identifier"] as? String else {
            throw BackendError("IOS_RUNTIME_MISSING", "Install an iOS Simulator runtime through Xcode.")
        }
        let supported = runtime["supportedDeviceTypes"] as? [[String: Any]] ?? []
        let phones = supported.filter { $0["productFamily"] as? String == "iPhone" || ($0["name"] as? String ?? "").hasPrefix("iPhone") }
        guard let type = (phones.first(where: { $0["name"] as? String == "iPhone 17" }) ?? phones.first)?["identifier"] as? String else {
            throw BackendError("IOS_DEVICE_TYPE_MISSING", "The selected iOS runtime does not report a compatible iPhone device type.")
        }
        let result = try await call(["create", device.driverName, type, id])
        let udid = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: udid) != nil else { throw BackendError("INVALID_TOOL_RESPONSE", "simctl did not return a device identifier.") }
        return udid
    }

    func start(_ id: String) async throws {
        let state = try await devices().first { $0["udid"] as? String == id }?["state"] as? String
        if state == "Shutdown" { _ = try await call(["boot", id]) }
        _ = try await call(["bootstatus", id], timeout: 240)
    }

    func stop(_ id: String) async throws {
        let state = try await devices().first { $0["udid"] as? String == id }?["state"] as? String
        if state != "Shutdown" { _ = try await call(["shutdown", id], timeout: 90) }
    }

    func setup() async throws {
        guard available else { throw BackendError("XCODE_MISSING", "Install Xcode, then reopen TwinSim or configure DEVELOPER_DIR.") }
        if try await runtimes().isEmpty {
            _ = try await Command("/usr/bin/xcodebuild", ["-downloadPlatform", "iOS", "-architectureVariant", "arm64"],
                                  environment: environment, timeout: 7200).run(in: scratch)
        }
        guard try await !runtimes().isEmpty else { throw BackendError("IOS_RUNTIME_MISSING", "Xcode did not report an available iOS runtime.") }
    }
}

struct VPhone: Sendable {
    static let setupURL = "https://lakr233.github.io/vphone-cli/get-started/quick-start.html"
    let config: Configuration
    let scratch: URL

    func blocker() async -> String? {
        let check = try? await Command("/usr/bin/csrutil", ["allow-research-guests", "status"]).run(in: scratch)
        if check?.text.localizedCaseInsensitiveContains("disabled") == true { return "RESEARCH_GUESTS_DISABLED" }
        if config.vphoneLaunchpad == nil { return "VPHONE_LAUNCHPAD_MISSING" }
        let result = try? await cli(["exec", "host", "preflight"], timeout: 30)
        return result == nil ? "VPHONE_PREFLIGHT_REQUIRED" : nil
    }

    func cli(_ args: [String], timeout: TimeInterval = 90, limit: Int = 32 << 20) async throws -> Command.Output {
        guard let path = config.vphoneLaunchpad else {
            throw BackendError("VPHONE_LAUNCHPAD_MISSING", "Install vphone Launchpad and its Core Bundle first.")
        }
        return try await Command(path, args, timeout: timeout).run(in: scratch, limit: limit)
    }

    func rpc(_ name: String, _ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 90) async throws -> Any {
        let json = try JSONSerialization.string(params)
        let output = try await cli(["guest", "rpc", name, method, json], timeout: timeout)
        return try JSONSerialization.jsonObject(with: output.data, options: [.fragmentsAllowed])
    }

    func create(_ device: Device, externalName: String?) async throws -> String {
        if let code = await blocker() { throw BackendError(code, "Complete the vphone host setup in Launchpad.") }
        if let name = externalName {
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$", options: .regularExpression) != nil,
                  FileManager.default.fileExists(atPath: config.vphoneMachines.appendingPathComponent(name).appendingPathComponent("config.plist").path)
            else { throw BackendError("VPHONE_MACHINE_NOT_FOUND", "The configured vphone library has no such VM.") }
            return name
        }
        let version = config.environment["TWINSIM_VPHONE_BUNDLE"]
        let iphone = config.environment["TWINSIM_VPHONE_IPSW"]
        let cloud = config.environment["TWINSIM_VPHONE_CLOUDOS"]
        guard let version, let iphone, let cloud else {
            throw BackendError("VPHONE_FIRMWARE_REQUIRED", "Import a prepared VM or configure a pinned Core Bundle and the two firmware paths.")
        }
        _ = try await cli(["vm", "create", device.driverName, "--bundle", version, "--device", "iPhone17,3",
                           "--iphone-source", iphone, "--cloudos-source", cloud,
                           "--memory", "4096", "--cpu", "4"], timeout: 7200)
        return device.driverName
    }

    func install(_ name: String, _ path: URL) async throws {
        let remote = "/var/root/Library/Caches/twinsim-\(UUID().uuidString).ipa"
        _ = try await cli(["guest", "push", name, path.path, remote, "--mode", "600"], timeout: 600)
        do {
            _ = try await rpc(name, "apps.install", ["path": remote], timeout: 600)
        } catch {
            _ = try? await rpc(name, "proc.run", ["path": "/bin/rm", "args": [remote]])
            throw error
        }
        _ = try? await rpc(name, "proc.run", ["path": "/bin/rm", "args": [remote]])
    }
}
