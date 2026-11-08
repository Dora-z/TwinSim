import AppKit
import Foundation
import Observation
import SwiftUI

struct ScreenTarget: Codable, Hashable, Sendable {
    var instanceId: UUID
    /// Set when the window was opened for a single application (single-app mode).
    var artifactId: UUID?
}

struct UserNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var code: String?
    var link: URL?
}

struct OperationFailure: LocalizedError, Sendable {
    let operation: BackendOperation
    var body: APIErrorBody { operation.error ?? APIErrorBody(code: "OPERATION_FAILED", message: "操作失败。") }
    var errorDescription: String? {
        if let hint = Labels.reason(body.code) { return "\(hint)\n(\(body.code): \(body.message))" }
        return "\(body.message) (\(body.code))"
    }
}

/// Central frontend state: backend lifecycle, cached API resources and tracked operations.
@MainActor @Observable
final class AppStore {
    enum Connection: Equatable {
        case idle
        case starting
        case connected
        case restarting(attempt: Int, delay: Int)
        case failed(message: String, diagnostics: String)
    }

    var connection: Connection = .idle
    var eventsConnected = false
    var components: [Component] = []
    var engines: [EngineInfo] = []
    var instances: [Instance] = []
    var artifacts: [Artifact] = []
    var operations: [UUID: BackendOperation] = [:]
    var operationOrder: [UUID] = []
    var notices: [UserNotice] = []
    var launching: Set<UUID> = []        // artifact IDs being opened
    var settings = BackendSettings.load()
    var backendDiagnostics: String { process?.diagnostics ?? "" }
    var helperPath: String? { process?.executable.path }

    @ObservationIgnored var openWindowAction: OpenWindowAction?
    @ObservationIgnored var agentBridge: AgentBridge?
    @ObservationIgnored private(set) var client: APIClient?
    @ObservationIgnored private var process: BackendProcess?
    @ObservationIgnored private var events: EventStream?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartAttempts: [Date] = []
    @ObservationIgnored private var instanceRefreshes: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var periodic: Task<Void, Never>?
    @ObservationIgnored private var shuttingDown = false

    var isConnected: Bool { connection == .connected }

    // Open screen windows register their session (weakly) so tooling and tests can reach them.
    @ObservationIgnored private let sessions = NSMapTable<NSUUID, ScreenSession>.strongToWeakObjects()
    func register(_ session: ScreenSession) { sessions.setObject(session, forKey: session.instanceId as NSUUID) }
    func screenSession(_ id: UUID) -> ScreenSession? { sessions.object(forKey: id as NSUUID) }
    var helperPID: Int32? { process?.isRunning == true ? process?.pid : nil }

    func instance(_ id: UUID) -> Instance? { instances.first { $0.id == id } }
    func artifact(_ id: UUID) -> Artifact? { artifacts.first { $0.id == id } }
    func component(_ id: String) -> Component? { components.first { $0.id == id } }

    var needsSetup: Bool {
        guard !components.isEmpty else { return false }
        let android = ["android-engine"].allSatisfy { component($0)?.isReady == true }
        let anyRuntime = ["android-runtime", "android-google-apis", "ios-simulator-runtime"].contains { component($0)?.isReady == true }
        return !android || !anyRuntime
    }

    // MARK: Backend lifecycle

    func startBackend() async {
        guard !shuttingDown else { return }
        generation += 1
        let myGeneration = generation
        connection = .starting
        events?.stop()
        events = nil
        client = nil
        if let old = process { old.onExit = nil; old.terminate() }
        process = nil
        HelperRegistry.reapOrphan()
        guard let helper = BackendProcess.locateHelper() else {
            connection = .failed(message: "找不到内置的 twinsimd。请重新安装 TwinSim。", diagnostics: "")
            return
        }
        let process = BackendProcess(executable: helper, settings: settings)
        process.onExit = { [weak self] status, intentional in
            Task { @MainActor in self?.helperExited(status: status, intentional: intentional, generation: myGeneration) }
        }
        self.process = process
        do {
            let handshake = try await process.start()
            guard myGeneration == generation else { return }
            let client = try APIClient(handshake: handshake)
            _ = try await client.health()
            self.client = client
            connection = .connected
            let stream = EventStream(client: client, onEvent: { [weak self] event in
                guard myGeneration == self?.generation else { return }
                self?.handle(event)
            }, onConnection: { [weak self] connected in
                guard myGeneration == self?.generation else { return }
                self?.eventsConnected = connected
            }, onUnauthorized: { [weak self] in
                guard myGeneration == self?.generation else { return }
                Task { await self?.startBackend() }
            })
            events = stream
            stream.start()
            await reloadAll()
            startPeriodicRefresh()
        } catch {
            guard myGeneration == generation else { return }
            let diagnostics = (error as? BackendLaunchError)?.diagnostics ?? process.diagnostics
            connection = .failed(message: error.localizedDescription, diagnostics: diagnostics)
            process.onExit = nil
            process.terminate()
        }
    }

