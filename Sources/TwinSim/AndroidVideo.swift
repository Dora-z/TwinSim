import Foundation
import Network

struct AndroidVideo: Sendable {
    static let version = "4.0"
    static let size: Int64 = 732_226
    static let checksum = "84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a"
    static let source = "https://github.com/Genymobile/scrcpy/releases/download/v4.0/scrcpy-server-v4.0"
    let android: Android

    var jar: URL { android.config.root.appendingPathComponent("runtime/scrcpy-server-v\(Self.version).jar") }
    var installed: Bool { Files.size(jar) == Self.size }

    func setup(_ update: @escaping ProgressUpdate) async throws {
        if installed, try Files.sha256(jar) == Self.checksum { return }
        try Files.directory(jar.deletingLastPathComponent())
        let partial = jar.appendingPathExtension("partial")
        if Files.size(partial) != Self.size {
            _ = try await Command("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--connect-timeout", "15",
                                                   "--max-time", "60", "--retry", "2", "--continue-at", "-",
                                                   "--output", partial.path, Self.source], timeout: 195)
                .run(in: android.scratch, heartbeat: { await update("downloading-display", Files.size(partial), Self.size) })
        }
        guard Files.size(partial) == Self.size, try Files.sha256(partial) == Self.checksum else {
            try? FileManager.default.removeItem(at: partial)
            throw BackendError("CHECKSUM_MISMATCH", "The scrcpy server release failed verification.", retryable: true)
        }
        if FileManager.default.fileExists(atPath: jar.path) {
            _ = try FileManager.default.replaceItemAt(jar, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: jar)
        }
    }

    func open(_ driver: String) async throws -> VideoSession {
        guard installed, try Files.sha256(jar) == Self.checksum else {
            throw BackendError("COMPONENT_REQUIRED", "Install the android-display component first.")
        }
        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        let remote = "/data/local/tmp/twinsim-scrcpy-\(Self.version).jar"
        _ = try await android.adb(driver, ["push", jar.path, remote])
        let forward = try await android.adb(driver, ["forward", "tcp:0", "localabstract:scrcpy_" + scid])
        guard let port = UInt16(forward.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw BackendError("ANDROID_VIDEO_FORWARD", "ADB did not return a video forwarding port.")
        }
        let release: @Sendable () async -> Void = {
            _ = try? await android.adb(driver, ["forward", "--remove", "tcp:\(port)"])
        }
        do {
            let command = try await android.adbCommand(driver, [
                "shell", "CLASSPATH=\(remote)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.version,
                "scid=\(scid)", "tunnel_forward=true", "audio=false", "control=false", "cleanup=false",
                "raw_stream=true", "send_dummy_byte=true", "video_codec=h264",
                "max_size=1280", "max_fps=30", "video_bit_rate=4000000",
            ], timeout: 3600)
            let process = Task { try await command.run(in: android.scratch, limit: 2 << 20) }
            do {
                let limit = ContinuousClock.now.advanced(by: .seconds(12))
                while ContinuousClock.now < limit {
                    let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
                    connection.start(queue: .global(qos: .userInitiated))
                    let timer = DispatchWorkItem { connection.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
                    let first = try? await VideoSession.receive(connection, count: 1)
                    timer.cancel()
                    if first == Data([0]) {
                        return VideoSession(connection: connection, process: process, release: release)
                    }
                    connection.cancel()
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw BackendError("ANDROID_VIDEO_TIMEOUT", "The scrcpy video channel did not become ready.", retryable: true)
            } catch {
                process.cancel()
                _ = try? await process.value
                throw error
            }
        } catch {
            await release()
            throw error
        }
    }
}

struct VideoSession: Sendable {
    let connection: NWConnection
    let process: Task<Command.Output, Error>
    let release: @Sendable () async -> Void

    func read() async throws -> Data? {
        try await Self.receive(connection, count: 64 << 10)
    }

    func close() async {
        connection.cancel()
        process.cancel()
        _ = try? await process.value
        await release()
    }

    static func receive(_ connection: NWConnection, count: Int) async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(returning: nil) }
                    else { continuation.resume(throwing: BackendError("VIDEO_EMPTY_READ", "The video channel returned no data.")) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
