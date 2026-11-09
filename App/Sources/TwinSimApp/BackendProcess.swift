import Darwin
import Foundation
import TwinSimAgentProtocol

/// Optional host paths passed to the helper. Empty values are not exported.
struct BackendSettings: Equatable, Sendable {
    var androidHome: String
    var developerDir: String
    /// Default Android emulator CPU cores / RAM for devices without their own values (0 = automatic).
    var androidCpus: Int = 0
    var androidRamMB: Int = 0

    static let androidHomeKey = "androidHome"
    static let developerDirKey = "developerDir"
    static let androidCpusKey = "androidCpus"
    static let androidRamKey = "androidRamMB"

    static let hostCpus = max(1, ProcessInfo.processInfo.activeProcessorCount)
    static let hostRamMB = Int(ProcessInfo.processInfo.physicalMemory >> 20)
    static var maxAndroidRamMB: Int { max(2048, hostRamMB - 4096) }
    static var autoCpus: Int { min(6, max(2, hostCpus / 2)) }
    static var autoRamMB: Int { hostRamMB >= 32 << 10 ? 4096 : 3072 }

    static func load(_ defaults: UserDefaults = .standard) -> BackendSettings {
        BackendSettings(androidHome: defaults.string(forKey: androidHomeKey) ?? "",
                        developerDir: defaults.string(forKey: developerDirKey) ?? "",
                        androidCpus: defaults.integer(forKey: androidCpusKey),
                        androidRamMB: defaults.integer(forKey: androidRamKey))
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(androidHome, forKey: Self.androidHomeKey)
        defaults.set(developerDir, forKey: Self.developerDirKey)
        defaults.set(androidCpus, forKey: Self.androidCpusKey)
        defaults.set(androidRamMB, forKey: Self.androidRamKey)
    }

    /// Data directory chosen in Settings; nil means the default location. `TWINSIM_HOME` in the
    /// app's own environment (tests) takes precedence.
    static var dataDirectory: String? {
        get { UserDefaults.standard.string(forKey: AgentProtocol.dataDirectoryKey).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let newValue, newValue != AgentProtocol.defaultDataDirectory {
                UserDefaults.standard.set(newValue, forKey: AgentProtocol.dataDirectoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AgentProtocol.dataDirectoryKey)
            }
        }
    }
}

struct BackendLaunchError: LocalizedError, Sendable {
    let message: String
    let diagnostics: String
    var errorDescription: String? { message }
}

/// Owns one `twinsimd` child process: starts it as the current user, reads the single-line
/// JSON handshake from stdout, keeps a bounded stderr tail and reports unexpected exits.
/// The session token only lives in memory.
final class BackendProcess: @unchecked Sendable {
    let executable: URL
    private let environment: [String: String]
    private let process = Process()
    private let lock = NSLock()
    private var stderrTail = Data()
    private var stdoutBuffer = Data()
    private var handshakeContinuation: CheckedContinuation<Handshake, Error>?
    private var handshakeDone = false
    private var intentionalStop = false
    var onExit: (@Sendable (Int32, Bool) -> Void)?

    init(executable: URL, settings: BackendSettings, inherited: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        var env = inherited
        // Never pass a token or origin through from the parent: the helper generates its own token.
        env["TWINSIM_TOKEN"] = nil
        env["TWINSIM_ORIGIN"] = nil
        env["TWINSIM_PORT"] = nil
        env["TWINSIM_DAEMON"] = nil
        if !settings.androidHome.isEmpty {
            env["ANDROID_HOME"] = settings.androidHome
            env["ANDROID_SDK_ROOT"] = settings.androidHome
        }
        if !settings.developerDir.isEmpty { env["DEVELOPER_DIR"] = settings.developerDir }
        if settings.androidCpus > 0 { env["TWINSIM_ANDROID_CPUS"] = String(settings.androidCpus) }
        if settings.androidRamMB > 0 { env["TWINSIM_ANDROID_RAM_MB"] = String(settings.androidRamMB) }
        env["TWINSIM_HOME"] = AgentProtocol.dataDirectory(environment: inherited)
        self.environment = env
    }