    private func helperExited(status: Int32, intentional: Bool, generation exited: Int) {
        guard exited == generation, !intentional, !shuttingDown else { return }
        events?.stop()
        eventsConnected = false
        client = nil
        let diagnostics = process?.diagnostics ?? ""
        let now = Date()
        restartAttempts = restartAttempts.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard restartAttempts.count <= 4 else {
            connection = .failed(message: "后端连续意外退出 (状态 \(status))，已停止自动重启。", diagnostics: diagnostics)
            return
        }
        let delay = 1 << (restartAttempts.count - 1)
        connection = .restarting(attempt: restartAttempts.count, delay: delay)
        post(UserNotice(title: "后端意外退出", message: "状态 \(status)。将在 \(delay) 秒后重新启动并重新同步设备状态。"))
        let gen = generation
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard gen == self.generation, !self.shuttingDown else { return }
            await self.startBackend()
        }
    }

    func restartBackend() async {
        restartAttempts.removeAll()
        await startBackend()
    }

    func applySettings(_ new: BackendSettings) async {
        new.save()
        settings = new
        await restartBackend()
    }

    /// Stops the helper. Devices stay under engine management unless stopped beforehand.
    func shutdown() {
        shuttingDown = true
        agentBridge?.stop()
        periodic?.cancel()
        events?.stop()
        process?.onExit = nil
        process?.terminate()
        process = nil
        client = nil
    }

    func stopAllRunning(timeout: TimeInterval = 150) async {
        let running = instances.filter { $0.state == "ready" || $0.state == "starting" || $0.state == "unknown" }
        await withTaskGroup(of: Void.self) { group in
            for item in running {
                group.addTask { @MainActor in
                    _ = try? await self.perform(item.id, "stop", timeout: timeout)
                }
            }
        }
    }

    private func startPeriodicRefresh() {
        periodic?.cancel()
        let gen = generation
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, gen == self.generation else { return }
                await self.reloadInstances()
            }
        }
    }

    private func requireClient() throws -> APIClient {
        guard let client else { throw APIError.disconnected }
        return client
    }

    // MARK: Loading

    func reloadAll() async {
        async let a: Void = reloadComponents()
        async let b: Void = reloadInstances()
        async let c: Void = reloadArtifacts()
        async let d: Void = reloadEngines()
        _ = await (a, b, c, d)
        // Reconcile operations we were tracking (events may have been missed during a reset).
        for id in operationOrder where operations[id]?.isTerminal == false {
            if let op = try? await client?.operation(id) { record(op) }
        }
    }

    func reloadComponents() async {
        guard let client else { return }
        do { components = try await client.components() } catch { reportLoad(error) }
    }

    func reloadEngines() async {
        guard let client else { return }
        if let value = try? await client.engines() { engines = value }
    }

    func reloadInstances() async {
        guard let client else { return }
        do { instances = try await client.instances().sorted(by: Self.instanceOrder) } catch { reportLoad(error) }
    }

    func reloadArtifacts() async {
        guard let client else { return }
        do { artifacts = try await client.artifacts() } catch { reportLoad(error) }
    }

    func refreshInstance(_ id: UUID) async {
        guard let client else { return }
        do {
            let value = try await client.instance(id)
            if let index = instances.firstIndex(where: { $0.id == id }) { instances[index] = value }
            else { instances.append(value); instances.sort(by: Self.instanceOrder) }
        } catch let error as APIError where error.code == "INSTANCE_NOT_FOUND" {
            instances.removeAll { $0.id == id }
        } catch {}
    }

    private static func instanceOrder(_ a: Instance, _ b: Instance) -> Bool {
        if a.purpose != b.purpose { return a.purpose == "device" }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private func scheduleInstanceRefresh(_ id: UUID) {
        instanceRefreshes[id]?.cancel()
        instanceRefreshes[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshInstance(id)
        }
    }

    private func reportLoad(_ error: Error) {
        if let api = error as? APIError, api.isConnectionLoss { return }  // connection banner covers it
        notify("同步失败", error)
    }

    // MARK: Events

    @ObservationIgnored private(set) var eventCount = 0

    private func handle(_ event: SSEEvent) {
        eventCount += 1
        switch event.event {
        case "reset":
            Task { await reloadAll() }
        case "operation":
            guard let op = try? JSONDecoder().decode(BackendOperation.self, from: Data(event.data.utf8)) else { return }
            record(op)
        case "instance":
            guard let partial = try? JSONDecoder().decode(Instance.self, from: Data(event.data.utf8)) else { return }
            if let index = instances.firstIndex(where: { $0.id == partial.id }) {
                instances[index].state = partial.state
                instances[index].name = partial.name
                instances[index].guestUid = partial.guestUid
                instances[index].selinux = partial.selinux
            }
            // The event carries no capabilities; fetch the full view.
            scheduleInstanceRefresh(partial.id)
        default:
            break
        }
    }

    private func record(_ op: BackendOperation) {
        let previous = operations[op.id]
        // Ignore stale updates that would move a finished operation backwards.
        if let previous, previous.isTerminal, !op.isTerminal { return }
        operations[op.id] = op
        if previous == nil { operationOrder.insert(op.id, at: 0); trimOperations() }
        if op.isTerminal && previous?.isTerminal != true {
            if op.action == "install-component" { Task { await reloadComponents(); await reloadEngines() } }
            if let id = op.instanceId { scheduleInstanceRefresh(id) }
        }
    }

    private func trimOperations() {
        guard operationOrder.count > 200 else { return }
        for id in operationOrder.suffix(from: 200) where operations[id]?.isTerminal != false { operations[id] = nil }
        operationOrder = operationOrder.filter { operations[$0] != nil }
    }

    // MARK: Operations

    /// Submits a long-running request (HTTP 202) with an Idempotency-Key. Transport failures are
    /// retried with the same key, so the backend never runs the request twice.
    func submit(_ send: @escaping (APIClient, String) async throws -> OperationAccepted) async throws -> OperationAccepted {
        let key = UUID().uuidString
        var attempt = 0
        while true {
            do {
                let accepted = try await send(try requireClient(), key)
                if operations[accepted.operationId] == nil, let op = try? await client?.operation(accepted.operationId) {
                    record(op)
                }
                if let id = accepted.instanceId, instance(id) == nil { await refreshInstance(id) }
                return accepted
            } catch let error as APIError where error.isConnectionLoss && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Waits until the operation finishes. SSE updates arrive through `record`; the operation is
    /// also polled so progress continues while the event stream reconnects.
    func wait(_ id: UUID, timeout: TimeInterval = 7200) async throws -> BackendOperation {
        let deadline = Date().addingTimeInterval(timeout)
        var lastPoll = Date.distantPast
        while Date() < deadline {
            try Task.checkCancellation()
            if let op = operations[id], op.isTerminal {
                if op.state == "failed" { throw OperationFailure(operation: op) }
                return op
            }
            let interval: TimeInterval = eventsConnected ? 4 : 1.5
            if Date().timeIntervalSince(lastPoll) > interval, let client {
                lastPoll = Date()
                if let op = try? await client.operation(id) { record(op) }
                continue
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw APIError.transport("操作超时，请查看设备状态后再决定是否重试。")
    }

    @discardableResult
    func perform(_ instance: UUID, _ action: String, body: [String: Any] = [:], timeout: TimeInterval = 900) async throws -> BackendOperation {
        let accepted = try await submit { client, key in try await client.action(instance, action, body: body, key: key) }
        let op = try await wait(accepted.operationId, timeout: timeout)
        scheduleInstanceRefresh(instance)
        return op
    }

    /// Runs an instance action and reports failures as a notice. Returns the result on success.
    @discardableResult
    func run(_ instance: UUID, _ action: String, body: [String: Any] = [:]) async -> BackendOperation? {
        do { return try await perform(instance, action, body: body) }
        catch is CancellationError { return nil }
        catch { notify("\(Labels.action(action))失败", error); return nil }
    }

    func latestOperation(forComponent id: String) -> BackendOperation? {
        operationOrder.lazy.compactMap { self.operations[$0] }
            .first { $0.action == "install-component" && ($0.result?["componentId"] == id || self.componentOps[$0.id] == id) }
    }
    var componentOps: [UUID: String] = [:]

    func installComponent(_ component: Component, accepting licenses: [LicenseText]) async {
        let consent = Dictionary(uniqueKeysWithValues: licenses.map { ($0.id, $0.sha256) })
        do {
            let accepted = try await submit { client, key in
                try await client.installComponent(component.id, acceptLicenses: consent, key: key)
            }
            componentOps[accepted.operationId] = component.id
            _ = try await wait(accepted.operationId)
        } catch is CancellationError {
        } catch {
            notify("\(Labels.component(component.id)) 安装失败", error)
        }
        await reloadComponents()
    }

    func createInstance(engineId: String, profileId: String, name: String, externalName: String?) async -> UUID? {
        do {
            let accepted = try await submit { client, key in
                try await client.createInstance(engineId: engineId, profileId: profileId, name: name,
                                                externalName: externalName, key: key)
            }
            await reloadInstances()
            let op = try await wait(accepted.operationId)
            await reloadInstances()
            return op.result?["instanceId"].flatMap(UUID.init(uuidString:)) ?? accepted.instanceId
        } catch is CancellationError {
            return nil
        } catch {
            notify("创建设备失败", error)
            await reloadInstances()
            return nil
        }
    }

    // MARK: Applications

    func importFiles(_ urls: [URL]) async -> [Artifact] {
        var imported: [Artifact] = []
        for url in urls {
            do {
                let artifact = try await requireClient().importArtifact(path: url.standardizedFileURL.path)
                imported.append(artifact)
            } catch {
                notify("无法导入 \(url.lastPathComponent)", error)
            }
        }
        await reloadArtifacts()
        return imported
    }

    /// Host blocker for an artifact, checked before submitting a launch.
    func launchBlocker(for artifact: Artifact) -> UserNotice? {
        let componentId: String
        switch artifact.kind {
        case "ipa": componentId = "ios-vphone"
        case "simulatorApp": componentId = "ios-simulator-runtime"
        default: componentId = "android-engine"
        }
        if artifact.kind == "apk", component("android-engine")?.isReady == true,
           component("android-runtime")?.isReady != true, component("android-google-apis")?.isReady != true {
            return UserNotice(title: "需要先安装 Android 运行环境",
                              message: "请在「组件」页安装 AOSP 或 Google APIs 运行环境。", code: nil, link: nil)
        }
        guard let component = component(componentId), !component.isReady else { return nil }
        let link = component.source.flatMap(URL.init(string:))
        switch component.status {
        case "externalSetup", "blocked":
            let hint = Labels.reason(component.reasonCode) ?? "\(Labels.component(componentId)) 尚未就绪。"
            return UserNotice(title: "无法在本机打开 \(artifact.name)", message: hint, code: component.reasonCode, link: link)
        default:
            return UserNotice(title: "需要先安装组件", message: "请在「组件」页安装 \(Labels.component(componentId))。", code: nil, link: nil)
        }
    }

    /// Default profile for single-app mode. APKs use AOSP when its runtime is installed and fall
    /// back to the Google APIs runtime, so a ready runtime is used without extra downloads.
    func preferredProfile(for artifact: Artifact) -> String? {
        guard artifact.kind == "apk" else { return nil }
        if component("android-runtime")?.isReady == true { return "android-aosp" }
        if component("android-google-apis")?.isReady == true { return "android-google-apis" }
        return nil
    }

    /// Opens an application: reuses the app workspace instance and existing install, then shows
    /// the application window.
    func open(_ artifact: Artifact, instanceId: UUID? = nil, profileId requestedProfile: String? = nil) async {
        let profileId = instanceId == nil ? (requestedProfile ?? preferredProfile(for: artifact)) : nil
        if instanceId == nil, let blocker = launchBlocker(for: artifact) {
            post(blocker)
            return
        }
        guard !launching.contains(artifact.id) else { return }
        launching.insert(artifact.id)
        defer { launching.remove(artifact.id) }
        do {
            let accepted = try await submit { client, key in
                try await client.launch(artifact.id, instanceId: instanceId, profileId: profileId, key: key)
            }
            let op = try await wait(accepted.operationId)
            let target = op.result?["instanceId"].flatMap(UUID.init(uuidString:)) ?? accepted.instanceId
            await reloadInstances()
            if let target {
                openWindowAction?(value: ScreenTarget(instanceId: target, artifactId: artifact.id))
            }
        } catch is CancellationError {
        } catch {
            if let failure = error as? OperationFailure, let hint = Labels.reason(failure.body.code),
               ["RESEARCH_GUESTS_DISABLED", "VPHONE_LAUNCHPAD_MISSING", "VPHONE_PREFLIGHT_REQUIRED", "VPHONE_FIRMWARE_REQUIRED"].contains(failure.body.code) {
                post(UserNotice(title: "无法在本机打开 \(artifact.name)", message: hint, code: failure.body.code,
                                          link: component("ios-vphone")?.source.flatMap(URL.init(string:))))
            } else {
                notify("无法打开 \(artifact.name)", error)
            }
            await reloadInstances()
        }
    }

    func importAndOpen(_ urls: [URL]) async {
        let imported = await importFiles(urls)
        for artifact in imported { await open(artifact) }
    }

    // MARK: Notices

    func notify(_ title: String, _ error: Error) {
        let code: String?
        switch error {
        case let api as APIError: code = api.code
        case let op as OperationFailure: code = op.body.code
        default: code = nil
        }
        post(UserNotice(title: title, message: error.localizedDescription, code: code))
    }

    /// Shows a notice. Informational notices disappear after a while; host blockers (with a link)
    /// stay until dismissed.
    func post(_ notice: UserNotice) {
        notices.append(notice)
        if notices.count > 6 { notices.removeFirst(notices.count - 6) }
        guard notice.link == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.dismiss(notice)
        }
    }

    func dismiss(_ notice: UserNotice) { notices.removeAll { $0.id == notice.id } }
}
