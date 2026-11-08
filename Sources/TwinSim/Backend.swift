import Foundation

actor Backend {
    private let stateFile: URL
    private var state: State
    private var busy: Set<String> = []
    private let android: Android
    private let androidVideo: AndroidVideo
    private let simulator: Simulator
    private let vphone: VPhone
    private let importer: Importer
    let scratch: URL

    private let epoch = UUID().uuidString
    private var sequence = 0
    private var events: [(Int, String, Data)] = []
    private var streaming: Set<UUID> = []

    init(_ config: Configuration) throws {
        stateFile = config.root.appendingPathComponent("state.json")
        scratch = config.root.appendingPathComponent("scratch")
        try Files.directory(scratch)
        let artifacts = config.root.appendingPathComponent("artifacts")
        try Files.directory(artifacts)
        importer = Importer(directory: artifacts, scratch: scratch)
        android = Android(config: config, scratch: scratch)
        androidVideo = AndroidVideo(android: android)
        simulator = Simulator(config: config, scratch: scratch)
        vphone = VPhone(config: config, scratch: scratch)
        if FileManager.default.fileExists(atPath: stateFile.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
        } else {
            state = State()
        }
        for id in state.operations.keys where ["queued", "running"].contains(state.operations[id]?.state ?? "") {
            state.operations[id]?.state = "failed"
            state.operations[id]?.error = BackendError("BACKEND_RESTARTED", "The backend stopped before this operation completed.", retryable: true)
        }
        for id in state.instances.keys where ["creating", "starting", "stopping", "ready"].contains(state.instances[id]?.state ?? "") {
            state.instances[id]?.state = "unknown"
        }
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    func importApp(path: String) async throws -> Artifact {
        guard path.hasPrefix("/") else { throw BackendError("INVALID_ARTIFACT", "Select a local absolute file path.") }
        return try await register(importer.load(URL(fileURLWithPath: path)))
    }

    func importUpload(_ path: URL, filename: String) async throws -> Artifact {
        try await register(importer.load(path, name: filename))
    }

    private func register(_ artifact: Artifact) throws -> Artifact {
        if let existing = state.artifacts.values.first(where: { $0.kind == artifact.kind && $0.sha256 == artifact.sha256 }) {
            try? FileManager.default.removeItem(at: importer.location(artifact).deletingLastPathComponent())
            return existing
        }
        state.artifacts[artifact.id] = artifact
        do { try save() }
        catch {
            state.artifacts[artifact.id] = nil
            try? FileManager.default.removeItem(at: importer.location(artifact).deletingLastPathComponent())
            throw error
        }
        return artifact
    }

    func artifacts() -> [Artifact] { state.artifacts.values.sorted { $0.name < $1.name } }

    func operation(_ id: UUID) throws -> Operation {
        guard let operation = state.operations[id] else { throw BackendError("OPERATION_NOT_FOUND", "No such operation.") }
        return operation
    }

    func components() async -> [Component] {
        var result = [Component(id: "android-engine", status: android.executable == nil ? "downloadable" : "ready",
                                version: Android.version, source: Android.source, downloadBytes: Android.downloadSize)]
        result.append(Component(id: "android-display", status: androidVideo.installed ? "ready" : "downloadable",
                                version: AndroidVideo.version, source: AndroidVideo.source, downloadBytes: AndroidVideo.size))
        for profile in [Profile.android, .google] {
            guard android.executable != nil else {
                result.append(Component(id: profile.component, status: "blocked", reasonCode: "ANDROID_ENGINE_MISSING"))
                continue
            }
            do {
                if try await android.isReady(profile) {
                    result.append(Component(id: profile.component, status: "ready"))
                } else {
                    let licenses = try await android.licenses(profile)
                    result.append(Component(id: profile.component, status: licenses.isEmpty ? "downloadable" : "needsConsent",
                                            source: "https://developer.android.com/studio", requiredFreeBytes: 10_000_000_000,
                                            licenses: licenses))
                }
            } catch {
                result.append(Component(id: profile.component, status: "blocked", reasonCode: BackendError.wrap(error).code))
            }
        }
        if !simulator.available {
            result.append(Component(id: "ios-simulator-runtime", status: "externalSetup",
                                    source: "https://developer.apple.com/xcode/", reasonCode: "XCODE_MISSING"))
        } else {
            let installed = try? await simulator.runtimes()
            result.append(Component(id: "ios-simulator-runtime", status: (installed?.isEmpty == false) ? "ready" : "downloadable",
                                    version: installed?.first?["version"] as? String,
                                    source: "https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components"))
        }
        let reason = await vphone.blocker()
        result.append(Component(id: "ios-vphone", status: reason == nil ? "ready" : "externalSetup",
                                source: VPhone.setupURL, reasonCode: reason))
        return result
    }

    func installComponent(_ id: String, request: InstallComponentRequest, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        guard ["android-engine", "android-display", "android-runtime", "android-google-apis", "ios-simulator-runtime"].contains(id) else {
            throw id == "ios-vphone"
                ? BackendError("EXTERNAL_SETUP_REQUIRED", "Set up vphone Launchpad and the host, then refresh components.")
                : BackendError("COMPONENT_NOT_FOUND", "No such component.")
        }
        let resource = id.hasPrefix("android-") ? "component:android" : "component:ios-simulator"
        return try enqueue("install-component", resource: resource, key: key, fingerprint: fingerprint) { backend, operation in
            let update: ProgressUpdate = { stage, received, total in
                await backend.progress(operation, stage, received, total)
            }
            switch id {
            case "android-engine":
                try await backend.android.setup(update)
            case "android-display":
                try await backend.androidVideo.setup(update)
            case "android-runtime", "android-google-apis":
                let profile: Profile = id == "android-runtime" ? .android : .google
                try await backend.android.installRuntime(profile, consent: request.acceptLicenses ?? [:], update: update)
            default:
                await update("xcode-runtime", nil, nil)
                try await backend.simulator.setup()
            }
            return ["componentId": id]
        }
    }

    func instances() async -> [InstanceView] {
        let ids = state.instances.keys.sorted { $0.uuidString < $1.uuidString }
        var result = [InstanceView]()
        for id in ids {
            if let view = try? await instance(id) { result.append(view) }
        }
        return result
    }

    func instance(_ id: UUID) async throws -> InstanceView {
        let device = try await refresh(id)
        let ready = device.state == "ready"
        let online: Capability = ready ? .available : .blocked("INSTANCE_NOT_READY")
        let isAndroid = device.engineId == .android
        let writableSystem: Capability
        if isAndroid, device.profileId.rootMode == "adb" {
            writableSystem = await android.supportsWritableSystem() ? online : .blocked("ANDROID_ENGINE_UPGRADE_REQUIRED")
        } else {
            writableSystem = .unsupported
        }
        return InstanceView(device, capabilities: [
            "installApk": isAndroid ? online : .unsupported,
            "installSimulatorApp": device.engineId == .simulator ? online : .unsupported,
            "installDeviceIpa": device.engineId == .vphone ? online : .unsupported,
            "guestRoot": (isAndroid && device.profileId.rootMode != "none") || device.engineId == .vphone ? online : .unsupported,
            "writableSystem": writableSystem,
            "guestShell": device.engineId == .simulator ? .unsupported : online,
            "guestFiles": device.engineId == .simulator ? .unsupported : online,
            "portForward": isAndroid ? online : .unsupported,
            "screenshot": online,
            "input": device.engineId == .simulator ? .unsupported : online,
            "logs": online,
            "snapshot": isAndroid ? online : .unsupported,
            "liveVideo": isAndroid ? (androidVideo.installed ? online : .blocked("ANDROID_DISPLAY_MISSING")) : .unsupported,
            "frida": .unsupported,
        ])
    }

    private func refresh(_ id: UUID) async throws -> Device {
        let device = try device(id)
        guard let driverID = device.driverID, !busy.contains(resource(id)) else { return device }
        let runtimeState: String?
        do {
            switch device.engineId {
            case .android:
                let match = try await android.devices().first { $0["id"] as? String == driverID }
                let status = match?["status"] as? [String: Any]
                switch status?["state"] as? String {
                case "running": runtimeState = "ready"
                case "stopped", "hibernated": runtimeState = "stopped"
                case "starting", "booting": runtimeState = "starting"
                case "stopping": runtimeState = "stopping"
                case "crashed": runtimeState = "failed"
                default: runtimeState = nil
                }
            case .simulator:
                let match = try await simulator.devices().first { $0["udid"] as? String == driverID }
                switch match?["state"] as? String {
                case "Booted": runtimeState = "ready"
                case "Shutdown": runtimeState = "stopped"
                case "Booting": runtimeState = "starting"
                case "Shutting Down": runtimeState = "stopping"
                default: runtimeState = nil
                }
            case .vphone:
                let result = try await vphone.cli(["vm", "list"])
                let json = try JSONSerialization.jsonObject(with: result.data)
                let records = (json as? [[String: Any]]) ?? (json as? [String: Any])?["machines"] as? [[String: Any]] ?? []
                let vm = records.first { $0["name"] as? String == driverID }
                let status = (vm?["state"] as? String ?? vm?["status"] as? String)?.lowercased()
                runtimeState = status == "running" ? "ready" : (status == "stopped" ? "stopped" : nil)
            }
        } catch {
            runtimeState = nil
        }
        var current = try self.device(id)
        if !busy.contains(resource(id)), current.driverID == driverID, let runtimeState, runtimeState != current.state {
            current.state = runtimeState
            if runtimeState != "ready" { current.guestUid = nil; current.selinux = nil }
            try put(current)
        }
        return current
    }

    func create(_ request: CreateRequest, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.profileId.engine == request.engineId, !name.isEmpty, name.count <= 80 else {
            throw BackendError("INVALID_INSTANCE", "Provide a display name and a profile for the selected engine.")
        }
        if let externalName = request.externalName {
            guard request.engineId == .vphone,
                  !state.instances.values.contains(where: { $0.engineId == .vphone && $0.externalName == externalName }) else {
                throw BackendError("INVALID_INSTANCE", "The external VM must be unregistered and use the vphone engine.")
            }
        }
        let device = Device(id: UUID(), name: name, profileId: request.profileId, engineId: request.engineId,
                            purpose: "device", externalName: request.externalName, state: "creating")
        return try enqueue("create", resource: resource(device.id), key: key, fingerprint: fingerprint, instance: device.id,
                           newDevice: device) { backend, _ in
            _ = try await backend.prepare(device.id)
            return ["instanceId": device.id.uuidString]
        }
    }

    func launch(_ artifactID: UUID, request: LaunchRequest, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        let artifact = try artifact(artifactID)
        let target: Device
        var newDevice: Device?
        if let id = request.instanceId {
            target = try device(id)
            try compatible(target, artifact)
        } else {
            let profile = request.profileId ?? defaultProfile(for: artifact.kind.engine)
            guard profile.engine == artifact.kind.engine else { throw BackendError("APP_PLATFORM_MISMATCH", "The artifact cannot use that profile.") }
            if let device = state.instances.values.first(where: { $0.purpose == "app" && $0.profileId == profile }) {
                target = device
            } else {
                target = Device(id: UUID(), name: "Application workspace", profileId: profile, engineId: profile.engine,
                                purpose: "app", state: "creating")
                newDevice = target
            }
        }
        return try enqueue("open-app", resource: resource(target.id), key: key, fingerprint: fingerprint,
                           instance: target.id, newDevice: newDevice) { backend, _ in
            _ = try await backend.prepare(target.id)
            try await backend.start(target.id)
            try await backend.install(target.id, artifact)
            try await backend.launchApp(target.id, bundle: artifact.bundleId)
            return ["instanceId": target.id.uuidString, "bundleId": artifact.bundleId]
        }
    }

    func action(_ id: UUID, action: String, request: ActionRequest, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        let device = try device(id)
        guard ["start", "stop", "install", "launch", "root", "writable-system", "snapshot-save",
               "snapshot-load", "tap", "key", "shell", "uninstall", "guest-push", "forward", "unforward"].contains(action) else {
            throw BackendError("ACTION_NOT_FOUND", "No such instance action.")
        }
        if action == "install" {
            guard let artifactId = request.artifactId else { throw BackendError("INVALID_ARTIFACT", "Specify an artifactId.") }
            try compatible(device, artifact(artifactId))
        }
        return try enqueue(action, resource: resource(id), key: key, fingerprint: fingerprint, instance: id) { backend, _ in
            try await backend.perform(id, action, request)
        }
    }

    private func perform(_ id: UUID, _ action: String, _ request: ActionRequest) async throws -> [String: String] {
        switch action {
        case "start":
            _ = try await prepare(id)
            try await start(id)
        case "stop":
            try await stop(id)
        case "install":
            guard let artifactId = request.artifactId else { throw BackendError("INVALID_ARTIFACT", "Specify an artifactId.") }
            try await install(id, artifact(artifactId))
        case "launch", "uninstall":
            guard let bundle = request.bundleId, Importer.identifier(bundle) else {
                throw BackendError("INVALID_BUNDLE_ID", "Specify an application identifier.")
            }
            if action == "launch" {
                try await launchApp(id, bundle: bundle)
            } else {
                try await uninstall(id, bundle)
            }
        default:
            return try await control(id, action, request)
        }
        return ["instanceId": id.uuidString]
    }

    private func prepare(_ id: UUID) async throws -> Device {
        var device = try device(id)
        if device.driverID != nil { return device }
        let driverID: String
        switch device.engineId {
        case .android: driverID = try await android.create(device)
        case .simulator: driverID = try await simulator.create(device)
        case .vphone: driverID = try await vphone.create(device, externalName: device.externalName)
        }
        device.driverID = driverID
        device.state = "stopped"
        try put(device)
        return device
    }

    private func start(_ id: UUID) async throws {
        var device = try device(id)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "The instance has not been created.") }
        device.state = "starting"
        try put(device)
        switch device.engineId {
        case .android:
            try await android.start(driver)
            let uid = try? await android.adb(driver, ["shell", "id", "-u"])
            let selinux = try? await android.adb(driver, ["shell", "getenforce"])
            device.guestUid = uid.flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            device.selinux = selinux?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .simulator:
            try await simulator.start(driver)
        case .vphone:
            _ = try await vphone.cli(["vm", "start", driver, "--headless", "--wait", "--timeout", "240"], timeout: 260)
        }
        device.state = "ready"
        try put(device)
    }

    private func stop(_ id: UUID) async throws {
        var device = try device(id)
        if device.state == "stopped" { return }
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "The instance has not been created.") }
        device.state = "stopping"
        try put(device)
        switch device.engineId {
        case .android: try await android.stop(driver)
        case .simulator: try await simulator.stop(driver)
        case .vphone: _ = try await vphone.cli(["vm", "stop", driver])
        }
        device.state = "stopped"
        device.guestUid = nil
        device.selinux = nil
        device.forwardedPorts = nil
        try put(device)
    }

    private func install(_ id: UUID, _ artifact: Artifact) async throws {
        var device = try running(id)
        try compatible(device, artifact)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "Missing device identifier.") }
        let path = importer.location(artifact)
        switch device.engineId {
        case .android:
            let existing = try? await android.adb(driver, ["shell", "pm", "path", artifact.bundleId])
            if device.installed[artifact.bundleId] != artifact.id || existing?.text.contains("package:") != true {
                try await android.install(driver, path)
            }
        case .simulator:
            let installed = try? await simulator.call(["get_app_container", driver, artifact.bundleId, "app"])
            if device.installed[artifact.bundleId] != artifact.id || installed == nil {
                _ = try await simulator.call(["install", driver, path.path], timeout: 180)
            }
        case .vphone:
            try await vphone.install(driver, path)
        }
        device.installed[artifact.bundleId] = artifact.id
        try put(device)
    }

    private func launchApp(_ id: UUID, bundle: String) async throws {
        let device = try running(id)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "Missing device identifier.") }
        switch device.engineId {
        case .android: try await android.launch(driver, bundle: bundle)
        case .simulator: _ = try await simulator.call(["launch", driver, bundle])
        case .vphone: _ = try await vphone.rpc(driver, "apps.launch", ["bundle_id": bundle])
        }
    }

    private func uninstall(_ id: UUID, _ bundle: String) async throws {
        var device = try running(id)
        guard let driver = device.driverID, device.installed[bundle] != nil else {
            throw BackendError("APP_NOT_MANAGED", "TwinSim can uninstall applications that it installed.")
        }
        switch device.engineId {
        case .android: _ = try await android.adb(driver, ["uninstall", bundle])
        case .simulator: _ = try await simulator.call(["uninstall", driver, bundle])
        case .vphone: _ = try await vphone.rpc(driver, "apps.uninstall", ["bundle_id": bundle, "force": true])
        }
        device.installed[bundle] = nil
        try put(device)
    }

    private func control(_ id: UUID, _ action: String, _ request: ActionRequest) async throws -> [String: String] {
        var device = try running(id)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "Missing device identifier.") }
        switch (device.engineId, action) {
        case (.android, "root"):
            guard device.profileId.rootMode != "none" else { throw BackendError("ROOT_PROFILE_REQUIRED", "Select an Android research profile.") }
            _ = try await android.cli(["root", "verify", driver], timeout: 120)
            let argv = device.profileId.rootMode == "magisk" ? ["shell", "su", "-c", "'id -u'"] : ["shell", "id", "-u"]
            let uid = try await android.adb(driver, argv).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard uid == "0" else { throw BackendError("ROOT_NOT_VERIFIED", "Guest root verification did not return UID 0.") }
            device.guestUid = 0
            try put(device)
            return ["uid": uid]
        case (.android, "writable-system"):
            guard device.profileId.rootMode == "adb", let value = request.value, ["on", "off"].contains(value) else {
                throw BackendError("INVALID_ACTION", "Specify on or off on an adb-root profile.")
            }
            guard await android.supportsWritableSystem() else {
                throw BackendError("ANDROID_ENGINE_UPGRADE_REQUIRED", "The installed Android helper does not support writable-system.")
            }
            _ = try await android.cli(["root", "writable-system", driver, value], timeout: 360)
        case (.android, "snapshot-save"), (.android, "snapshot-load"):
            guard let name = request.snapshot, name.range(of: "^[A-Za-z0-9_-]{1,48}$", options: .regularExpression) != nil else {
                throw BackendError("INVALID_SNAPSHOT", "Specify a snapshot name.")
            }
            let verb = action == "snapshot-save" ? "save" : "load"
            _ = try await android.cli(["snapshot", verb, driver, name], timeout: 180)
        case (.android, "tap"), (.vphone, "tap"):
            guard let x = request.x, let y = request.y, (0...10000).contains(x), (0...10000).contains(y) else {
                throw BackendError("INVALID_INPUT", "Specify nonnegative screen coordinates.")
            }
            if device.engineId == .android {
                _ = try await android.adb(driver, ["shell", "input", "tap", String(x), String(y)])
            } else {
                let payload = try JSONSerialization.string(["t": "tap", "x": x, "y": y])
                _ = try await vphone.cli(["guest", "send", driver, payload])
            }
        case (.android, "key"), (.vphone, "key"):
            guard let value = request.value, value.range(of: "^[A-Za-z0-9_+.-]{1,40}$", options: .regularExpression) != nil else {
                throw BackendError("INVALID_INPUT", "Specify a valid key.")
            }
            if device.engineId == .android {
                _ = try await android.adb(driver, ["shell", "input", "keyevent", value])
            } else {
                _ = try await vphone.rpc(driver, "input.key", ["name": value])
            }
        case (.android, "shell"), (.vphone, "shell"):
            guard let args = request.argv, let executable = args.first, args.count <= 64,
                  !executable.isEmpty, args.allSatisfy({ $0.utf8.count < 16_384 && !$0.contains("\0") }) else {
                throw BackendError("INVALID_COMMAND", "Specify a guest command as an argument array.")
            }
            if device.engineId == .android {
                let output = try await android.adb(driver, ["shell", args.map(Android.quote).joined(separator: " ")], timeout: 30)
                return ["stdout": String(output.text.prefix(1 << 20)), "stderr": output.stderr, "exitCode": String(output.code)]
            }
            let output = try await vphone.rpc(driver, "proc.run", ["path": executable, "args": Array(args.dropFirst())], timeout: 30)
            return ["guestResult": String(decoding: try JSONSerialization.data(withJSONObject: output, options: .fragmentsAllowed), as: UTF8.self)]
        case (.android, "guest-push"), (.vphone, "guest-push"):
            let local = URL(fileURLWithPath: try Self.absolutePath(request.localPath)).resolvingSymlinksInPath()
            let remote = try Self.absolutePath(request.remotePath)
            guard try local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw BackendError("INVALID_FILE", "Select a regular local file.")
            }
            if device.engineId == .android {
                _ = try await android.adb(driver, ["push", local.path, remote], timeout: 600)
            } else {
                _ = try await vphone.cli(["guest", "push", driver, local.path, remote], timeout: 600)
            }
        case (.android, "forward"):
            guard let guestPort = request.guestPort, (1...65535).contains(guestPort) else {
                throw BackendError("INVALID_PORT", "Specify a guest TCP port.")
            }
            let response = try await android.adb(driver, ["forward", "tcp:0", "tcp:\(guestPort)"])
            guard let localPort = Int(response.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...65535).contains(localPort) else {
                throw BackendError("INVALID_TOOL_RESPONSE", "ADB did not return the forwarded port.")
            }
            device.forwardedPorts = (device.forwardedPorts ?? []) + [localPort]
            do { try put(device) }
            catch {
                _ = try? await android.adb(driver, ["forward", "--remove", "tcp:\(localPort)"])
                throw error
            }
            return ["host": "127.0.0.1", "localPort": String(localPort), "guestPort": String(guestPort)]
        case (.android, "unforward"):
            guard let localPort = request.localPort, device.forwardedPorts?.contains(localPort) == true else {
                throw BackendError("FORWARD_NOT_FOUND", "No managed forward uses that port.")
            }
            _ = try await android.adb(driver, ["forward", "--remove", "tcp:\(localPort)"])
            device.forwardedPorts?.removeAll { $0 == localPort }
            try put(device)
        default:
            throw BackendError("CAPABILITY_UNSUPPORTED", "The instance does not support this action.")
        }
        return ["instanceId": id.uuidString]
    }

    private static func absolutePath(_ path: String?) throws -> String {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw BackendError("INVALID_PATH", "Specify an absolute file path.")
        }
        return path
    }

    func pull(_ id: UUID, remotePath: String?) async throws -> Data {
        let remote = try Self.absolutePath(remotePath)
        _ = try await refresh(id)
        let device = try running(id)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "Missing device identifier.") }
        let folder = try Files.scratch(in: scratch)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("guest-file")
        switch device.engineId {
        case .android:
            let path = Android.quote(remote)
            let check = "test -f \(path) && stat -L -c %s \(path)"
            let metadata = try await android.adb(driver, ["shell", "sh", "-c", Android.quote(check)])
            guard let size = Int64(metadata.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  size <= 128 << 20 else {
                throw BackendError("GUEST_FILE_UNSUPPORTED", "Select a regular guest file at most 128 MB.")
            }
            _ = try await android.adb(driver, ["pull", remote, output.path], timeout: 600)
        case .vphone: _ = try await vphone.cli(["guest", "pull", driver, remote, output.path], timeout: 600)
        case .simulator: throw BackendError("CAPABILITY_UNSUPPORTED", "Guest transfer is unavailable for this engine.")
        }
        let file = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard file.isRegularFile == true, file.isSymbolicLink != true,
              Files.size(output) <= 128 << 20 else {
            throw BackendError("GUEST_FILE_UNSUPPORTED", "The response must be a regular file at most 128 MB.")
        }
        return try Data(contentsOf: output)
    }

    func screenshot(_ id: UUID) async throws -> (String, Data) {
        _ = try await refresh(id)
        let device = try running(id)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "Missing device identifier.") }
        switch device.engineId {
        case .android:
            let output = try await android.adb(driver, ["exec-out", "screencap", "-p"])
            return ("image/png", output.data)
        case .simulator:
            let folder = try Files.scratch(in: scratch)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("screen.png")
            _ = try await simulator.call(["io", driver, "screenshot", "--type=png", "--display=primary", file.path])
            let image = try Data(contentsOf: file)
            guard image.starts(with: [0x89, 0x50, 0x4e, 0x47]) else {
                throw BackendError("INVALID_TOOL_RESPONSE", "The Simulator did not produce a PNG screenshot.")
            }
            return ("image/png", image)
        case .vphone:
            let output = try await vphone.rpc(driver, "screen.screenshot") as? [String: Any]
            let encoded = (output?["data"] ?? output?["data_base64"] ?? output?["base64"]) as? String
            guard let encoded, let data = Data(base64Encoded: encoded) else {
                throw BackendError("INVALID_TOOL_RESPONSE", "The VM did not return a screenshot.")
            }
            return ("image/jpeg", data)
        }
    }

    func logs(_ id: UUID, lines: Int) async throws -> String {
        _ = try await refresh(id)
        let device = try running(id)
        guard let driver = device.driverID else { throw BackendError("INSTANCE_UNAVAILABLE", "Missing device identifier.") }
        let limit = max(1, min(lines, 1000))
        switch device.engineId {
        case .android:
            return try await android.adb(driver, ["logcat", "-d", "-t", String(limit)]).text
        case .simulator:
            let output = try await simulator.call(["spawn", driver, "log", "show", "--last", "30s", "--style", "compact"])
            return output.text.split(whereSeparator: \.isNewline).suffix(limit).joined(separator: "\n")
        case .vphone:
            return try await vphone.cli(["vm", "log", driver, "--lines", String(limit)]).text
        }
    }

    func openVideo(_ id: UUID) async throws -> VideoSession {
        _ = try await refresh(id)
        let device = try running(id)
        guard device.engineId == .android, let driver = device.driverID else {
            throw BackendError("CAPABILITY_UNSUPPORTED", "Live H.264 is available for Android instances.")
        }
        guard streaming.insert(id).inserted else {
            throw BackendError("RESOURCE_BUSY", "This instance already has a video subscriber.", retryable: true)
        }
        do { return try await androidVideo.open(driver) }
        catch { streaming.remove(id); throw error }
    }

    func closeVideo(_ id: UUID, session: VideoSession) async {
        await session.close()
        streaming.remove(id)
    }

    private func running(_ id: UUID) throws -> Device {
        let device = try device(id)
        guard device.state == "ready" else { throw BackendError("INSTANCE_NOT_READY", "Start the instance first.", retryable: true) }
        return device
    }

    private func defaultProfile(for engine: Engine) -> Profile {
        switch engine {
        case .android: .android
        case .simulator: .simulator
        case .vphone: .vphone
        }
    }

    private func compatible(_ device: Device, _ artifact: Artifact) throws {
        guard device.engineId == artifact.kind.engine else {
            throw BackendError("APP_PLATFORM_MISMATCH", "The artifact cannot be installed on this instance.")
        }
    }

    private func device(_ id: UUID) throws -> Device {
        guard let device = state.instances[id] else { throw BackendError("INSTANCE_NOT_FOUND", "No such instance.") }
        return device
    }

    private func artifact(_ id: UUID) throws -> Artifact {
        guard let artifact = state.artifacts[id] else { throw BackendError("ARTIFACT_NOT_FOUND", "No such artifact.") }
        return artifact
    }

    private func put(_ device: Device) throws {
        let old = state.instances.updateValue(device, forKey: device.id)
        do { try save() }
        catch { state.instances[device.id] = old; throw error }
        publish("instance", InstanceView(device, capabilities: [:]))
    }

    private func resource(_ id: UUID) -> String { "device:" + id.uuidString }

    private func previous(_ key: String?, _ fingerprint: String) throws -> Operation? {
        guard let key, let record = state.idempotency[key] else { return nil }
        guard record.fingerprint == fingerprint else {
            throw BackendError("IDEMPOTENCY_CONFLICT", "This Idempotency-Key was used for a different request.")
        }
        return try operation(record.operation)
    }

    private func enqueue(_ action: String, resource: String, key: String?, fingerprint: String,
                         instance: UUID? = nil, newDevice: Device? = nil,
                         job: @escaping @Sendable (Backend, UUID) async throws -> [String: String]) throws -> Operation {
        guard !busy.contains(resource) else { throw BackendError("RESOURCE_BUSY", "Another operation is already in progress.", retryable: true) }
        let id = UUID()
        let operation = Operation(id: id, action: action, state: "queued", instanceId: instance)
        state.operations[id] = operation
        if let key { state.idempotency[key] = Idempotency(fingerprint: fingerprint, operation: id) }
        if let newDevice { state.instances[newDevice.id] = newDevice }
        do { try save() }
        catch {
            state.operations[id] = nil
            if let key { state.idempotency[key] = nil }
            if let newDevice { state.instances[newDevice.id] = nil }
            throw error
        }
        busy.insert(resource)
        publish("operation", operation)
        Task {
            await self.run(id, resource: resource, job)
        }
        return operation
    }

    private func run(_ id: UUID, resource: String,
                     _ job: @Sendable (Backend, UUID) async throws -> [String: String]) async {
        guard var operation = state.operations[id] else { busy.remove(resource); return }
        defer { busy.remove(resource) }
        operation.state = "running"
        state.operations[id] = operation
        publish("operation", operation)
        do {
            try save()
            operation.result = try await job(self, id)
            operation.state = "succeeded"
        } catch {
            operation.error = BackendError.wrap(error)
            operation.state = "failed"
            if let instance = operation.instanceId, var device = state.instances[instance],
               ["creating", "starting", "stopping"].contains(device.state) {
                device.state = "failed"
                try? put(device)
            }
        }
        operation.stage = state.operations[id]?.stage
        operation.receivedBytes = state.operations[id]?.receivedBytes
        operation.totalBytes = state.operations[id]?.totalBytes
        state.operations[id] = operation
        do { try save() }
        catch {
            operation.state = "failed"
            operation.error = BackendError("STATE_WRITE_FAILED", error.localizedDescription, retryable: true)
            state.operations[id] = operation
        }
        publish("operation", operation)
    }

    private func progress(_ id: UUID, _ stage: String, _ received: Int64?, _ total: Int64?) {
        guard var operation = state.operations[id] else { return }
        operation.stage = stage
        operation.receivedBytes = received
        operation.totalBytes = total
        state.operations[id] = operation
        publish("operation", operation)
    }

    private func save() throws {
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    private func publish<T: Encodable>(_ kind: String, _ value: T) {
        guard let payload = try? JSONEncoder().encode(value) else { return }
        sequence += 1
        events.append((sequence, kind, payload))
        if events.count > 256 { events.removeFirst(events.count - 256) }
    }

    func eventBatch(after id: String?) -> [(String, String, Data)] {
        guard let id else { return [("\(epoch):\(sequence)", "reset", Data("{}".utf8))] }
        let fields = id.split(separator: ":", maxSplits: 1)
        guard fields.count == 2, fields[0] == epoch, let previous = Int(fields[1]), previous >= 0, previous <= sequence,
              previous >= (events.first?.0 ?? 1) - 1 else {
            return [("\(epoch):\(sequence)", "reset", Data("{}".utf8))]
        }
        return events.filter { $0.0 > previous }.map { ("\(epoch):\($0.0)", $0.1, $0.2) }
    }
}
