import CryptoKit
import Darwin
import Foundation

struct BackendError: Error, Codable, LocalizedError {
    let code: String
    let message: String
    let retryable: Bool

    init(_ code: String, _ message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    var errorDescription: String? { message }

    static func wrap(_ error: Error) -> Self {
        (error as? Self) ?? Self("BACKEND_ERROR", error.localizedDescription)
    }
}

struct Handshake: Encodable {
    let url: String
    let token: String
}

struct Configuration: Sendable {
    let rootLock: RootLock
    let root: URL
    let port: Int
    let adbPort: Int
    let token: String
    let origin: String?
    let jidrOverride: String?
    let developerDir: String?
    let vphoneLaunchpad: String?
    let vphoneMachines: URL
    let environment: [String: String]

    init(_ env: [String: String]) throws {
        environment = env
        let home = FileManager.default.homeDirectoryForCurrentUser
        root = URL(fileURLWithPath: env["TWINSIM_HOME"] ?? home.appendingPathComponent("Library/Application Support/TwinSim").path)
        try Files.directory(root)
        rootLock = try RootLock(root)
        port = try Self.port(env["TWINSIM_PORT"], allowZero: true) ?? 0
        let portFile = root.appendingPathComponent("adb-port")
        if let requested = try Self.port(env["TWINSIM_ADB_PORT"], allowZero: false) {
            adbPort = requested
        } else if let saved = try? String(contentsOf: portFile, encoding: .utf8),
                  let value = try? Self.port(saved, allowZero: false) {
            adbPort = value
        } else {
            adbPort = try Self.availablePort()
            try Data(String(adbPort).utf8).write(to: portFile, options: .atomic)
        }
        token = env["TWINSIM_TOKEN"] ?? (UUID().uuidString + UUID().uuidString)
        guard token.utf8.count >= 32, token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw BackendError("INVALID_CONFIGURATION", "TWINSIM_TOKEN must have at least 32 printable ASCII characters.")
        }
        origin = env["TWINSIM_ORIGIN"]
        jidrOverride = env["TWINSIM_JIDR"]
        developerDir = env["DEVELOPER_DIR"] ?? Self.selectedXcode()
        vphoneLaunchpad = env["TWINSIM_VPHONE_LAUNCHPAD"] ?? [
            "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli",
            home.appendingPathComponent("Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad-cli").path,
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
        vphoneMachines = URL(fileURLWithPath: env["TWINSIM_VPHONE_MACHINES"] ?? home.appendingPathComponent(".vphone/machines").path)
    }

    private static func selectedXcode() -> String? {
        let conventional = "/Applications/Xcode.app/Contents/Developer"
        if FileManager.default.isExecutableFile(atPath: conventional + "/usr/bin/simctl") { return conventional }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let directory = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: directory + "/usr/bin/simctl") ? directory : nil
    }

    private static func port(_ input: String?, allowZero: Bool) throws -> Int? {
        guard let input else { return nil }
        guard let value = Int(input), (allowZero ? 0...65535 : 1024...65535).contains(value) else {
            throw BackendError("INVALID_CONFIGURATION", "Invalid TCP port.")
        }
        return value
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendError("PORT_ALLOCATION_FAILED", "Could not open a loopback socket.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 ? getsockname(fd, pointer, &length) : -1
            }
        }
        guard result == 0 else { throw BackendError("PORT_ALLOCATION_FAILED", "Could not reserve a loopback port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

enum Files {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    static func scratch(in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try directory(url)
        return url
    }

    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func size(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

struct Command: Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]?
    let timeout: TimeInterval

    init(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 60) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }

    struct Output: Sendable {
        let code: Int32
        let data: Data
        let stderr: String
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    func run(in parent: URL, input: Data? = nil, limit: Int = 32 << 20, check: Bool = true,
             heartbeat: (@Sendable () async -> Void)? = nil) async throws -> Output {
        let scratch = try Files.scratch(in: parent)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stdout = scratch.appendingPathComponent("stdout")
        let stderr = scratch.appendingPathComponent("stderr")
        let stdin = scratch.appendingPathComponent("stdin")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        try (input ?? Data()).write(to: stdin)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        let read = try FileHandle(forReadingFrom: stdin)
        defer { try? out.close(); try? err.close(); try? read.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = read
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var nextHeartbeat = ContinuousClock.now
        do {
            while process.isRunning {
                guard ContinuousClock.now < deadline else {
                    throw BackendError("TOOL_TIMEOUT", "\(URL(fileURLWithPath: executable).lastPathComponent) exceeded its time limit.", retryable: true)
                }
                guard Files.size(stdout) <= Int64(limit) else {
                    throw BackendError("OUTPUT_LIMIT", "Tool output exceeded the allowed size.")
                }
                if let heartbeat, ContinuousClock.now >= nextHeartbeat {
                    await heartbeat()
                    nextHeartbeat = ContinuousClock.now.advanced(by: .seconds(1))
                }
                try await Task.sleep(for: .milliseconds(75))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                for _ in 0..<10 where process.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            throw error
        }
        guard Files.size(stdout) <= Int64(limit) else { throw BackendError("OUTPUT_LIMIT", "Tool output exceeded the allowed size.") }
        let errorFile = try FileHandle(forReadingFrom: stderr)
        defer { try? errorFile.close() }
        let output = try Output(code: process.terminationStatus, data: Data(contentsOf: stdout),
                                stderr: String(decoding: errorFile.read(upToCount: 8192) ?? Data(), as: UTF8.self))
        if check && output.code != 0 {
            let message = output.stderr.isEmpty ? output.text : output.stderr
            throw BackendError("TOOL_FAILED", String(message.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}

final class RootLock: Sendable {
    let descriptor: Int32

    init(_ root: URL) throws {
        let descriptor = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BackendError("STATE_LOCK", "Could not open the backend data lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BackendError("STATE_LOCK", "A backend is already using this data directory.")
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }
}

extension JSONSerialization {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try jsonObject(with: data) as? [String: Any] else {
            throw BackendError("INVALID_TOOL_RESPONSE", "Expected a JSON object from the runtime.")
        }
        return object
    }

    static func string(_ object: [String: Any]) throws -> String {
        String(decoding: try data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
