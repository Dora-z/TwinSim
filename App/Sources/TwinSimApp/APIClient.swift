import Foundation

enum APIError: LocalizedError, Sendable {
    case backend(status: Int, body: APIErrorBody)
    case transport(String)
    case decoding(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case let .backend(_, body):
            if let hint = Labels.reason(body.code) { return "\(hint)\n(\(body.code): \(body.message))" }
            return body.message.isEmpty ? body.code : "\(body.message) (\(body.code))"
        case let .transport(message): return "无法连接后端：\(message)"
        case let .decoding(message): return "后端返回了无法识别的数据：\(message)"
        case .disconnected: return "后端未连接。"
        }
    }

    var code: String? {
        if case let .backend(_, body) = self { return body.code }
        return nil
    }

    var retryable: Bool {
        switch self {
        case let .backend(status, body): return body.retryable || status >= 500
        case .transport, .disconnected: return true
        case .decoding: return false
        }
    }

    var isConnectionLoss: Bool {
        if case .transport = self { return true }
        if case .disconnected = self { return true }
        return false
    }
}

/// Thin authenticated client for the twinsimd HTTP API. Every request carries the session token.
struct APIClient: Sendable {
    let baseURL: URL
    private let token: String
    let session: URLSession

    init(handshake: Handshake) throws {
        guard let url = URL(string: handshake.url), url.host == "127.0.0.1" || url.host == "localhost" else {
            throw APIError.transport("握手地址不是本机回环地址。")
        }
        baseURL = url
        token = handshake.token
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]  // never route loopback traffic through a proxy
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 12
        session = URLSession(configuration: config)
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1"), resolvingAgainstBaseURL: false)!
        components.path += path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                 json: Any? = nil, idempotencyKey: String? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let timeout { request.timeoutInterval = timeout }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            request.httpBody = Data()
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("无效的响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(APIErrorBody.self, from: data))
                ?? APIErrorBody(code: "HTTP_\(http.statusCode)", message: String(decoding: data.prefix(500), as: UTF8.self))
            throw APIError.backend(status: http.statusCode, body: body)
        }
        return (data, http)
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await send(request(path, query: query))
        return try decode(data)
    }

    func post<T: Decodable>(_ path: String, json: Any? = nil, idempotencyKey: String? = nil,
                            as type: T.Type = T.self) async throws -> T {
        let (data, _) = try await send(request(path, method: "POST", json: json, idempotencyKey: idempotencyKey))
        return try decode(data)
    }

    func raw(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval? = nil) async throws -> (Data, String) {
        let (data, response) = try await send(request(path, query: query, timeout: timeout))
        return (data, response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decoding(String(describing: error)) }
    }

    // MARK: Endpoints

    func health() async throws -> [String: String] { try await get("/health") }
    func components() async throws -> [Component] { try await get("/components") }
    func engines() async throws -> [EngineInfo] { try await get("/engines") }
    func instances() async throws -> [Instance] { try await get("/instances") }
    func instance(_ id: UUID) async throws -> Instance { try await get("/instances/\(id.uuidString)") }
    func artifacts() async throws -> [Artifact] { try await get("/artifacts") }
    func operation(_ id: UUID) async throws -> BackendOperation { try await get("/operations/\(id.uuidString)") }

    func installComponent(_ id: String, acceptLicenses: [String: String]?, key: String) async throws -> OperationAccepted {
        var body: [String: Any] = [:]
        if let acceptLicenses, !acceptLicenses.isEmpty { body["acceptLicenses"] = acceptLicenses }
        return try await post("/components/\(id)/install", json: body, idempotencyKey: key)
    }

    func createInstance(engineId: String, profileId: String, name: String, externalName: String?, key: String) async throws -> OperationAccepted {
        var body: [String: Any] = ["engineId": engineId, "profileId": profileId, "name": name]
        if let externalName, !externalName.isEmpty { body["externalName"] = externalName }
        return try await post("/instances", json: body, idempotencyKey: key)
    }

    func action(_ instance: UUID, _ action: String, body: [String: Any] = [:], key: String) async throws -> OperationAccepted {
        try await post("/instances/\(instance.uuidString)/actions/\(action)", json: body, idempotencyKey: key)
    }

    func importArtifact(path: String) async throws -> Artifact {
        try await post("/artifacts/import", json: ["path": path])
    }

    func launch(_ artifact: UUID, instanceId: UUID?, profileId: String?, key: String) async throws -> OperationAccepted {
        var body: [String: Any] = [:]
        if let instanceId { body["instanceId"] = instanceId.uuidString }
        if let profileId { body["profileId"] = profileId }
        return try await post("/artifacts/\(artifact.uuidString)/launch", json: body, idempotencyKey: key)
    }

    func screenshot(_ instance: UUID) async throws -> Data {
        try await raw("/instances/\(instance.uuidString)/screenshot", timeout: 60).0
    }

    func logs(_ instance: UUID, lines: Int) async throws -> String {
        let value: [String: String] = try await get("/instances/\(instance.uuidString)/logs",
                                                    query: [URLQueryItem(name: "lines", value: String(lines))])
        return value["text"] ?? ""
    }

    func guestFile(_ instance: UUID, path: String) async throws -> Data {
        try await raw("/instances/\(instance.uuidString)/guest-file", query: [URLQueryItem(name: "path", value: path)], timeout: 600).0
    }

    func videoRequest(_ instance: UUID) throws -> URLRequest {
        var r = try request("/instances/\(instance.uuidString)/video")
        r.timeoutInterval = 24 * 3600
        return r
    }

    func eventsRequest(lastEventID: String?) throws -> URLRequest {
        var r = try request("/events")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { r.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        r.timeoutInterval = 90
        return r
    }
}
