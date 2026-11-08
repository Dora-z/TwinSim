import Darwin
import Foundation
import TwinSimAgentProtocol

/// Serves the local agent bridge (see `AgentProtocol`) so AI tools can drive TwinSim through the
/// running app. Only processes of the same user can connect; the backend token stays in this
/// process and is added when requests are forwarded.
final class AgentBridge: @unchecked Sendable {
    static let enabledKey = "agentBridgeEnabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private(set) var path = AgentProtocol.socketPath()
    private weak var store: AppStore?
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.twinsim.agent-bridge")
    private(set) var isListening = false
    private(set) var lastError: String?
    private var clients = 0
    private let lock = NSLock()

    init(store: AppStore) { self.store = store }

    var connectedClients: Int { lock.lock(); defer { lock.unlock() }; return clients }

    func start() {
        guard !isListening else { return }
        path = AgentProtocol.socketPath()
        do { try listen() } catch {
            lastError = error.localizedDescription
            FileHandle.standardError.write(Data("agent bridge: \(error.localizedDescription)\n".utf8))
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { close(listener); listener = -1 }
        if isListening { unlink(path) }
        isListening = false
    }

    private func listen() throws {
        guard var address = AgentProtocol.makeAddress(path) else { throw BridgeError("socket path too long: \(path)") }
        // A live socket means another TwinSim already serves this data directory.
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            let alive = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
            }
            close(probe)
            if alive { throw BridgeError("another TwinSim is already serving \(path)") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError("socket() failed: \(errno)") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0 else { close(fd); throw BridgeError("bind() failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { close(fd); unlink(path); throw BridgeError("listen() failed: \(errno)") }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
        isListening = true
        lastError = nil
    }

    private func acceptClient() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        lock.lock(); clients += 1; lock.unlock()
        let connection = Connection(fd: fd)
        Thread.detachNewThread { [weak self] in
            self?.serve(connection)
            self?.lock.lock(); self?.clients -= 1; self?.lock.unlock()
        }
    }

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        private let writeLock = NSLock()
        private var closed = false
        init(fd: Int32) { self.fd = fd }

        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return }
            data.append(10)
            writeLock.lock(); defer { writeLock.unlock() }
            guard !closed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    offset += n
                }
            }
        }

        func close() {
            writeLock.lock(); closed = true; writeLock.unlock()
            Darwin.close(fd)
        }
    }

    private func serve(_ connection: Connection) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        defer { connection.close() }
        while true {
            let n = read(connection.fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                guard let request = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                    connection.send(["ok": false, "error": ["code": "INVALID_REQUEST", "message": "Expected one JSON object per line."]])
                    continue
                }
                let id = request["id"] ?? NSNull()
                Task { @MainActor [weak self] in
                    var response = await self?.handle(request) ?? Self.failure("BRIDGE_CLOSED", "TwinSim is shutting down.")
                    response["id"] = id
                    connection.send(response)
                }
            }
            if buffer.count > 16 << 20 { return }
        }
    }

    private static func failure(_ code: String, _ message: String, status: Int? = nil) -> [String: Any] {
        var value: [String: Any] = ["ok": false, "error": ["code": code, "message": message]]
        if let status { value["status"] = status }
        return value
    }

    @MainActor
    private func handle(_ request: [String: Any]) async -> [String: Any] {
        guard let store else { return Self.failure("BRIDGE_CLOSED", "TwinSim is shutting down.") }
        switch request["type"] as? String {
        case "hello":
            let backend: String
            switch store.connection {
            case .connected: backend = "connected"
            case .failed(let message, _): backend = "failed: " + message
            case .restarting: backend = "restarting"
            default: backend = "starting"
            }
            return ["ok": true, "protocol": AgentProtocol.version, "backend": backend,
                    "app": Bundle.main.bundlePath, "dataDirectory": store.dataDirectory,
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"]
        case "showWindow":
            guard let id = (request["instanceId"] as? String).flatMap(UUID.init(uuidString:)) else {
                return Self.failure("INVALID_REQUEST", "instanceId is required.")
            }
            let artifact = (request["artifactId"] as? String).flatMap(UUID.init(uuidString:))
            await store.refreshInstance(id)
            store.openWindowAction?(value: ScreenTarget(instanceId: id, artifactId: artifact))
            return ["ok": true, "opened": store.openWindowAction != nil]
        case "http":
            return await forward(request, store: store)
        default:
            return Self.failure("INVALID_REQUEST", "Unknown request type.")
        }
    }

    @MainActor
    private func forward(_ request: [String: Any], store: AppStore) async -> [String: Any] {
        guard let client = store.client else {
            return Self.failure("BACKEND_UNAVAILABLE", "The TwinSim backend is not connected yet.", status: 503)
        }
        let method = (request["method"] as? String ?? "GET").uppercased()
        guard let full = request["path"] as? String, full.hasPrefix("/v1/"), ["GET", "POST"].contains(method),
              !full.contains(".."), !full.hasPrefix("/v1/events"), !full.hasSuffix("/video") else {
            return Self.failure("FORBIDDEN_PATH", "Only /v1 GET/POST endpoints (except events and video) are available.", status: 403)
        }
        let query = (request["query"] as? [String: Any] ?? [:]).map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        do {
            let urlRequest = try client.request(String(full.dropFirst(3)), method: method, query: query,
                                                json: request["body"].flatMap { $0 is NSNull ? nil : $0 },
                                                idempotencyKey: request["idempotencyKey"] as? String, timeout: 600)
            let (data, http) = try await client.send(urlRequest)
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            var response: [String: Any] = ["ok": true, "status": http.statusCode, "contentType": type]
            if type.contains("json"), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                response["json"] = json
            } else {
                response["base64"] = data.base64EncodedString()
            }
            return response
        } catch let APIError.backend(status, body) {
            return ["ok": true, "status": status, "contentType": "application/json",
                    "json": ["code": body.code, "message": body.message, "retryable": body.retryable]]
        } catch {
            return Self.failure("BACKEND_UNAVAILABLE", error.localizedDescription, status: 502)
        }
    }
}

private struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
