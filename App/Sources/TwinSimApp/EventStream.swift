import Foundation

struct SSEEvent: Sendable, Equatable {
    var id: String?
    var event: String
    var data: String
}

/// Incremental Server-Sent Events parser (WHATWG event-stream rules, minus `retry`).
struct SSEParser: Sendable {
    private var id: String?
    private var event: String?
    private var data: [String] = []
    private var pending = Data()
    private(set) var lastEventID: String?

    /// Feeds raw bytes and returns any completed events.
    mutating func feed(_ bytes: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        pending.append(bytes)
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            var lineData = pending[pending.startIndex..<index]
            var consumed = index
            if pending[index] == 13 {
                let next = pending.index(after: index)
                if next == pending.endIndex { break }  // wait to see whether \n follows \r
                if pending[next] == 10 { consumed = next }
            }
            if lineData.count > 1 << 20 { lineData = lineData.prefix(0) }
            let line = String(decoding: lineData, as: UTF8.self)
            pending.removeSubrange(pending.startIndex...consumed)
            if let event = process(line) { events.append(event) }
        }
        if pending.count > 4 << 20 { pending.removeAll() }
        return events
    }

    private mutating func process(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { event = nil; data = []; id = nil }
            if let id { lastEventID = id }
            guard !data.isEmpty || event != nil else { return nil }
            return SSEEvent(id: id ?? lastEventID, event: event ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(line); value = ""
        }
        switch field {
        case "id": if !value.contains("\0") { id = String(value) }
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}

/// Keeps `/v1/events` subscribed: reconnects with `Last-Event-ID` after the backend closes the
/// stream (it does so roughly every minute) or after a network error, with bounded backoff.
final class EventStream: @unchecked Sendable {
    private let client: APIClient
    private var task: Task<Void, Never>?
    private let onEvent: @MainActor @Sendable (SSEEvent) -> Void
    private let onConnection: @MainActor @Sendable (Bool) -> Void
    private let onUnauthorized: @MainActor @Sendable () -> Void

    init(client: APIClient,
         onEvent: @escaping @MainActor @Sendable (SSEEvent) -> Void,
         onConnection: @escaping @MainActor @Sendable (Bool) -> Void,
         onUnauthorized: @escaping @MainActor @Sendable () -> Void) {
        self.client = client
        self.onEvent = onEvent
        self.onConnection = onConnection
        self.onUnauthorized = onUnauthorized
    }

    func start() {
        task?.cancel()
        task = Task.detached(priority: .utility) { [client, onEvent, onConnection, onUnauthorized] in
            var lastID: String?
            var backoff: Double = 0.5
            while !Task.isCancelled {
                do {
                    let request = try client.eventsRequest(lastEventID: lastID)
                    let (bytes, response) = try await client.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.transport("SSE") }
                    if http.statusCode == 401 {
                        await onUnauthorized()
                        return
                    }
                    guard http.statusCode == 200 else { throw APIError.transport("SSE HTTP \(http.statusCode)") }
                    await onConnection(true)
                    backoff = 0.5
                    var parser = SSEParser()
                    var chunk = Data()
                    chunk.reserveCapacity(4096)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 10 {
                            for event in parser.feed(chunk) {
                                if let id = event.id { lastID = id }
                                await onEvent(event)
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    // Clean end of stream: reconnect at once with the last event ID.
                } catch {
                    if Task.isCancelled { break }
                    await onConnection(false)
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 8)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
