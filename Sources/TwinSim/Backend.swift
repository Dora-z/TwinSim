import CoreGraphics
import Foundation

actor Backend {
    private let stateFile: URL
    private var state: State
    private var busy: Set<String> = []
    private let android: Android
    private let androidVideo: AndroidVideo
    private let simulator: Simulator
    private let vphone: VPhone
    private let windows: Wine
    private var windowCaptures: [UUID: Wine.WindowCapture] = [:]
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
        windows = Wine(config: config, scratch: scratch)
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
        if !Wine.rosettaAvailable {
            result.append(Component(id: "windows-wine", status: "externalSetup", version: Wine.version, source: Wine.setupURL,
                                    reasonCode: "ROSETTA_MISSING"))
        } else {
            result.append(Component(id: "windows-wine", status: windows.installed ? "ready" : "downloadable", version: "Wine \(Wine.version) (staging)",
                                    source: Wine.source, downloadBytes: Wine.downloadSize, requiredFreeBytes: 1_200_000_000))
        }
        if !Wine.rosettaAvailable {
            result.append(Component(id: "windows-d3dmetal", status: "externalSetup", version: Wine.gptkVersion, source: Wine.setupURL,
                                    reasonCode: "ROSETTA_MISSING"))
        } else if windows.installed(.gptk) {
            result.append(Component(id: "windows-d3dmetal", status: "ready", version: "Game Porting Toolkit \(Wine.gptkVersion)",
                                    source: Wine.gptkSource))
        } else {
            do {
                let license = try await windows.gptkLicense()
                result.append(Component(id: "windows-d3dmetal", status: "needsConsent", version: "Game Porting Toolkit \(Wine.gptkVersion)",
                                        source: Wine.gptkSource, downloadBytes: Wine.gptkSize, requiredFreeBytes: 1_500_000_000,
                                        licenses: [license]))
            } catch {
                result.append(Component(id: "windows-d3dmetal", status: "blocked", source: Wine.gptkLicenseURL,
                                        reasonCode: BackendError.wrap(error).code))
            }
        }
        result.append(Component(id: "windows-dxvk", status: !windows.installed ? "blocked" : (windows.dxvkInstalled ? "ready" : "downloadable"),
                                version: Wine.dxvkVersion, source: Wine.dxvkSource, downloadBytes: Wine.dxvkSize,
                                reasonCode: windows.installed ? nil : "WINE_MISSING"))
        return result
    }

    func installComponent(_ id: String, request: InstallComponentRequest, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        guard ["android-engine", "android-display", "android-runtime", "android-google-apis", "ios-simulator-runtime",
               "windows-wine", "windows-dxvk", "windows-d3dmetal"].contains(id) else {
            throw id == "ios-vphone"
                ? BackendError("EXTERNAL_SETUP_REQUIRED", "Set up vphone Launchpad and the host, then refresh components.")
                : BackendError("COMPONENT_NOT_FOUND", "No such component.")
        }
        let resource = id.hasPrefix("android-") ? "component:android" : id.hasPrefix("windows-") ? "component:windows" : "component:ios-simulator"
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
            case "windows-wine":
                guard Wine.rosettaAvailable else { throw BackendError("ROSETTA_MISSING", "Install Rosetta 2 first.") }
                try await backend.windows.setup(update)
            case "windows-dxvk":
                guard backend.windows.installed else { throw BackendError("WINE_MISSING", "Install windows-wine first.") }
                try await backend.windows.setupDXVK(update)
            case "windows-d3dmetal":
                guard Wine.rosettaAvailable else { throw BackendError("ROSETTA_MISSING", "Install Rosetta 2 first.") }
                await update("checking-licenses", nil, nil)
                let license = try await backend.windows.gptkLicense()
                guard request.acceptLicenses?[license.id] == license.sha256 else {
                    throw BackendError("LICENSE_CONSENT_REQUIRED", "Review and accept Apple's Game Porting Toolkit license shown by the component endpoint.")
                }
                try await backend.windows.setupGPTK(update)
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
        if device.engineId == .windows {
            var caps: [String: Capability] = [:]
            for key in ["installApk", "installSimulatorApp", "installDeviceIpa", "guestRoot", "writableSystem", "portForward",
                        "snapshot", "liveVideo", "frida"] { caps[key] = .unsupported }
            caps["installWindowsApp"] = online
            caps["screenshot"] = online
            caps["logs"] = online
            caps["guestShell"] = online
            caps["guestFiles"] = online
            caps["windowsTools"] = online
            caps["input"] = ready ? (Wine.inputAllowed ? .available : .blocked("ACCESSIBILITY_REQUIRED")) : online
            let isGPTK = device.driverID.map { windows.runtime($0) == .gptk } ?? (device.profileId == .d3dmetal)
            caps["dxvk"] = isGPTK ? .unsupported : (windows.dxvkInstalled ? online : .blocked("DXVK_MISSING"))
            caps["d3dmetal"] = isGPTK ? online : .unsupported
            return InstanceView(device, capabilities: caps)
        }
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
            case .windows:
                runtimeState = windows.isRunning(driverID) ? "ready" : "stopped"
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

    /// Deletes an imported app: optionally uninstalls it from the devices it was installed on,
    /// then removes the stored copy and the library entry.
    func deleteArtifact(_ id: UUID, uninstall: Bool, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        let artifact = try artifact(id)
        return try enqueue("delete-app", resource: "artifact:" + id.uuidString, key: key, fingerprint: fingerprint) { backend, _ in
            try await backend.removeArtifact(artifact, uninstall: uninstall)
        }
    }

    private func removeArtifact(_ artifact: Artifact, uninstall: Bool) async throws -> [String: String] {
        var uninstalled = 0
        var skipped: [String] = []
        for deviceID in state.instances.keys {
            guard let device = state.instances[deviceID], device.installed[artifact.bundleId] == artifact.id else { continue }
            if uninstall {
                if device.engineId == .windows, let driver = device.driverID {
                    // Programs copied into the prefix can be removed without starting the device;
                    // an MSI package needs its uninstaller, which needs the device running.
                    if artifact.kind == .windowsMsi && device.state != "ready" {
                        skipped.append(device.name)
                    } else if (try? await uninstallWindows(driver, artifact)) != nil {
                        uninstalled += 1
                    } else {
                        skipped.append(device.name)
                    }
                } else if device.state == "ready", !busy.contains(resource(deviceID)) {
                    if (try? await self.uninstall(deviceID, artifact.bundleId)) != nil { uninstalled += 1; continue }
                    skipped.append(device.name)
                } else {
                    skipped.append(device.name)
                }
            }
            if var current = state.instances[deviceID] {
                current.installed[artifact.bundleId] = nil
                try put(current)
            }
        }
        try? FileManager.default.removeItem(at: importer.location(artifact).deletingLastPathComponent())
        state.artifacts[artifact.id] = nil
        try save()
        publish("artifact-deleted", ["id": artifact.id.uuidString])
        var result = ["artifactId": artifact.id.uuidString, "uninstalled": String(uninstalled)]
        if !skipped.isEmpty { result["notUninstalled"] = skipped.joined(separator: ", ") }
        return result
    }

    private func uninstallWindows(_ driver: String, _ artifact: Artifact) async throws {
        let directory = windows.appDirectory(driver, artifact)
        if artifact.kind == .windowsMsi {
            let package = directory.appendingPathComponent(artifact.filename)
            if FileManager.default.fileExists(atPath: package.path) {
                try await windows.wine(driver, ["msiexec", "/x", package.path, "/qb"], timeout: 900)
            }
        }
        try? FileManager.default.removeItem(at: directory)
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
            if request.launch != false { try await backend.launchApp(target.id, bundle: artifact.bundleId) }
            return ["instanceId": target.id.uuidString, "bundleId": artifact.bundleId]
        }
    }

    func action(_ id: UUID, action: String, request: ActionRequest, key: String?, fingerprint: String) throws -> Operation {
        if let existing = try previous(key, fingerprint) { return existing }
        let device = try device(id)
        guard ["start", "stop", "delete", "install", "launch", "root", "writable-system", "snapshot-save",
               "snapshot-load", "tap", "key", "text", "shell", "uninstall", "guest-push", "forward", "unforward",
               "wine-tool", "dxvk", "display"].contains(action) else {
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
        case "delete":
            return try await delete(id)
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
        case .android:
            driverID = try await android.create(device)
            device.hardwareTuning = Android.tuningLevel
        case .simulator: driverID = try await simulator.create(device)
        case .vphone: driverID = try await vphone.create(device, externalName: device.externalName)
        case .windows: driverID = try await windows.create(device)
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
            if device.hardwareTuning != Android.tuningLevel {
                // Older devices used 2 cores / 2 GB; give them room for the software video encoder.
                if (try? await android.tune(driver)) != nil {
                    device.hardwareTuning = Android.tuningLevel
                    try put(device)
                }
            }
            try await android.start(driver)
            let uid = try? await android.adb(driver, ["shell", "id", "-u"])
            let selinux = try? await android.adb(driver, ["shell", "getenforce"])
            device.guestUid = uid.flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            device.selinux = selinux?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .simulator:
            try await simulator.start(driver)
        case .vphone:
            _ = try await vphone.cli(["vm", "start", driver, "--headless", "--wait", "--timeout", "240"], timeout: 260)
        case .windows:
            try await windows.start(driver)
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
        case .windows: try await windows.stop(driver)
        }
        windowCaptures[id] = nil
        device.state = "stopped"
        device.guestUid = nil
        device.selinux = nil
        device.forwardedPorts = nil
        try put(device)
    }

    /// Stops the instance if needed, deletes its engine resources and forgets it. Android AVDs and
    /// Simulator devices are deleted with their data; a vphone VM is only unregistered, because its
    /// files belong to the vphone library.
    private func delete(_ id: UUID) async throws -> [String: String] {
        let device = try device(id)
        var detail = "deleted"
        if let driver = device.driverID {
            if device.state != "stopped" {
                do { try await stop(id) }
                catch where device.state == "unknown" || device.state == "failed" { /* engine may already be gone */ }
            }
            switch device.engineId {
            case .android:
                do {
                    _ = try await android.cli(["device", "delete", "--yes", driver], timeout: 180)
                } catch {
                    // Already gone from the engine: nothing left to delete.
                    let known = (try? await android.devices())?.contains { $0["id"] as? String == driver } ?? true
                    if known { throw error }
                }
            case .simulator:
                do {
                    _ = try await simulator.call(["delete", driver], timeout: 120)
                } catch {
                    let known = (try? await simulator.devices())?.contains { $0["udid"] as? String == driver } ?? true
                    if known { throw error }
                }
            case .vphone:
                detail = "unregistered"
            case .windows:
                if windows.isRunning(driver) { try? await windows.stop(driver) }
                try? FileManager.default.removeItem(at: windows.prefix(driver))
                try? FileManager.default.removeItem(at: windows.log(driver))
            }
        }
        state.instances[id] = nil
        streaming.remove(id)
        try save()
        publish("instance-deleted", ["id": id.uuidString, "result": detail])
        return ["instanceId": id.uuidString, "result": detail]
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
        case .windows:
            try windows.install(driver, artifact, from: path)
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
        case .windows:
            guard let artifactID = device.installed[bundle], let artifact = state.artifacts[artifactID] else {
                throw BackendError("APP_NOT_INSTALLED", "Install the program on this device first.")
            }
            try windows.launch(driver, artifact)
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
        case .windows:
            if let artifactID = device.installed[bundle], let artifact = state.artifacts[artifactID] {
                try await uninstallWindows(driver, artifact)
            }
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
        case (.windows, "tap"):
            guard let x = request.x, let y = request.y, (0...10000).contains(x), (0...10000).contains(y) else {
                throw BackendError("INVALID_INPUT", "Specify nonnegative coordinates in the latest screenshot.")
            }
            let capture = try await windowCapture(id, driver)
            let point = CGPoint(x: capture.bounds.minX + Double(x) * capture.bounds.width / max(1, capture.pixelSize.width),
                                y: capture.bounds.minY + Double(y) * capture.bounds.height / max(1, capture.pixelSize.height))
            await MainActor.run { Wine.activate(capture.owner) }
            try await Task.sleep(for: .milliseconds(120))
            try Wine.click(at: point)
            return ["x": String(Int(point.x)), "y": String(Int(point.y))]
        case (.windows, "key"), (.windows, "text"):
            guard let value = request.value, !value.isEmpty, value.count <= 4000 else {
                throw BackendError("INVALID_INPUT", "Specify a key name or text.")
            }
            let capture = try await windowCapture(id, driver)
            await MainActor.run { Wine.activate(capture.owner) }
            try await Task.sleep(for: .milliseconds(120))
            if action == "key" { try Wine.key(value) } else { try Wine.type(value) }
        case (.windows, "shell"):
            guard let args = request.argv, !args.isEmpty, args.count <= 64,
                  args.allSatisfy({ $0.utf8.count < 16_384 && !$0.contains("\0") }) else {
                throw BackendError("INVALID_COMMAND", "Specify a guest command as an argument array, e.g. [\"cmd\", \"/c\", \"ver\"].")
            }
            let output = try await windows.wine(driver, args, timeout: 60, check: false)
            return ["stdout": String(output.text.replacingOccurrences(of: "\r\n", with: "\n").prefix(1 << 20)),
                    "stderr": output.stderr, "exitCode": String(output.code)]
        case (.windows, "guest-push"):
            let local = URL(fileURLWithPath: try Self.absolutePath(request.localPath)).resolvingSymlinksInPath()
            guard try local.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw BackendError("INVALID_FILE", "Select a regular local file.")
            }
            let target = try windows.hostPath(driver, windowsPath: request.remotePath ?? "")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: local, to: target)
        case (.windows, "wine-tool"):
            guard let value = request.value, let args = Wine.tools[value] else {
                throw BackendError("INVALID_ACTION", "Specify one of: \(Wine.tools.keys.sorted().joined(separator: ", ")).")
            }
            try windows.spawn(driver, args)
        case (.windows, "dxvk"):
            guard let value = request.value, ["on", "off"].contains(value) else { throw BackendError("INVALID_ACTION", "Specify on or off.") }
            if windows.runtime(driver) == .gptk { throw BackendError("CAPABILITY_UNSUPPORTED", "D3DMetal devices render Direct3D 11/12 with D3DMetal; DXVK does not apply.") }
            if value == "on" && !windows.dxvkInstalled { throw BackendError("DXVK_MISSING", "Install the windows-dxvk component first.") }
            var settings = windows.settings(driver)
            settings.dxvk = value == "on"
            try windows.save(settings, driver)
            return ["dxvk": value, "note": "Applies to programs started from now on."]
        case (.windows, "display"):
            guard let value = request.value, ["retina", "standard"].contains(value) else {
                throw BackendError("INVALID_ACTION", "Specify retina or standard.")
            }
            try await windows.applyDisplay(driver, retina: value == "retina")
            return ["display": value, "note": "Restart running programs to apply."]
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
        _ = try await refresh(id)
        let device = try running(id)
        if device.engineId == .windows, let driver = device.driverID {
            let url = try windows.hostPath(driver, windowsPath: remotePath ?? "")
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, Files.size(url) <= 128 << 20 else {
                throw BackendError("GUEST_FILE_UNSUPPORTED", "Select a regular file on C: of at most 128 MB.")
            }
            return try Data(contentsOf: url)
        }
        let remote = try Self.absolutePath(remotePath)
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
        case .simulator, .windows: throw BackendError("CAPABILITY_UNSUPPORTED", "Guest transfer is unavailable for this engine.")
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
        case .windows:
            let (data, capture) = try await windows.capture(driver)
            windowCaptures[id] = capture
            return ("image/png", data)
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
        case .windows:
            return windows.logs(driver, lines: limit)
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

    /// Opens a window-sized virtual display for one app (Android) and starts the app on it.
    func openAppSession(_ id: UUID, package: String, width: Int, height: Int, dpi: Int, fps: Int) async throws -> AppSession {
        _ = try await refresh(id)
        let device = try running(id)
        guard device.engineId == .android, let driver = device.driverID else {
            throw BackendError("CAPABILITY_UNSUPPORTED", "App windows are available for Android instances.")
        }
        guard Importer.identifier(package), !package.contains("/") else { throw BackendError("INVALID_BUNDLE_ID", "Specify a package name.") }
        let w = min(max(width, 240), 3840) & ~1, h = min(max(height, 240), 3840) & ~1
        return try await androidVideo.openApp(driver, package: package, width: w, height: h,
                                              dpi: min(max(dpi, 80), 640), fps: min(max(fps, 15), 120))
    }

    /// Input-only channel to the main display (device view).
    func openControlSession(_ id: UUID) async throws -> ControlSession {
        _ = try await refresh(id)
        let device = try running(id)
        guard device.engineId == .android, let driver = device.driverID else {
            throw BackendError("CAPABILITY_UNSUPPORTED", "The input channel is available for Android instances.")
        }
        return try await androidVideo.openControl(driver)
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
        case .windows: .windows
        }
    }

    /// Latest captured window (used to map screenshot pixels to screen points), capturing if needed.
    private func windowCapture(_ id: UUID, _ driver: String) async throws -> Wine.WindowCapture {
        // Reuse the last screenshot's pixel size while the same window keeps its size (it may have moved).
        if let capture = windowCaptures[id], let (window, bounds, owner) = windows.mainWindow(driver),
           window == capture.windowID, bounds.size == capture.bounds.size {
            return Wine.WindowCapture(windowID: window, bounds: bounds, pixelSize: capture.pixelSize, owner: owner)
        }
        let (_, capture) = try await windows.capture(driver)
        windowCaptures[id] = capture
        return capture
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
