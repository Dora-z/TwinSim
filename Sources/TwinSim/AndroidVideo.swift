import Foundation
import Network

struct AndroidVideo: Sendable {
    static let version = "4.0"
    static let size: Int64 = 732_226
    static let checksum = "84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a"
    static let source = "https://github.com/Genymobile/scrcpy/releases/download/v4.0/scrcpy-server-v4.0"
    let android: Android

    /// The emulator only has software encoders (c2.android.avc.encoder): baseline profile (no
    /// CABAC, no B-frames) and real-time priority trade a little compression for encode speed.
    static let codecOptions = "profile:int=1,priority:int=0,max-bframes:int=0"

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
                "max_size=1280", "max_fps=60", "video_bit_rate=8000000", "video_codec_options=\(Self.codecOptions)",
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

/// One app shown in its own window: a scrcpy virtual display sized for the window, the app
/// started on it, H.264 out and scrcpy control messages (touch, keys, text, paste, resize) in.
struct AppSession: Sendable {
    let video: NWConnection
    let control: NWConnection
    let process: Task<Command.Output, Error>
    let release: @Sendable () async -> Void
    let drain: Task<Void, Never>

    func read() async throws -> Data? { try await VideoSession.receive(video, count: 64 << 10) }

    func sendControl(_ bytes: [UInt8]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            control.send(content: Data(bytes), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() async {
        drain.cancel()
        video.cancel()
        control.cancel()
        process.cancel()
        _ = try? await process.value
        await release()
    }

    /// Message types a client may send (scrcpy control protocol): inject keycode/text/touch/scroll,
    /// back-or-screen-on, set clipboard (paste) and resize display. Start-app is sent by the backend.
    static func allowed(_ bytes: [UInt8]) -> Bool {
        guard let type = bytes.first, bytes.count <= 256 << 10 else { return false }
        return [0, 1, 2, 3, 4, 9, 21].contains(type)
    }

    static func startApp(_ package: String) -> [UInt8] {
        let name = Array(("+" + package).utf8)   // "+" force-stops first so the app opens on this display
        return [16, UInt8(min(255, name.count))] + name.prefix(255)
    }
}

extension AndroidVideo {
    func openApp(_ driver: String, package: String, width: Int, height: Int, dpi: Int, fps: Int) async throws -> AppSession {
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
                "scid=\(scid)", "tunnel_forward=true", "audio=false", "control=true", "cleanup=false",
                "raw_stream=true", "send_dummy_byte=true", "video_codec=h264",
                "new_display=\(width)x\(height)/\(dpi)", "flex_display=true", "vd_system_decorations=false", "vd_destroy_content=true",
                "max_size=0", "max_fps=\(fps)", "video_bit_rate=12000000", "video_codec_options=\(Self.codecOptions)",
                "clipboard_autosync=false",
            ], timeout: 24 * 3600)
            let process = Task { try await command.run(in: android.scratch, limit: 2 << 20) }
            do {
                let limit = ContinuousClock.now.advanced(by: .seconds(12))
                var video: NWConnection?
                while ContinuousClock.now < limit, video == nil {
                    let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
                    connection.start(queue: .global(qos: .userInitiated))
                    let timer = DispatchWorkItem { connection.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
                    let first = try? await VideoSession.receive(connection, count: 1)
                    timer.cancel()
                    if first == Data([0]) { video = connection } else {
                        connection.cancel()
                        try await Task.sleep(for: .milliseconds(150))
                    }
                }
                guard let video else {
                    throw BackendError("ANDROID_VIDEO_TIMEOUT", "The app display channel did not become ready.", retryable: true)
                }
                // The server accepts the control socket right after the video socket.
                let control = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
                control.start(queue: .global(qos: .userInitiated))
                let drain = Task {
                    // Device messages (clipboard, acks) are not used; keep the socket drained.
                    while !Task.isCancelled, (try? await VideoSession.receive(control, count: 16 << 10)) != nil {}
                }
                let session = AppSession(video: video, control: control, process: process, release: release, drain: drain)
                await session.sendControl(AppSession.startApp(package))
                return session
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


/// Input-only scrcpy session on the main display (no video): the device view sends touch,
/// scroll, keys and text through it instead of `adb shell input`.
struct ControlSession: Sendable {
    let control: NWConnection
    let process: Task<Command.Output, Error>
    let release: @Sendable () async -> Void
    let drain: Task<Void, Never>

    func send(_ bytes: [UInt8]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            control.send(content: Data(bytes), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func close() async {
        drain.cancel()
        control.cancel()
        process.cancel()
        _ = try? await process.value
        await release()
    }
}

extension AndroidVideo {
    func openControl(_ driver: String) async throws -> ControlSession {
        guard installed, try Files.sha256(jar) == Self.checksum else {
            throw BackendError("COMPONENT_REQUIRED", "Install the android-display component first.")
        }
        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        let remote = "/data/local/tmp/twinsim-scrcpy-\(Self.version).jar"
        _ = try await android.adb(driver, ["push", jar.path, remote])
        let forward = try await android.adb(driver, ["forward", "tcp:0", "localabstract:scrcpy_" + scid])
        guard let port = UInt16(forward.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw BackendError("ANDROID_VIDEO_FORWARD", "ADB did not return a forwarding port.")
        }
        let release: @Sendable () async -> Void = {
            _ = try? await android.adb(driver, ["forward", "--remove", "tcp:\(port)"])
        }
        do {
            let command = try await android.adbCommand(driver, [
                "shell", "CLASSPATH=\(remote)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.version,
                "scid=\(scid)", "tunnel_forward=true", "video=false", "audio=false", "control=true", "cleanup=false",
                "raw_stream=true", "send_dummy_byte=true", "clipboard_autosync=false",
            ], timeout: 24 * 3600)
            let process = Task { try await command.run(in: android.scratch, limit: 2 << 20) }
            do {
                // Without video, the control socket is the first connection and carries the dummy byte.
                let limit = ContinuousClock.now.advanced(by: .seconds(12))
                while ContinuousClock.now < limit {
                    let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
                    connection.start(queue: .global(qos: .userInitiated))
                    let timer = DispatchWorkItem { connection.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
                    let first = try? await VideoSession.receive(connection, count: 1)
                    timer.cancel()
                    if first == Data([0]) {
                        let drain = Task {
                            while !Task.isCancelled, (try? await VideoSession.receive(connection, count: 16 << 10)) != nil {}
                        }
                        return ControlSession(control: connection, process: process, release: release, drain: drain)
                    }
                    connection.cancel()
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw BackendError("ANDROID_CONTROL_TIMEOUT", "The input channel did not become ready.", retryable: true)
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
