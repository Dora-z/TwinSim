import CryptoKit
import Foundation
import Vapor

private struct APIAuth: AsyncMiddleware {
    let config: Configuration

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let host = request.headers.first(name: .host) ?? ""
        guard host.range(of: "^(127\\.0\\.0\\.1|localhost)(:[0-9]{1,5})?$", options: .regularExpression) != nil else {
            return try json(BackendError("INVALID_HOST", "Use the local backend address."), .forbidden)
        }
        let origin = request.headers.first(name: .origin)
        if let origin, origin != config.origin {
            return try json(BackendError("INVALID_ORIGIN", "The origin is not allowed."), .forbidden)
        }
        let response: Response
        if request.method == .OPTIONS, origin != nil {
            response = Response(status: .noContent)
            response.headers.replaceOrAdd(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            response.headers.replaceOrAdd(name: "Access-Control-Allow-Headers",
                                          value: "Authorization, Content-Type, Idempotency-Key, Last-Event-ID, X-Filename")
        } else {
            let sent = Array((request.headers.first(name: .authorization) ?? "").utf8)
            let expected = Array(("Bearer " + config.token).utf8)
            guard sent.count == expected.count, zip(sent, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
                return try json(BackendError("UNAUTHORIZED", "A valid backend session token is required."), .unauthorized)
            }
            do { response = try await next.respond(to: request) }
            catch {
                let failure: BackendError
                let status: HTTPResponseStatus
                switch error {
                case let error as BackendError:
                    failure = error
                    switch error.code {
                    case "IDEMPOTENCY_CONFLICT", "RESOURCE_BUSY", "INSTANCE_NOT_READY", "COMPONENT_REQUIRED",
                         "EXTERNAL_SETUP_REQUIRED": status = .conflict
                    case "OPERATION_NOT_FOUND", "INSTANCE_NOT_FOUND", "ARTIFACT_NOT_FOUND", "COMPONENT_NOT_FOUND",
                         "ACTION_NOT_FOUND": status = .notFound
                    default: status = .unprocessableEntity
                    }
                case let abort as Abort:
                    status = abort.status
                    failure = BackendError("HTTP_\(abort.status.code)", abort.reason)
                case is DecodingError:
                    status = .badRequest
                    failure = BackendError("INVALID_JSON", "Request body does not match the API schema.")
                default:
                    status = .internalServerError
                    failure = BackendError.wrap(error)
                }
                response = try json(failure, status)
            }
        }
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        if let origin {
            response.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: origin)
            response.headers.add(name: "Vary", value: "Origin")
        }
        return response
    }
}

private struct OperationAccepted: Encodable {
    let operationId: UUID
    let instanceId: UUID?
}

private struct EngineView: Encodable {
    let engineId: Engine
    let profiles: [Profile]
    let componentIds: [String]
}

