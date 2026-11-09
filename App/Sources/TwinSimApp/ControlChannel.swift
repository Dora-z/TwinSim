import Foundation
import Observation

/// Input-only WebSocket to the Android main display (scrcpy control protocol). Replaces
/// `adb shell input` for the device view: touches arrive in milliseconds and drags are continuous.
@MainActor @Observable
final class ControlChannel {
    enum Phase: Equatable { case connecting, ready, failed(String), closed }
    private(set) var phase: Phase = .connecting
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private(set) var sent = 0

    var isReady: Bool { phase == .ready }

    func connect(client: APIClient, instanceId: UUID) {
        guard socket == nil, var request = try? client.request("/instances/\(instanceId.uuidString)/control-session") else { return }
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        request.url = components.url
        request.httpBody = nil
        request.timeoutInterval = 24 * 3600
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 24 * 3600
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: request)
        self.session = session
        socket = task
        task.resume()
        receiver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    if case .string(let text) = try await task.receive() { self?.handle(text) }
                } catch {
                    guard let self, self.phase != .closed else { return }
                    self.phase = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "ready": phase = .ready
        case "error":
            let error = object["error"] as? [String: Any] ?? [:]
            phase = .failed((error["code"] as? String).flatMap(Labels.reason) ?? error["message"] as? String ?? "输入通道不可用")
        default: break
        }
    }

    func send(_ bytes: [UInt8]) {
        guard isReady, let socket else { return }
        sent += 1
        socket.send(.data(Data(bytes))) { _ in }
    }

    func close() {
        phase = .closed
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
