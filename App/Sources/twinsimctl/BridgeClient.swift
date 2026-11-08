import Darwin
import Foundation
import TwinSimAgentProtocol

struct AgentError: Error, CustomStringConvertible {
    let code: String
    let message: String
    var hint: String?
    init(_ code: String, _ message: String, hint: String? = nil) { self.code = code; self.message = message; self.hint = hint }
    var description: String { "\(code): \(message)" + (hint.map { "\nHint: \($0)" } ?? "") }
}

struct HTTPResult {
    let status: Int
    let contentType: String
    let json: Any?
    let data: Data?
    var ok: Bool { (200..<300).contains(status) }
    var object: [String: Any] { json as? [String: Any] ?? [:] }
    var array: [[String: Any]] { json as? [[String: Any]] ?? [] }

    func check() throws -> HTTPResult {
        guard ok else {
            let body = object
            let code = body["code"] as? String ?? "HTTP_\(status)"
            throw AgentError(code, body["message"] as? String ?? "Request failed.", hint: Hints.for(code))
        }
        return self
    }
}

/// Client for the TwinSim.app agent bridge. Starts the app (hidden) when it is not running.
final class BridgeClient {
    let path = AgentProtocol.socketPath()
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 1
    private var ready = false
    var log: (String) -> Void = { FileHandle.standardError.write(Data(("twinsim: " + $0 + "\n").utf8)) }

    deinit { if fd >= 0 { close(fd) } }

    // MARK: Connection

    private func connectOnce() -> Bool {
        guard var address = AgentProtocol.makeAddress(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(s); return false }
        fd = s
        buffer.removeAll()
        return true
    }

    /// Connects, launching TwinSim.app if needed, and waits until the backend is connected.
    func ensureReady(timeout: TimeInterval = 120) throws {
        if ready && fd >= 0 { return }
        if fd < 0 && !connectOnce() {
            guard ProcessInfo.processInfo.environment["TWINSIM_NO_LAUNCH"] == nil else {
                throw AgentError("APP_NOT_RUNNING", "TwinSim is not running (\(path)).", hint: "Open TwinSim.app first.")
            }
            // LaunchServices can fail transiently (e.g. right after the bundle was replaced), so the
            // launch is re-issued until the socket appears.
            let deadline = Date().addingTimeInterval(60)
            var nextLaunch = Date.distantPast
            var lastLaunchError = ""
            while !connectOnce() {
                guard Date() < deadline else {
                    throw AgentError("APP_NOT_RUNNING", "TwinSim did not open its agent connection at \(path). \(lastLaunchError)",
                                     hint: "Open TwinSim.app and check Settings > AI 集成: the agent connection must be enabled.")
                }
                if Date() >= nextLaunch {
                    lastLaunchError = (try? launchApp()) ?? lastLaunchError
                    nextLaunch = Date().addingTimeInterval(12)
                }
                usleep(300_000)
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let hello = try request(["type": "hello"])
            let backend = hello["backend"] as? String ?? ""
            if backend == "connected" { ready = true; return }
            if backend.hasPrefix("failed") {
                throw AgentError("BACKEND_FAILED", backend, hint: "Open TwinSim and restart the backend (后端 > 重新启动后端).")
            }
            guard Date() < deadline else { throw AgentError("BACKEND_UNAVAILABLE", "The TwinSim backend is still \(backend).") }
            usleep(500_000)
        }
    }

    private func appBundle() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["TWINSIM_APP"] { return explicit }
        // .../TwinSim.app/Contents/Helpers/twinsim
        let me = executableURL()
        let bundle = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle.path }
        let installed = "/Applications/TwinSim.app"
        return FileManager.default.fileExists(atPath: installed) ? installed : nil
    }

    /// Asks LaunchServices to start the app hidden. Returns an error description, or "" on success.
    private func launchApp() throws -> String {
        guard let app = appBundle() else {
            throw AgentError("APP_NOT_FOUND", "TwinSim.app was not found.", hint: "Set TWINSIM_APP to the TwinSim.app path.")
        }
        log("starting \(app)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-g", "-j", app]
        // LaunchServices keeps the app in the user's GUI session, which the iOS Simulator needs.
        if let home = ProcessInfo.processInfo.environment["TWINSIM_HOME"] { args += ["--env", "TWINSIM_HOME=\(home)"] }
        process.arguments = args
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            log("open failed (\(process.terminationStatus)): \(message)")
            return "open: \(message)"
        }
        return ""
    }

    // MARK: Requests

    func request(_ object: [String: Any], retry: Bool = true) throws -> [String: Any] {
        if fd < 0 && !connectOnce() { throw AgentError("APP_NOT_RUNNING", "Lost the connection to TwinSim.") }
        var message = object
        let id = nextID
        nextID += 1
        message["id"] = id
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        let sent = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
        guard sent, let line = readLine() else {
            close(fd); fd = -1; ready = false
            if retry { return try request(object, retry: false) }
            throw AgentError("APP_NOT_RUNNING", "The connection to TwinSim closed.")
        }
        guard let response = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw AgentError("INVALID_RESPONSE", "TwinSim returned an invalid response.")
        }
        if response["ok"] as? Bool != true {
            let error = response["error"] as? [String: Any] ?? [:]
            let code = error["code"] as? String ?? "BRIDGE_ERROR"
            throw AgentError(code, error["message"] as? String ?? "Request failed.", hint: Hints.for(code))
        }
        return response
    }

    private func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 256 << 10)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    func http(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil,
              idempotencyKey: String? = nil) throws -> HTTPResult {
        try ensureReady()
        var object: [String: Any] = ["type": "http", "method": method, "path": "/v1" + path, "query": query]
        if let body { object["body"] = body }
        if let idempotencyKey { object["idempotencyKey"] = idempotencyKey }
        var attempt = 0
        while true {
            do {
                let response = try request(object)
                let data = (response["base64"] as? String).flatMap { Data(base64Encoded: $0) }
                return HTTPResult(status: response["status"] as? Int ?? 0, contentType: response["contentType"] as? String ?? "",
                                  json: response["json"], data: data)
            } catch let error as AgentError where error.code == "BACKEND_UNAVAILABLE" && attempt < 60 {
                // Backend restarting: wait for it (same Idempotency-Key, so a resend is safe).
                attempt += 1
                ready = false
                usleep(1_000_000)
                try ensureReady()
            }
        }
    }

    func get(_ path: String, query: [String: String] = [:]) throws -> HTTPResult { try http("GET", path, query: query).check() }

    func showWindow(instanceId: String, artifactId: String? = nil) throws {
        try ensureReady()
        var object: [String: Any] = ["type": "showWindow", "instanceId": instanceId]
        if let artifactId { object["artifactId"] = artifactId }
        _ = try request(object)
    }
}