func configure(_ app: Application, backend: Backend, configuration: Configuration) throws {
    app.middleware.use(APIAuth(config: configuration))
    let api = app.grouped("v1")

    api.get("health") { _ in try json(["status": "ok", "apiVersion": "1"]) }
    api.get("engines") { _ in
        try json(Engine.allCases.map { engine in
            let profiles = Profile.allCases.filter { $0.engine == engine }
            let ids = Set(profiles.map(\.component))
            return EngineView(engineId: engine, profiles: profiles,
                              componentIds: (engine == .android ? ["android-engine", "android-display"] : [])
                                + ids.sorted() + (engine == .windows ? ["windows-dxvk"] : []))
        })
    }
    api.get("components") { _ in try await json(backend.components()) }
    api.post("components", ":component", "install") { request in
        let component = try parameter(request, "component")
        let input = try decode(request, default: InstallComponentRequest())
        let identity = try idempotency(request)
        let op = try await backend.installComponent(component, request: input, key: identity.key, fingerprint: identity.hash)
        return try accepted(op)
    }
    api.get("instances") { _ in try await json(backend.instances()) }
    api.get("instances", ":id") { request in try await json(backend.instance(uuid(request, "id"))) }
    api.post("instances") { request in
        let input = try decode(request, as: CreateRequest.self)
        let identity = try idempotency(request)
        return try await accepted(backend.create(input, key: identity.key, fingerprint: identity.hash))
    }
    api.post("instances", ":id", "actions", ":action") { request in
        let id = try uuid(request, "id")
        let action = try parameter(request, "action")
        let input = try decode(request, default: ActionRequest())
        let identity = try idempotency(request)
        return try await accepted(backend.action(id, action: action, request: input, key: identity.key, fingerprint: identity.hash))
    }
    api.get("instances", ":id", "screenshot") { request in
        let (mime, data) = try await backend.screenshot(uuid(request, "id"))
        return Response(status: .ok, headers: ["Content-Type": mime], body: .init(data: data))
    }
    api.get("instances", ":id", "video") { request in
        let id = try uuid(request, "id")
        let session = try await backend.openVideo(id)
        let body = Response.Body(managedAsyncStream: { writer in
            do {
                while let chunk = try await session.read() {
                    try await writer.writeBuffer(ByteBuffer(bytes: chunk))
                }
            } catch {
                await backend.closeVideo(id, session: session)
                throw error
            }
            await backend.closeVideo(id, session: session)
        })
        return Response(status: .ok, headers: ["Content-Type": "video/h264"], body: body)
    }
    // App window: binary frames out = H.264 Annex B; binary frames in = scrcpy control messages.
    api.webSocket("instances", ":id", "app-session", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 1 << 20)) { request, ws in
        Task {
            let session: AppSession
            do {
                let id = try uuid(request, "id")
                let package = try request.query.get(String.self, at: "package")
                session = try await backend.openAppSession(
                    id, package: package,
                    width: (try? request.query.get(Int.self, at: "width")) ?? 1080,
                    height: (try? request.query.get(Int.self, at: "height")) ?? 2340,
                    dpi: (try? request.query.get(Int.self, at: "dpi")) ?? 320,
                    fps: (try? request.query.get(Int.self, at: "fps")) ?? 60)
            } catch {
                let failure = BackendError.wrap(error)
                let body = (try? JSONEncoder().encode(failure)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                try? await ws.send("{\"type\":\"error\",\"error\":\(body)}")
                try? await ws.close(code: .unexpectedServerError)
                return
            }
            try? await ws.send("{\"type\":\"ready\"}")
            ws.onBinary { _, buffer in
                let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
                guard AppSession.allowed(bytes) else { return }
                await session.sendControl(bytes)
            }
            ws.onClose.whenComplete { _ in Task { await session.close() } }
            do {
                while let chunk = try await session.read() { try await ws.send(Array(chunk)) }
            } catch {}
            await session.close()
            try? await ws.close()
        }
    }
    // Device view input: binary frames in = scrcpy control messages for the main display.
    api.webSocket("instances", ":id", "control-session", maxFrameSize: WebSocketMaxFrameSize(integerLiteral: 1 << 20)) { request, ws in
        Task {
            let session: ControlSession
            do {
                session = try await backend.openControlSession(try uuid(request, "id"))
            } catch {
                let body = (try? JSONEncoder().encode(BackendError.wrap(error))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                try? await ws.send("{\"type\":\"error\",\"error\":\(body)}")
                try? await ws.close(code: .unexpectedServerError)
                return
            }
            try? await ws.send("{\"type\":\"ready\"}")
            ws.onBinary { _, buffer in
                let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
                guard AppSession.allowed(bytes) else { return }
                await session.send(bytes)
            }
            try? await ws.onClose.get()
            await session.close()
        }
    }
    api.get("instances", ":id", "logs") { request in
        let lines = (try? request.query.get(Int.self, at: "lines")) ?? 200
        return try await json(["text": backend.logs(uuid(request, "id"), lines: lines)])
    }
    api.get("instances", ":id", "guest-file") { request in
        let path = try? request.query.get(String.self, at: "path")
        let data = try await backend.pull(uuid(request, "id"), remotePath: path)
        return Response(status: .ok, headers: ["Content-Type": "application/octet-stream"], body: .init(data: data))
    }
    api.get("artifacts") { _ in try await json(backend.artifacts()) }
    api.post("artifacts", "import") { request in
        let input = try decode(request, as: ImportRequest.self)
        return try await json(backend.importApp(path: input.path), .created)
    }
    api.on(.POST, "artifacts", body: .collect(maxSize: "128mb")) { request in
        guard let filename = request.headers.first(name: "X-Filename"), let bytes = request.body.data else {
            throw BackendError("INVALID_ARTIFACT", "Send an APK or IPA body with X-Filename.")
        }
        let scratch = try Files.scratch(in: backend.scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let upload = scratch.appendingPathComponent("upload")
        try Data(bytes.readableBytesView).write(to: upload)
        return try await json(backend.importUpload(upload, filename: filename), .created)
    }
    api.post("artifacts", ":id", "launch") { request in
        let id = try uuid(request, "id")
        let input = try decode(request, default: LaunchRequest())
        let identity = try idempotency(request)
        return try await accepted(backend.launch(id, request: input, key: identity.key, fingerprint: identity.hash))
    }
    api.post("artifacts", ":id", "delete") { request in
        let id = try uuid(request, "id")
        let input = try decode(request, default: DeleteArtifactRequest())
        let identity = try idempotency(request)
        return try await accepted(backend.deleteArtifact(id, uninstall: input.uninstall ?? true,
                                                         key: identity.key, fingerprint: identity.hash))
    }
    api.get("operations", ":id") { request in try await json(backend.operation(uuid(request, "id"))) }

    api.get("events") { request in
        let initial = request.headers.first(name: "Last-Event-ID")
        let body = Response.Body(managedAsyncStream: { writer in
            var cursor = initial
            for index in 0..<240 {
                let batch = await backend.eventBatch(after: cursor)
                for (id, kind, data) in batch {
                    let line = "id: \(id)\nevent: \(kind)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
                    try await writer.writeBuffer(ByteBuffer(string: line))
                    cursor = id
                }
                if batch.isEmpty && index.isMultiple(of: 40) {
                    try await writer.writeBuffer(ByteBuffer(string: ": heartbeat\n\n"))
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        })
        return Response(status: .ok, headers: ["Content-Type": "text/event-stream"], body: body)
    }
}

private func json<T: Encodable>(_ value: T, _ status: HTTPResponseStatus = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(status: status, headers: ["Content-Type": "application/json"], body: .init(data: data))
}

private func accepted(_ op: Operation) throws -> Response {
    try json(OperationAccepted(operationId: op.id, instanceId: op.instanceId), .accepted)
}

private func parameter(_ request: Request, _ name: String) throws -> String {
    guard let value = request.parameters.get(name), value.count <= 128 else { throw Abort(.badRequest, reason: "Invalid route parameter.") }
    return value
}

private func uuid(_ request: Request, _ name: String) throws -> UUID {
    guard let id = UUID(uuidString: try parameter(request, name)) else { throw Abort(.badRequest, reason: "Expected a UUID.") }
    return id
}

private func decode<T: Decodable>(_ request: Request, as: T.Type = T.self) throws -> T {
    guard let bytes = request.body.data else { throw Abort(.badRequest, reason: "A JSON body is required.") }
    return try JSONDecoder().decode(T.self, from: Data(bytes.readableBytesView))
}

private func decode<T: Decodable>(_ request: Request, default value: T) throws -> T {
    guard let bytes = request.body.data, bytes.readableBytes > 0 else { return value }
    return try JSONDecoder().decode(T.self, from: Data(bytes.readableBytesView))
}

private func idempotency(_ request: Request) throws -> (key: String?, hash: String) {
    let key = request.headers.first(name: "Idempotency-Key")
    if let key, key.isEmpty || key.utf8.count > 128 {
        throw Abort(.badRequest, reason: "Invalid Idempotency-Key.")
    }
    var digest = SHA256()
    digest.update(data: Data(request.url.path.utf8))
    digest.update(data: Data([0]))
    if let body = request.body.data { digest.update(data: Data(body.readableBytesView)) }
    return (key, digest.finalize().map { String(format: "%02x", $0) }.joined())
}