    static func locateHelper() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["TWINSIM_DAEMON"], FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/twinsimd")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        // Development: binary inside .build of the frontend package, payload at the repository root.
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent(".build/backend-payload/Contents/Helpers/twinsimd")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
    }

    /// Starts the helper and waits for the handshake line.
    func start(timeout: TimeInterval = 45) async throws -> Handshake {
        let out = Pipe(), err = Pipe()
        process.executableURL = executable
        process.arguments = []
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { handle.readabilityHandler = nil; return }
            self.lock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 64 << 10 { self.stderrTail.removeFirst(self.stderrTail.count - (64 << 10)) }
            self.lock.unlock()
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.consumeStdout(data)
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            let intentional = self.intentionalStop
            self.lock.unlock()
            // Give stderr a moment to drain so diagnostics include the exit reason.
            usleep(100_000)
            self.failHandshake(BackendLaunchError(message: "后端进程在握手前退出 (状态 \(proc.terminationStatus))。",
                                                   diagnostics: self.diagnostics))
            self.onExit?(proc.terminationStatus, intentional)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Handshake, Error>) in
                lock.lock()
                handshakeContinuation = continuation
                lock.unlock()
                do {
                    try process.run()
                    HelperRegistry.record(pid: process.processIdentifier, executable: executable)
                } catch {
                    failHandshake(BackendLaunchError(message: "无法启动后端：\(error.localizedDescription)", diagnostics: ""))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self else { return }
                    self.failHandshake(BackendLaunchError(message: "后端在 \(Int(timeout)) 秒内没有返回握手信息。",
                                                          diagnostics: self.diagnostics))
                }
            }
        } onCancel: {
            self.terminate()
        }
    }

    private func consumeStdout(_ data: Data) {
        lock.lock()
        guard !handshakeDone else { lock.unlock(); return }
        stdoutBuffer.append(data)
        var found: Handshake?
        while let newline = stdoutBuffer.firstIndex(of: 10) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            if line.first == UInt8(ascii: "{"), let value = try? JSONDecoder().decode(Handshake.self, from: Data(line)) {
                found = value
                break
            }
        }
        if stdoutBuffer.count > 1 << 20 { stdoutBuffer.removeAll() }
        lock.unlock()
        if let found { succeedHandshake(found) }
    }

    private func succeedHandshake(_ value: Handshake) {
        lock.lock()
        guard !handshakeDone, let continuation = handshakeContinuation else { lock.unlock(); return }
        handshakeDone = true
        handshakeContinuation = nil
        stdoutBuffer.removeAll()
        lock.unlock()
        continuation.resume(returning: value)
    }

    private func failHandshake(_ error: Error) {
        lock.lock()
        guard !handshakeDone, let continuation = handshakeContinuation else { lock.unlock(); return }
        handshakeDone = true
        handshakeContinuation = nil
        lock.unlock()
        if process.isRunning { terminate() }
        continuation.resume(throwing: error)
    }

    /// Sends SIGTERM, then SIGKILL after a grace period.
    var helperDirectory: URL { executable.deletingLastPathComponent() }

    func terminate(grace: TimeInterval = 6) {
        lock.lock()
        intentionalStop = true
        lock.unlock()
        guard process.isRunning else { HelperRegistry.clear(); return }
        let pid = process.processIdentifier
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        HelperRegistry.clear()
    }
}

/// Records the running helper's PID so that a helper orphaned by a frontend crash can be
/// stopped on the next launch (it would otherwise hold the data-directory lock).
enum HelperRegistry {
    private static var file: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.twinsim.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let home = AgentProtocol.dataDirectory()
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in home.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return base.appendingPathComponent("helper-\(String(hash, radix: 16)).pid")
    }

    static func record(pid: Int32, executable: URL) {
        try? "\(pid)\n\(executable.resolvingSymlinksInPath().path)\n".write(to: file, atomically: true, encoding: .utf8)
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    /// Stops a helper left behind by a previous frontend process, if it is still our binary.
    static func reapOrphan() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let pid = Int32(lines[0]), pid > 1, kill(pid, 0) == 0 else { clear(); return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { clear(); return }
        let running = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        guard running == lines[1] else { clear(); return }
        kill(pid, SIGTERM)
        for _ in 0..<100 where kill(pid, 0) == 0 { usleep(50_000) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        clear()
    }
}