enum Hints {
    static func `for`(_ code: String) -> String? {
        switch code {
        case "RESEARCH_GUESTS_DISABLED", "VPHONE_LAUNCHPAD_MISSING", "VPHONE_PREFLIGHT_REQUIRED", "VPHONE_FIRMWARE_REQUIRED":
            return "Device IPAs need the iOS research VM (vphone), which this Mac has not set up. Tell the user; the host must be configured manually."
        case "INSTANCE_NOT_READY": return "Start the device first (start_device), or use open_app which starts it."
        case "RESOURCE_BUSY": return "Another operation is running on this device; retry in a few seconds."
        case "COMPONENT_REQUIRED", "ANDROID_ENGINE_MISSING": return "Call list_components and install the missing component."
        case "LICENSE_CONSENT_REQUIRED": return "Show the license text to the user and only accept with their explicit consent."
        case "CAPABILITY_UNSUPPORTED": return "This device's engine does not support that action; check the device capabilities."
        case "OUTPUT_LIMIT", "TOOL_TIMEOUT": return "The guest produced too much output or was slow; retry, or narrow the request."
        case "APP_HAS_NO_LAUNCHER": return "The APK has no launcher activity; use shell with `am start -n` instead."
        case "ROSETTA_MISSING": return "Windows programs need Rosetta 2. Ask the user to run `softwareupdate --install-rosetta`."
        case "WINE_MISSING": return "Install the windows-wine component (install_component componentId=windows-wine)."
        case "NO_WINDOW": return "The Windows program has no window on screen yet; wait a few seconds or open it with open_app / windows_tool."
        case "SCREEN_RECORDING_REQUIRED": return "Ask the user to allow TwinSim in System Settings > Privacy & Security > Screen & System Audio Recording."
        case "ACCESSIBILITY_REQUIRED": return "Ask the user to allow TwinSim in System Settings > Privacy & Security > Accessibility so it can send clicks and keys."
        case "APP_ARCH_UNSUPPORTED": return "Use the x86/x64 build of the Windows program; ARM64 Windows builds cannot run in Wine on macOS."
        default: return nil
        }
    }
}
