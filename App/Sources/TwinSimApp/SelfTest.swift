import AppKit
import SwiftUI
import CoreImage
import Foundation

/// End-to-end check of the frontend against the real bundled backend. Enabled only when the app
/// is started with TWINSIM_SELF_TEST=<report directory> and TWINSIM_SELF_TEST_SAMPLES=<directory
/// with TouchProbe.apk, TouchProbe.app and TouchProbeDevice.ipa>. It drives the same store,
/// windows, decoder and input mapping the user interface uses, then writes report.md.
@MainActor
final class SelfTest {
    private let store: AppStore
    private let samples: URL
    private let out: URL
    private var lines: [String] = []
    private var checks: [(String, Bool, String)] = []
    private let started = Date()

    static func startIfRequested(store: AppStore) {
        let env = ProcessInfo.processInfo.environment
        guard let report = env["TWINSIM_SELF_TEST"], let samples = env["TWINSIM_SELF_TEST_SAMPLES"] else { return }
        let test = SelfTest(store: store, samples: URL(fileURLWithPath: samples), out: URL(fileURLWithPath: report))
        let platforms = Set((env["TWINSIM_SELF_TEST_PLATFORMS"] ?? "android,ios,ipa").split(separator: ",").map(String.init))
        Task { await test.run(platforms) }
    }

    init(store: AppStore, samples: URL, out: URL) {
        self.store = store
        self.samples = samples
        self.out = out
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    private func log(_ text: String) {
        let stamp = String(format: "%7.1fs", Date().timeIntervalSince(started))
        let line = "[\(stamp)] \(text)"
        lines.append(line)
        FileHandle.standardError.write(Data((line + "\n").utf8))
        let file = out.appendingPathComponent("selftest.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: file)
        }
    }

    @discardableResult
    private func check(_ name: String, _ ok: Bool, _ detail: String = "") -> Bool {
        checks.append((name, ok, detail))
        log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        return ok
    }

    private func waitUntil(_ timeout: TimeInterval, poll: Double = 0.25, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .seconds(poll))
        }
        return condition()
    }

    func run(_ platforms: Set<String>) async {
        log("Self-test started. TWINSIM_HOME=\(ProcessInfo.processInfo.environment["TWINSIM_HOME"] ?? "(default)")")
        guard await waitUntil(90, { store.isConnected && !store.components.isEmpty }) else {
            check("backend handshake", false, "\(store.connection) \(store.backendDiagnostics.suffix(400))")
            return finish()
        }
        check("backend handshake + token auth", true, "helper \(store.helperPath ?? "?") pid \(store.helperPID ?? 0)")
        check("SSE subscribed (reset handled)", await waitUntil(10) { store.eventsConnected && store.eventCount > 0 },
              "events \(store.eventCount)")
        log("components: " + store.components.map { "\($0.id)=\($0.status)\($0.reasonCode.map { "(\($0))" } ?? "")" }.joined(separator: ", "))
        await snapshotMain("01-components", select: .components)

        if platforms.contains("android") { await android() }
        if platforms.contains("ios") { await ios() }
        if platforms.contains("ipa") { await ipa() }
        if platforms.contains("device") { await devices() }
        if platforms.contains("data") { await dataMove() }
        if platforms.contains("windows") { await windowsPlatform() }
        if platforms.contains("library") { await library() }
        if platforms.contains("appwindow") { await appWindow() }
        if platforms.contains("perf") { await performance() }
        if platforms.contains("hardware") { await hardware() }
        if platforms.contains("frida") { await frida() }
        await snapshotMain("09-devices", select: .devices)
        renderOffscreen(AISettingsView().environment(store), size: CGSize(width: 640, height: 1000), "12-ai-settings")
        renderOffscreen(SettingsView().environment(store), size: CGSize(width: 560, height: 1300), "13-settings")
        check("agent bridge listening", store.agentBridge?.isListening == true, store.agentBridge?.path ?? "")
        finish()
    }

    // MARK: Android

    private func android() async {
        log("== Android ==")
        if let display = store.component("android-display"), !display.isReady {
            log("installing android-display")
            await store.installComponent(display, accepting: [])
        }
        check("android-display component ready", store.component("android-display")?.isReady == true)
        guard let apk = await store.importFiles([samples.appendingPathComponent("TouchProbe.apk")]).first else {
            check("APK import", false); return
        }
        check("APK import", apk.kind == "apk" && apk.bundleId == "org.twinsim.touchprobe", "\(apk.bundleId) \(apk.sha256.prefix(12))")
        let again = await store.importFiles([samples.appendingPathComponent("TouchProbe.apk")]).first
        check("APK re-import deduplicated", again?.id == apk.id)
        await snapshotMain("02-apps", select: .apps)

        var t = Date()
        await store.open(apk, forceDeviceView: true)
        let workspace = store.instances.first { $0.isAppWorkspace && $0.isAndroid }
        guard let ws = workspace, check("Android launch (open-app)", ws.isReady,
                                        "profile \(ws.profileId), \(String(format: "%.1f", Date().timeIntervalSince(t)))s") else {
            log("notices: \(store.notices.map(\.message))"); return
        }
        guard await waitUntil(15, { store.screenSession(ws.id) != nil }), let session = store.screenSession(ws.id) else {
            check("app window opened", false); return
        }
        check("app window opened", true)
        let video = await waitUntil(60) { session.source == .video && session.stats.decodedFrames >= 3 }
        check("live H.264 decoded (VideoToolbox)", video,
              "frames \(session.stats.decodedFrames), bytes \(session.stats.receivedBytes), errors \(session.stats.decodeErrors), idle flushes \(session.stats.idleFlushes)")
        _ = await waitUntil(20) { session.guestSize != nil && session.contentSize != nil }
        check("guest vs video size", session.guestSize != nil,
              "guest \(fmt(session.guestSize)), video \(fmt(session.contentSize))")
        saveFrame(session, "03-android-video")
        snapshotWindow(containing: "TouchProbe", "04-android-window")

        // Touch: normalised picture points go through the same mapping as mouse clicks.
        var expected: [CGPoint] = []
        for p in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.85, y: 0.3)] {
            guard let g = session.guestPoint(normalized: p) else { continue }
            expected.append(g)
            session.tap(normalized: p)
        }
        let framesBefore = session.totalFrames
        _ = await waitUntil(60) { session.pendingInputs == 0 }
        try? await Task.sleep(for: .seconds(1))
        let taps = await touchLog(ws.id)
        if let error = session.lastInputError { log("input error: \(error)") }
        let matched = zip(expected, taps.suffix(expected.count)).allSatisfy { abs($0.x - $1.x) <= 2 && abs($0.y - $1.y) <= 2 }
        check("touch mapped to guest pixels", matched && taps.count >= expected.count,
              "expected \(expected.map(fmt)), guest saw \(taps.suffix(expected.count).map(fmt))")
        check("video updates after touch", await waitUntil(10) { session.totalFrames > framesBefore },
              "frames \(framesBefore) -> \(session.totalFrames)")
        saveFrame(session, "05-android-after-taps")

        // Reopen: same workspace instance, existing install reused.
        session.key("KEYCODE_HOME")
        _ = await waitUntil(30) { session.pendingInputs == 0 }
        let count = store.instances.count
        t = Date()
        await store.open(apk, forceDeviceView: true)
        let reopened = store.instances.first { $0.isAppWorkspace && $0.isAndroid }
        check("reopen reuses instance", reopened?.id == ws.id && store.instances.count == count,
              String(format: "%.1fs", Date().timeIntervalSince(t)))

        // Network drop: the stream reconnects and decoding resumes.
        let reconnects = session.reconnects
        try? await Task.sleep(for: .seconds(2))
        var mark = session.totalFrames
        session.simulateVideoDrop()
        let rejoined = await waitUntil(30) { session.reconnects > reconnects && session.source == .video }
        try? await Task.sleep(for: .seconds(1))
        session.tap(normalized: CGPoint(x: 0.5, y: 0.3))   // force a screen change on the new stream
        let flowing = await waitUntil(15) { session.totalFrames > mark }
        check("video reconnect after drop", rejoined && flowing,
              "reconnects \(session.reconnects), frames \(mark) -> \(session.totalFrames)")
        if !rejoined { log("video log:\n  " + session.videoLog.joined(separator: "\n  ")) }

        // Screenshot fallback and back.
        session.setPreferScreenshots(true)
        let shot = await waitUntil(20) { session.source == .screenshots && session.contentSize == session.guestSize && session.contentSize != nil }
        check("screenshot fallback", shot, "content \(fmt(session.contentSize))")
        session.setPreferScreenshots(false)
        mark = session.totalFrames
        check("back to live video", await waitUntil(30) { session.source == .video && session.stats.decodedFrames > 0 && session.totalFrames > mark })

        // Helper crash: frontend restarts it, re-syncs, and the window reconnects.
        if let pid = store.helperPID {
            log("killing helper pid \(pid)")
            kill(pid, SIGKILL)
            let back = await waitUntil(60) { store.isConnected && store.helperPID != nil && store.helperPID != pid }
            check("helper restarted after crash", back, "new pid \(store.helperPID ?? 0)")
            let ready = await waitUntil(60) { store.instance(ws.id)?.isReady == true }
            check("instance re-synced after restart", ready, "state \(store.instance(ws.id)?.state ?? "?")")
            mark = session.totalFrames
            session.tap(normalized: CGPoint(x: 0.5, y: 0.6))
            check("video resumes after restart", await waitUntil(60) { session.source == .video && session.totalFrames > mark },
                  "frames \(mark) -> \(session.totalFrames)")
            if session.totalFrames <= mark { log("video log:\n  " + session.videoLog.joined(separator: "\n  ")) }
        }

        t = Date()
        do {
            try await store.perform(ws.id, "stop", timeout: 180)
            await store.refreshInstance(ws.id)
            check("Android stop", store.instance(ws.id)?.state == "stopped", String(format: "%.1fs", Date().timeIntervalSince(t)))
        } catch {
            check("Android stop", false, error.localizedDescription)
        }
        check("window shows stopped state", await waitUntil(10) { session.source == .none })
        closeWindows()
    }

    private func touchLog(_ id: UUID) async -> [CGPoint] {
        // Filter in the guest: right after boot the log buffer is far too busy for a tail.
        guard let op = try? await store.perform(id, "shell", body: ["argv": ["logcat", "-d", "-s", "TwinSimTouch:I"]], timeout: 60),
              let text = op.result?["stdout"] else { return [] }
        return text.split(separator: "\n").compactMap { line -> CGPoint? in
            guard line.contains("TwinSimTouch"), let range = line.range(of: #"x=(\d+) y=(\d+)"#, options: .regularExpression) else { return nil }
            let parts = line[range].split(separator: " ").map { $0.split(separator: "=")[1] }
            guard let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: iOS

    private func ios() async {
        log("== iOS Simulator ==")
        guard store.component("ios-simulator-runtime")?.isReady == true else {
            check("iOS Simulator runtime ready", false, store.component("ios-simulator-runtime")?.reasonCode ?? ""); return
        }
        guard let app = await store.importFiles([samples.appendingPathComponent("TouchProbe.app")]).first else {
            check("Simulator .app import", false); return
        }
        check("Simulator .app import", app.kind == "simulatorApp", app.bundleId)
        var t = Date()
        await store.open(app)
        guard let ws = store.instances.first(where: { $0.isAppWorkspace && $0.isSimulator }),
              check("iOS launch (open-app)", ws.isReady, String(format: "%.1fs", Date().timeIntervalSince(t))) else {
            log("notices: \(store.notices.map(\.message))"); return
        }
        guard await waitUntil(15, { store.screenSession(ws.id) != nil }), let session = store.screenSession(ws.id) else {
            check("iOS window opened", false); return
        }
        let shot = await waitUntil(60) { session.source == .screenshots && session.contentSize != nil }
        check("iOS screenshot shown", shot, "size \(fmt(session.contentSize))")
        if let image = await session.captureScreenshot(updateDisplay: false) { savePNG(image, "06-ios-screenshot") }
        snapshotWindow(containing: "TouchProbe", "07-ios-window")
        check("iOS input hidden (capability unsupported)", store.instance(ws.id)?.capability("input")?.isSupported == false)
        var logs = ""
        var logError = ""
        for attempt in 1...2 where logs.isEmpty {
            let t0 = Date()
            do { logs = try await store.client?.logs(ws.id, lines: 100) ?? "" }
            catch { logError = "attempt \(attempt) after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(error.localizedDescription)" ; log(logError) }
        }
        check("iOS logs", !logs.isEmpty, logs.isEmpty ? logError : "\(logs.split(separator: "\n").count) lines")
        let count = store.instances.count
        t = Date()
        await store.open(app)
        check("iOS reopen reuses instance", store.instances.first { $0.isAppWorkspace && $0.isSimulator }?.id == ws.id && store.instances.count == count,
              String(format: "%.1fs", Date().timeIntervalSince(t)))
        t = Date()
        do {
            try await store.perform(ws.id, "stop", timeout: 180)
            await store.refreshInstance(ws.id)
            check("iOS stop", store.instance(ws.id)?.state == "stopped", String(format: "%.1fs", Date().timeIntervalSince(t)))
        } catch {
            check("iOS stop", false, error.localizedDescription)
        }
        closeWindows()
    }

    // MARK: Android hardware settings (CPU cores / RAM)

    private func guestHardware(_ id: UUID) async -> (Int, Int) {
        guard let op = try? await store.perform(id, "shell", body: ["argv": ["sh", "-c", "grep -c ^processor /proc/cpuinfo; grep MemTotal /proc/meminfo"]], timeout: 60)
        else { return (0, 0) }
        let lines = (op.result?["stdout"] ?? "").split(separator: "\n")
        let cores = Int(lines.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        let kb = lines.dropFirst().first.flatMap { Int($0.split(whereSeparator: { !$0.isNumber }).joined()) } ?? 0
        return (cores, kb / 1024)
    }

    /// MemTotal is a little below the configured size (kernel reservations); the emulator raises
    /// RAM below the image minimum (measured 2560 MB for API 34).
    private func ramMatches(_ guestMB: Int, _ configured: Int) -> Bool {
        let effective = max(configured, 2560)
        return guestMB > effective - 640 && guestMB <= effective
    }

    private func hardware() async {
        log("== Android hardware settings ==")
        var t = Date()
        guard let id = await store.createInstance(engineId: "android-emulator", profileId: "android-google-apis",
                                                  name: "HW Test", externalName: nil, cpus: 3, ramMB: 2048) else {
            check("create with 3 cores / 2 GB", false, store.notices.last?.message ?? ""); return
        }
        await store.refreshInstance(id)
        check("create with 3 cores / 2 GB", store.instance(id)?.hardware.map { $0.cpus == 3 && $0.ramMB == 2048 && $0.custom } ?? false,
              String(format: "%.1fs", Date().timeIntervalSince(t)))
        await store.run(id, "start")
        var (cores, ram) = await guestHardware(id)
        check("guest sees 3 cores / ~2 GB", cores == 3 && ramMatches(ram, 2048), "cores \(cores), MemTotal \(ram) MB")

        // Change while running: stored, applied on next start.
        let op = await store.run(id, "hardware", body: ["cpus": 4, "ramMB": 3072])
        await store.refreshInstance(id)
        check("change while running is pending", op?.result?["applied"] == "next-start" && store.instance(id)?.hardware?.pending == true)
        t = Date()
        await store.run(id, "stop")
        await store.run(id, "start")
        (cores, ram) = await guestHardware(id)
        await store.refreshInstance(id)
        check("after restart guest sees 4 cores / ~3 GB", cores == 4 && ramMatches(ram, 3072) && store.instance(id)?.hardware?.pending == false,
              String(format: "cores \(cores), MemTotal \(ram) MB, restart %.1fs", Date().timeIntervalSince(t)))

        // Stopped device: the CLI (same path as MCP) changes it immediately.
        await store.run(id, "stop")
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/twinsim")
        let out = await Task.detached { () -> String in
            let p = Process(); p.executableURL = cli
            p.arguments = ["set_device_hardware", "--device", id.uuidString, "--cpus", "2", "--ramMB", "2048"]
            var e = ProcessInfo.processInfo.environment; e["TWINSIM_NO_LAUNCH"] = "1"; p.environment = e
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try? p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
        check("CLI/MCP set_device_hardware on stopped device", out.contains("applied."), out.trimmingCharacters(in: .whitespacesAndNewlines))
        await store.run(id, "start")
        (cores, ram) = await guestHardware(id)
        check("guest sees 2 cores / ~2 GB", cores == 2 && ramMatches(ram, 2048), "cores \(cores), MemTotal \(ram) MB")

        // Back to the default (automatic unless Settings say otherwise).
        await store.run(id, "stop")
        await store.run(id, "hardware", body: ["useDefault": true])
        await store.refreshInstance(id)
        let hw = store.instance(id)?.hardware
        await store.run(id, "start")
        (cores, ram) = await guestHardware(id)
        check("restore default", hw?.custom == false && cores == hw?.cpus && ramMatches(ram, hw?.ramMB ?? 0),
              "default \(hw?.cpus ?? 0) cores / \(hw?.ramMB ?? 0) MB, guest \(cores) / \(ram) MB")

        // Out of range is rejected with a clear code.
        do {
            _ = try await store.perform(id, "hardware", body: ["cpus": 999], timeout: 60)
            check("reject out-of-range cores", false, "accepted")
        } catch let failure as OperationFailure {
            check("reject out-of-range cores", failure.body.code == "INVALID_HARDWARE", failure.body.message)
        } catch {
            check("reject out-of-range cores", (error as? APIError)?.code == "INVALID_HARDWARE", error.localizedDescription)
        }
        _ = await store.deleteInstance(id)
    }

    // MARK: Built-in frida-server

    private func frida() async {
        log("== Built-in frida-server ==")
        guard let id = await store.createInstance(engineId: "android-emulator", profileId: "android-google-apis",
                                                  name: "Frida Test", externalName: nil) else {
            check("create device", false, store.notices.last?.message ?? ""); return
        }
        await store.run(id, "start")
        await store.refreshInstance(id)
        let cap = store.instance(id)?.capability("frida")
        check("frida capability available", cap?.isAvailable == true, "\(cap?.availability ?? "-") \(cap?.reasonCode ?? "")")
        var t = Date()
        let op = await store.run(id, "frida-start")
        let port = op?.result?["localPort"].flatMap(Int.init)
        check("frida-start", port != nil, String(format: "%@ pid %@ v%@ %.1fs", "127.0.0.1:\(port ?? 0)", op?.result?["pid"] ?? "?",
                                                 op?.result?["version"] ?? "?", Date().timeIntervalSince(t)))
        guard let port else { _ = await store.deleteInstance(id); return }
        let pid = (try? await store.perform(id, "shell", body: ["argv": ["sh", "-c", "pidof twinsim-frida-server; id -u"]], timeout: 60))?
            .result?["stdout"] ?? ""
        let lines = pid.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        check("frida-server runs in guest (root shell)", lines.count == 2 && Int(lines[0]) != nil && lines[1] == "0",
              pid.replacingOccurrences(of: "\n", with: " "))
        // adb accepts the forward even without a listener but then drops the connection; an HTTP answer means frida-server replied.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!); request.timeoutInterval = 10
        let reply = try? await URLSession.shared.data(for: request)
        check("frida-server answers on 127.0.0.1:\(port)", reply != nil,
              (reply?.1 as? HTTPURLResponse).map { "HTTP \($0.statusCode) \($0.value(forHTTPHeaderField: "Server") ?? "")" } ?? "no response")
        await store.refreshInstance(id)
        check("instance reports frida status", store.instance(id)?.frida?.running == true && store.instance(id)?.frida?.localPort == port,
              store.instance(id)?.frida?.address ?? "-")
        if let instance = store.instance(id) {
            renderOffscreen(ToolsPanel(instance: instance).environment(store), size: CGSize(width: 420, height: 900), "14-frida-tools")
        }
        t = Date()
        let again = await store.run(id, "frida-start")
        check("frida-start is idempotent", again?.result?["localPort"] == String(port), String(format: "%.1fs", Date().timeIntervalSince(t)))

        // Optional: attach with a host Frida client of the same major version (TWINSIM_SELFTEST_FRIDA_PYTHON=/path/to/python).
        if let python = ProcessInfo.processInfo.environment["TWINSIM_SELFTEST_FRIDA_PYTHON"] {
            let target = ((try? await store.perform(id, "shell", body: ["argv": ["sh", "-c", "pidof com.android.systemui"]], timeout: 60))?
                .result?["stdout"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let script = """
            import frida, sys
            device = frida.get_device_manager().add_remote_device(sys.argv[1])
            session = device.attach(int(sys.argv[2]))
            out = []
            s = session.create_script("send(Process.arch + ' ' + Process.id + ' ' + Process.enumerateModules().length + ' modules')")
            s.on('message', lambda m, d: out.append(m.get('payload') or m.get('description')))
            s.load(); session.detach()
            print(frida.__version__, out[0] if out else 'no-message')
            """
            let result = await Task.detached { () -> String in
                let p = Process(); p.executableURL = URL(fileURLWithPath: python)
                p.arguments = ["-I", "-c", script, "127.0.0.1:\(port)", target]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                try? p.run(); p.waitUntilExit()
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }.value.trimmingCharacters(in: .whitespacesAndNewlines)
            check("Frida client attaches to SystemUI (pid \(target))", result.contains("arm64 \(target)"), result.split(separator: "\n").last.map(String.init) ?? "")
        }

        // Stop through the CLI (same path as the MCP tool).
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/twinsim")
        let out = await Task.detached { () -> String in
            let p = Process(); p.executableURL = cli
            p.arguments = ["frida_server", "--device", id.uuidString, "--action", "stop"]
            var e = ProcessInfo.processInfo.environment; e["TWINSIM_NO_LAUNCH"] = "1"; p.environment = e
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            try? p.run(); p.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }.value
        let after = (try? await store.perform(id, "shell", body: ["argv": ["sh", "-c", "pidof twinsim-frida-server || echo none"]], timeout: 60))?
            .result?["stdout"] ?? ""
        await store.refreshInstance(id)
        check("CLI/MCP frida_server stop", out.contains("stopped") && after.contains("none") && store.instance(id)?.frida?.running == false,
              out.trimmingCharacters(in: .whitespacesAndNewlines))
        if ProcessInfo.processInfo.environment["TWINSIM_SELFTEST_KEEP_FRIDA"] == nil { _ = await store.deleteInstance(id) }
    }

    // MARK: Android performance (cores, hardware decode, fast input, frame rates)

    private func performance() async {
        log("== Android performance ==")
        if let display = store.component("android-display"), !display.isReady { await store.installComponent(display, accepting: []) }
        guard let apk = await store.importFiles([samples.appendingPathComponent("TouchProbe.apk")]).first else { check("import APK", false); return }
        var t = Date()
        await store.open(apk, forceDeviceView: true)
        guard let ws = store.instances.first(where: { $0.isAppWorkspace && $0.isAndroid }), ws.isReady else {
            check("open APK (device view)", false, store.notices.last?.message ?? ""); return
        }
        check("open APK (device view)", true, String(format: "%.1fs incl. first boot", Date().timeIntervalSince(t)))
        if let op = try? await store.perform(ws.id, "shell", body: ["argv": ["sh", "-c", "grep -c ^processor /proc/cpuinfo; head -1 /proc/meminfo"]], timeout: 60) {
            let out = (op.result?["stdout"] ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let cores = Int(out.first ?? "") ?? 0
            check("emulator CPU cores / RAM", cores >= 4, "cores \(cores), \(out.dropFirst().first ?? "")")
        }
        guard await waitUntil(15, { store.screenSession(ws.id) != nil }), let session = store.screenSession(ws.id) else {
            check("device window", false); return
        }
        _ = await waitUntil(30) { session.source == .video && session.stats.decodedFrames > 0 && session.hardwareDecoding != nil }
        check("device view: hardware decoding", session.hardwareDecoding == true, "\(session.hardwareDecoding.map { $0 ? "hardware" : "software" } ?? "unknown")")
        _ = await waitUntil(20) { session.liveInput }
        check("device view: fast input channel", session.liveInput, "\(session.control?.phase ?? .closed)")
        guard let size = session.guestSize else { return }

        // 10 taps through the control channel vs 3 through adb (old path).
        _ = try? await store.perform(ws.id, "shell", body: ["argv": ["logcat", "-c"]], timeout: 30)
        var expected: [CGPoint] = []
        t = Date()
        for i in 0..<10 {
            let p = CGPoint(x: 0.15 + 0.07 * Double(i), y: 0.35 + 0.04 * Double(i))
            if let g = session.guestPoint(normalized: p) { expected.append(g) }
            session.tap(normalized: p)
            try? await Task.sleep(for: .milliseconds(80))
        }
        let sendTime = Date().timeIntervalSince(t)
        _ = await waitUntil(10) { false }   // give the app time to log
        let taps = await touchLog(ws.id)
        let matched = expected.count == 10 && taps.count >= 10 && zip(expected, taps.suffix(10)).allSatisfy { abs($0.x - $1.x) <= 2 && abs($0.y - $1.y) <= 2 }
        check("10 fast taps land exactly", matched, String(format: "sent in %.2fs, app saw %d taps", sendTime, taps.count))
        t = Date()
        for i in 0..<3 {
            let g = CGPoint(x: Int(size.width * 0.5), y: Int(size.height * (0.4 + 0.1 * Double(i))))
            _ = try? await store.perform(ws.id, "tap", body: ["x": Int(g.x), "y": Int(g.y)], timeout: 60)
        }
        let adbPerTap = Date().timeIntervalSince(t) / 3
        check("adb tap path (comparison)", true, String(format: "%.0f ms per tap via adb vs ~40 ms (finger hold) via control", adbPerTap * 1000))

        // Live drag in the device view: continuous move events, frame rate.
        var before = session.stats.decodedFrames
        var start = Date()
        _ = session.liveTouch(.down, normalized: CGPoint(x: 0.2, y: 0.3))
        for i in 0..<90 {
            _ = session.liveTouch(.move, normalized: CGPoint(x: 0.2 + 0.6 * Double(i) / 90, y: 0.3 + 0.4 * Double(i) / 90))
            try? await Task.sleep(for: .milliseconds(16))
        }
        _ = session.liveTouch(.up, normalized: CGPoint(x: 0.8, y: 0.7))
        try? await Task.sleep(for: .milliseconds(200))
        var rate = Double(session.stats.decodedFrames - before) / Date().timeIntervalSince(start)
        check("device view frame rate during drag", rate >= 25, String(format: "%.0f fps (%@)", rate, fmt(session.contentSize)))
        for window in NSApp.windows where window.title.contains("TouchProbe") || window.title.contains("应用工作区") { window.close() }
        try? await Task.sleep(for: .seconds(2))

        // App window frame rate at the default density (balanced) and at Retina density.
        for density in [AppWindowSession.density] {
            t = Date()
            await store.open(apk)
            guard await waitUntil(20, { store.appWindow(apk.id)?.frames ?? 0 > 0 }), let app = store.appWindow(apk.id), let frame = app.frameSize else {
                check("app window", false); return
            }
            _ = await waitUntil(5) { app.hardwareDecoding != nil }
            check("app window: hardware decoding", app.hardwareDecoding == true, String(format: "first frame %.1fs", Date().timeIntervalSince(t)))
            before = app.frames
            start = Date()
            app.touch(.down, at: CGPoint(x: frame.width * 0.2, y: frame.height * 0.3))
            for i in 0..<90 {
                app.touch(.move, at: CGPoint(x: frame.width * (0.2 + 0.6 * Double(i) / 90), y: frame.height * (0.3 + 0.4 * Double(i) / 90)))
                try? await Task.sleep(for: .milliseconds(16))
            }
            app.touch(.up, at: CGPoint(x: frame.width * 0.8, y: frame.height * 0.7))
            try? await Task.sleep(for: .milliseconds(200))
            rate = Double(app.frames - before) / Date().timeIntervalSince(start)
            check("app window frame rate during drag", rate >= 30, String(format: "%.0f fps at density %.1f (%@)", rate, density, fmt(frame)))
            for window in NSApp.windows where window.title.contains("TouchProbe") { window.close() }
            try? await Task.sleep(for: .seconds(2))
        }
        _ = try? await store.perform(ws.id, "stop", timeout: 180)
    }

    // MARK: Android app windows (virtual display, scrcpy control)

    private func appWindow() async {
        log("== Android app window ==")
        if let display = store.component("android-display"), !display.isReady { await store.installComponent(display, accepting: []) }
        guard let apk = await store.importFiles([samples.appendingPathComponent("TouchProbe.apk")]).first else {
            check("import APK", false); return
        }
        var t = Date()
        await store.open(apk)
        guard let ws = store.instances.first(where: { $0.isAppWorkspace && $0.isAndroid }), ws.isReady else {
            check("open APK in app window", false, store.notices.last?.message ?? ""); return
        }
        guard await waitUntil(15, { store.appWindow(apk.id) != nil }), let session = store.appWindow(apk.id) else {
            check("app window opened", false, "windows: " + NSApp.windows.map { "\($0.title)|\($0.identifier?.rawValue ?? "-")|\($0.isVisible)" }.joined(separator: "; ")
                  + " notices: " + store.notices.map(\.message).joined(separator: " / "))
            return
        }
        let running = await waitUntil(30) { session.phase == .running && session.frames > 0 }
        check("app window shows only the app (virtual display)", running,
              String(format: "%.1fs to first frame, phase \(session.phase)", Date().timeIntervalSince(t)))
        guard running, let size = session.frameSize else { return }
        check("display = window pixels (1 dp = 1 pt, no downscale)",
              abs(size.width - session.requestedSize.width) <= 2 && abs(size.height - session.requestedSize.height) <= 2,
              "frame \(fmt(size)), requested \(fmt(session.requestedSize))")
        try? await Task.sleep(for: .seconds(2))
        if let buffer = session.lastFrame {
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = CIContext().createCGImage(image, from: image.extent) { savePNG(cg, "30-app-window") }
        }
        // Touch through the control channel; the app logs coordinates on its own display.
        _ = try? await store.perform(ws.id, "shell", body: ["argv": ["logcat", "-c"]], timeout: 30)
        let center = CGPoint(x: (size.width / 2).rounded(), y: (size.height * 0.6).rounded())
        t = Date()
        session.touch(.down, at: center)
        try? await Task.sleep(for: .milliseconds(60))
        session.touch(.up, at: center)
        try? await Task.sleep(for: .seconds(1.5))
        let taps = await touchLog(ws.id)
        check("touch lands at window coordinates", taps.last.map { abs($0.x - center.x) <= 2 && abs($0.y - center.y) <= 2 } ?? false,
              "sent \(fmt(center)), app saw \(taps.suffix(1).map(fmt))")
        // Continuous drag: frames keep up (interactive frame rate).
        let before = session.frames
        let start = Date()
        session.touch(.down, at: CGPoint(x: size.width * 0.2, y: size.height * 0.3))
        for i in 0..<60 {
            session.touch(.move, at: CGPoint(x: size.width * (0.2 + 0.6 * Double(i) / 60), y: size.height * (0.3 + 0.4 * Double(i) / 60)))
            try? await Task.sleep(for: .milliseconds(16))
        }
        session.touch(.up, at: CGPoint(x: size.width * 0.8, y: size.height * 0.7))
        try? await Task.sleep(for: .milliseconds(300))
        let rate = Double(session.frames - before) / Date().timeIntervalSince(start)
        check("interactive frame rate during drag", rate >= 20, String(format: "%.0f fps at density %.1f", rate, AppWindowSession.density))
        // Resize: the virtual display follows the window and the app reflows.
        var sizes: [String] = []
        var resized = false
        for target in [CGSize(width: 700, height: 1000), CGSize(width: 1100, height: 1300)] {
            session.resize(pixels: target)
            let ok = await waitUntil(8) { session.frameSize.map { abs($0.width - target.width) <= 2 && abs($0.height - target.height) <= 2 } ?? false }
            sizes.append("\(fmt(target))->\(fmt(session.frameSize))")
            resized = resized || ok
        }
        check("resize window -> display resized", resized, sizes.joined(separator: ", "))
        if let buffer = session.lastFrame {
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = CIContext().createCGImage(image, from: image.extent) { savePNG(cg, "31-app-window-resized") }
        }
        // Close and reopen: a new display, the app starts again.
        for window in NSApp.windows where window.title.contains("TouchProbe") { window.close() }
        try? await Task.sleep(for: .seconds(2))
        t = Date()
        await store.open(apk)
        let again = await waitUntil(30) { (store.appWindow(apk.id).map { $0 !== session && $0.frames > 0 }) ?? false }
        check("close + reopen app window", again, String(format: "%.1fs", Date().timeIntervalSince(t)))
        for window in NSApp.windows where window.title.contains("TouchProbe") { window.close() }
        _ = try? await store.perform(ws.id, "stop", timeout: 180)
    }

    // MARK: App library deletion + D3DMetal consent

    private func library() async {
        log("== App library ==")
        // D3DMetal: Apple's license is fetched, read from the PDF and must be accepted first.
        if let c = store.component("windows-d3dmetal") {
            let text = c.licenses?.first?.text ?? ""
            check("D3DMetal component asks for Apple license consent", c.status == "needsConsent" && text.count > 5000,
                  "\(c.status), license \(text.count) chars, id \(c.licenses?.first?.id ?? "-")")
        } else {
            check("D3DMetal component listed", false)
        }
        // A header-only Windows executable (never executed) to exercise import + delete of .exe.
        let exe = out.appendingPathComponent("library-sample.exe")
        var pe = Data(count: 0x200)
        pe[0] = 0x4d; pe[1] = 0x5a; pe[0x3c] = 0x80; pe[0x80] = 0x50; pe[0x81] = 0x45; pe[0x84] = 0x4c; pe[0x85] = 0x01
        try? pe.write(to: exe)
        let imported = await store.importFiles([samples.appendingPathComponent("TouchProbe.apk"),
                                                samples.appendingPathComponent("TouchProbe.app"), exe])
        guard imported.count == 3, let apk = imported.first(where: { $0.kind == "apk" }),
              let sim = imported.first(where: { $0.kind == "simulatorApp" }), let win = imported.first(where: { $0.isWindows }) else {
            check("import apk + .app + .exe", false, store.notices.last?.message ?? ""); return
        }
        check("import apk + .app + .exe", true, imported.map { "\($0.kind)" }.joined(separator: ", "))
        let artifactsDir = URL(fileURLWithPath: store.dataDirectory).appendingPathComponent("artifacts")

        await store.open(apk)
        guard let ws = store.instances.first(where: { $0.isAndroid && $0.isAppWorkspace }), ws.isReady else {
            check("open APK before delete", false, store.notices.last?.message ?? ""); return
        }
        let before = try? await store.perform(ws.id, "shell", body: ["argv": ["sh", "-c", "pm path org.twinsim.touchprobe"]], timeout: 60)
        check("APK installed on device", (before?.result?["stdout"] ?? "").contains("package:"))
        var t = Date()
        let deleted = await store.deleteArtifact(apk, uninstall: true)
        let after = try? await store.perform(ws.id, "shell", body: ["argv": ["sh", "-c", "pm path org.twinsim.touchprobe; echo done"]], timeout: 60)
        check("delete APK + uninstall from running device", deleted && store.artifact(apk.id) == nil
              && !(after?.result?["stdout"] ?? "package:").contains("package:"),
              String(format: "%.1fs", Date().timeIntervalSince(t)))
        check("stored APK copy removed", !FileManager.default.fileExists(atPath: artifactsDir.appendingPathComponent(apk.id.uuidString).path))

        t = Date()
        check("delete Simulator .app (library only)", await store.deleteArtifact(sim, uninstall: false) && store.artifact(sim.id) == nil
              && !FileManager.default.fileExists(atPath: artifactsDir.appendingPathComponent(sim.id.uuidString).path),
              String(format: "%.1fs", Date().timeIntervalSince(t)))
        check("delete Windows .exe", await store.deleteArtifact(win, uninstall: true) && store.artifact(win.id) == nil
              && !FileManager.default.fileExists(atPath: artifactsDir.appendingPathComponent(win.id.uuidString).path))
        await store.reloadArtifacts()
        check("library empty after deletes (server state)", store.artifacts.isEmpty, "\(store.artifacts.count) left")
        let again = await store.importFiles([samples.appendingPathComponent("TouchProbe.apk")])
        check("re-import after delete", again.first?.kind == "apk" && again.first?.id != apk.id)
        _ = try? await store.perform(ws.id, "stop", timeout: 180)
    }

    // MARK: Windows (Wine)

    private func windowsPlatform() async {
        log("== Windows (Wine) ==")
        for id in ["windows-wine", "windows-dxvk"] {
            if let c = store.component(id), !c.isReady {
                let t = Date()
                log("installing \(id) (\(c.status))")
                await store.installComponent(c, accepting: [])
                check("component \(id) installed", store.component(id)?.isReady == true, String(format: "%.0fs", Date().timeIntervalSince(t)))
            } else {
                check("component \(id) installed", store.component(id)?.isReady == true, store.component(id)?.status ?? "missing")
            }
        }
        guard store.component("windows-wine")?.isReady == true else { return }
        // Real Windows programs shipped with Wine: 32-bit Minesweeper and 64-bit Notepad.
        let lib = URL(fileURLWithPath: store.dataDirectory)
            .appendingPathComponent("runtime/wine-staging-11.21/Wine Staging.app/Contents/Resources/wine/lib/wine")
        let samples = out.appendingPathComponent("samples")
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let mine = samples.appendingPathComponent("winemine32.exe"), pad = samples.appendingPathComponent("notepad64.exe")
        try? FileManager.default.removeItem(at: mine); try? FileManager.default.removeItem(at: pad)
        try? FileManager.default.copyItem(at: lib.appendingPathComponent("i386-windows/winemine.exe"), to: mine)
        try? FileManager.default.copyItem(at: lib.appendingPathComponent("x86_64-windows/notepad.exe"), to: pad)
        let imported = await store.importFiles([mine, pad])
        guard imported.count == 2 else { check("import .exe (x86 + x64)", false, "\(store.notices.last?.message ?? "")"); return }
        check("import .exe (x86 + x64)", imported.allSatisfy { $0.kind == "windowsExe" }, imported.map(\.bundleId).joined(separator: ", "))

        var t = Date()
        await store.open(imported[0])
        guard let ws = store.instances.first(where: { $0.isWindows && $0.isAppWorkspace }), ws.isReady else {
            check("open 32-bit program (creates Wine prefix)", false, store.notices.last?.message ?? ""); return
        }
        check("open 32-bit program (creates Wine prefix)", true, String(format: "%.1fs", Date().timeIntervalSince(t)))
        check("no TwinSim mirror window for Windows apps", store.screenSession(ws.id) == nil)
        var shot: Data?
        var lastError = ""
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, shot == nil {
            do { shot = try await store.client?.screenshot(ws.id) } catch { lastError = error.localizedDescription; try? await Task.sleep(for: .seconds(1)) }
        }
        if let shot, let image = NSImage(data: shot) {
            try? shot.write(to: out.appendingPathComponent("20-windows-winemine.png"))
            check("program window on screen + captured", true, "\(Int(image.size.width))×\(Int(image.size.height)) pt image")
        } else {
            check("program window on screen + captured", false, lastError)
        }

        if let op = try? await store.perform(ws.id, "shell", body: ["argv": ["cmd", "/c", "ver & echo %PROCESSOR_ARCHITECTURE% & echo %WINEDLLPATH_PREPEND%"]], timeout: 120) {
            let outText = (op.result?["stdout"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            check("cmd shell", op.result?["exitCode"] == "0" && outText.contains("Windows"), outText.replacingOccurrences(of: "\n", with: " | "))
        } else { check("cmd shell", false, store.notices.last?.message ?? "") }

        let note = FileManager.default.temporaryDirectory.appendingPathComponent("twinsim-wine-\(UUID().uuidString).txt")
        try? "hello from macOS".write(to: note, atomically: true, encoding: .utf8)
        let pushed = (try? await store.perform(ws.id, "guest-push", body: ["localPath": note.path, "remotePath": #"C:\users\Public\twinsim.txt"#])) != nil
        let pulled = try? await store.client?.guestFile(ws.id, path: #"C:\users\Public\twinsim.txt"#)
        check("file push/pull via C:\\", pushed && pulled.map { String(decoding: $0, as: UTF8.self) } == "hello from macOS")

        t = Date()
        await store.open(imported[1])
        let reused = store.instances.filter { $0.isWindows && $0.isAppWorkspace }.count == 1
        check("open 64-bit program on the same prefix", reused && store.instance(ws.id)?.isReady == true, String(format: "%.1fs", Date().timeIntervalSince(t)))
        try? await Task.sleep(for: .seconds(3))
        if store.instance(ws.id)?.can("input") == true {
            let before = try? await store.client?.screenshot(ws.id)
            let typed = (try? await store.perform(ws.id, "text", body: ["value": "TwinSim on Wine"], timeout: 60)) != nil
            try? await Task.sleep(for: .seconds(1))
            let after = try? await store.client?.screenshot(ws.id)
            if let after { try? after.write(to: out.appendingPathComponent("21-windows-notepad-typed.png")) }
            check("type into Notepad (CGEvent)", typed && before != after, "screenshot changed: \(before != after)")
        } else {
            check("input needs Accessibility permission", true, store.instance(ws.id)?.capability("input")?.reasonCode ?? "")
        }

        _ = try? await store.perform(ws.id, "dxvk", body: ["value": "on"], timeout: 60)
        if let op = try? await store.perform(ws.id, "shell", body: ["argv": ["cmd", "/c", "echo %WINEDLLPATH_PREPEND%|%DXVK_ASYNC%"]], timeout: 60) {
            let text = (op.result?["stdout"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            check("DXVK enabled for new programs", text.contains("dxvk") && text.hasSuffix("|1"), text)
        }
        _ = try? await store.perform(ws.id, "display", body: ["value": "standard"], timeout: 120)
        if let op = try? await store.perform(ws.id, "shell", body: ["argv": ["cmd", "/c", #"reg query "HKCU\Software\Wine\Mac Driver" /v RetinaMode"#]], timeout: 60) {
            check("display mode switch (registry)", (op.result?["stdout"] ?? "").contains("n"), (op.result?["stdout"] ?? "").replacingOccurrences(of: "\n", with: " "))
        }
        _ = try? await store.perform(ws.id, "display", body: ["value": "retina"], timeout: 120)
        _ = try? await store.perform(ws.id, "wine-tool", body: ["value": "winecfg"], timeout: 60)

        t = Date()
        let stopped = (try? await store.perform(ws.id, "stop", timeout: 120)) != nil
        await store.refreshInstance(ws.id)
        check("stop Windows device (all programs closed)", stopped && store.instance(ws.id)?.state == "stopped", String(format: "%.1fs", Date().timeIntervalSince(t)))
        let prefix = URL(fileURLWithPath: store.dataDirectory).appendingPathComponent("wine/prefixes/twinsim-\(ws.id.uuidString.lowercased())")
        check("delete Windows device removes prefix", await store.deleteInstance(ws.id) && !FileManager.default.fileExists(atPath: prefix.path))
    }

    // MARK: Data directory move + delete

    private func dataMove() async {
        log("== Data location ==")
        let env = ProcessInfo.processInfo.environment
        guard let destination = env["TWINSIM_SELF_TEST_MOVE_TO"] else { check("data move target", false, "TWINSIM_SELF_TEST_MOVE_TO unset"); return }
        let source = store.dataDirectory
        check("starts from custom data directory", !store.dataDirectoryIsDefault && !store.dataDirectoryLockedByEnvironment, source)
        let before = Set(store.instances.map(\.id))
        log("devices before: " + store.instances.map { "\($0.displayName)/\($0.profileId)/\($0.state)" }.joined(separator: ", "))
        guard let android = store.instances.first(where: \.isAndroid), let ios = store.instances.first(where: \.isSimulator) else {
            check("seeded devices present", false); return
        }
        await store.run(android.id, "start")
        check("android running before move", store.instance(android.id)?.isReady == true)

        let bytes = DataLocation.size(of: source)
        do { try DataLocation.validate(destination: destination, current: source, requiredBytes: bytes); check("destination validated", true, "\(Labels.bytes(bytes)) → \(destination)") }
        catch { check("destination validated", false, error.localizedDescription); return }
        if let v = DataLocation.volume(of: destination) { log("destination volume: \(v.name) \(v.format) removable/external=\(v.isRemovable)") }
        var t = Date()
        var maxProgress = 0.0
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if case .migrating(let p, _) = store.connection { maxProgress = max(maxProgress, p) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await store.moveData(to: destination, deleteOld: true)
        watcher.cancel()
        check("move completed and backend restarted", store.isConnected && store.dataDirectory == destination,
              String(format: "%.1fs, progress reached %.0f%%", Date().timeIntervalSince(t), maxProgress * 100))
        check("old location deleted", !FileManager.default.fileExists(atPath: source))
        check("devices preserved", Set(store.instances.map(\.id)) == before, "\(store.instances.count) devices")
        let avdDir = destination + "/jidr/data/avd"
        let inis = (try? FileManager.default.contentsOfDirectory(atPath: avdDir).filter { $0.hasSuffix(".ini") }) ?? []
        let rewritten = inis.allSatisfy { ((try? String(contentsOfFile: avdDir + "/" + $0, encoding: .utf8)) ?? "").contains("path=" + destination) }
        check("AVD paths rewritten", !inis.isEmpty && rewritten, inis.joined(separator: ","))
        check("android stopped for the move", store.instance(android.id)?.state == "stopped")

        // The CLI finds the app through the data directory chosen in Settings.
        if let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/twinsim") as URL?,
           FileManager.default.isExecutableFile(atPath: cli.path) {
            let out = await Task.detached { () -> String in
                let p = Process(); p.executableURL = cli; p.arguments = ["status"]
                var e = ProcessInfo.processInfo.environment; e["TWINSIM_HOME"] = nil; e["TWINSIM_NO_LAUNCH"] = "1"; p.environment = e
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                try? p.run(); p.waitUntilExit()
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            }.value
            check("twinsim CLI connects after move", out.contains(destination), out.split(separator: "\n").first(where: { $0.contains("dataDirectory") }).map(String.init) ?? out.prefix(200).description)
        }

        for target in [android, ios] {
            t = Date()
            await store.run(target.id, "start")
            let ok = store.instance(target.id)?.isReady == true
            var detail = String(format: "%.1fs", Date().timeIntervalSince(t))
            if ok, let data = try? await store.client?.screenshot(target.id), let size = NSImage(data: data)?.size { detail += " screenshot \(Int(size.width))×\(Int(size.height))" }
            check("\(target.isAndroid ? "android" : "ios") boots from new location", ok, detail)
        }

        // Unplugged drive: a missing custom directory must not start the backend.
        BackendSettings.dataDirectory = "/Volumes/TwinSimMissingDisk/TwinSim"
        await store.restartBackend()
        check("missing drive detected", store.dataDirectoryMissing && !store.isConnected,
              { if case .failed(let m, _) = store.connection { return m }; return "\(store.connection)" }())
        check("no folder created for missing drive", !FileManager.default.fileExists(atPath: "/Volumes/TwinSimMissingDisk"))
        BackendSettings.dataDirectory = destination
        await store.restartBackend()
        _ = await waitUntil(60) { store.instance(android.id)?.isReady == true }
        check("reconnected after drive returns", store.isConnected, "android \(store.instance(android.id)?.state ?? "?")")

        // Delete: a running Android device and a running Simulator device.
        let avdName = "twinsim-" + android.id.uuidString.lowercased()
        t = Date()
        check("delete running android device", await store.deleteInstance(android.id), String(format: "%.1fs", Date().timeIntervalSince(t)))
        check("android removed from list and disk", store.instance(android.id) == nil
              && !FileManager.default.fileExists(atPath: avdDir + "/\(avdName).avd") && !FileManager.default.fileExists(atPath: avdDir + "/\(avdName).ini"))
        let simDevices = (try? FileManager.default.contentsOfDirectory(atPath: destination + "/simulators").filter { UUID(uuidString: $0) != nil }) ?? []
        t = Date()
        check("delete running ios device", await store.deleteInstance(ios.id), String(format: "%.1fs", Date().timeIntervalSince(t)))
        let simAfter = (try? FileManager.default.contentsOfDirectory(atPath: destination + "/simulators").filter { UUID(uuidString: $0) != nil }) ?? []
        check("simulator device removed from disk", store.instance(ios.id) == nil && simAfter.count == simDevices.count - 1,
              "\(simDevices.count) → \(simAfter.count) device folders")
        await store.refreshInstance(android.id)
        check("deleted devices stay deleted after resync", store.instance(android.id) == nil && store.instance(ios.id) == nil)
    }

    // MARK: Devices page (full devices)

    private func devices() async {
        log("== Devices page ==")
        let only = ProcessInfo.processInfo.environment["TWINSIM_SELF_TEST_DEVICE_ENGINES"]
        for (engine, profile, name) in [("android-emulator", "android-google-apis", "E2E Android 研究机"),
                                        ("ios-simulator", "ios-development", "E2E iPhone")]
            where only == nil || only!.contains(engine) {
            var t = Date()
            guard let id = await store.createInstance(engineId: engine, profileId: profile, name: name, externalName: nil) else {
                check("create \(profile)", false, store.notices.last?.message ?? ""); continue
            }
            check("create \(profile)", store.instance(id)?.state == "stopped", String(format: "%.1fs", Date().timeIntervalSince(t)))
            t = Date()
            await store.run(id, "start")
            await store.refreshInstance(id)
            guard check("start \(profile)", store.instance(id)?.isReady == true, String(format: "%.1fs", Date().timeIntervalSince(t))) else { continue }
            store.openWindowAction?(value: ScreenTarget(instanceId: id))
            guard await waitUntil(15, { store.screenSession(id) != nil }), let session = store.screenSession(id) else {
                check("device window \(profile)", false); continue
            }
            let shown = await waitUntil(60) { session.contentSize != nil && session.totalFrames > 0 }
            check("device window \(profile)", shown, "\(session.source) \(fmt(session.contentSize))")
            let caps = store.instance(id)?.capabilities ?? [:]
            log("capabilities: " + caps.keys.sorted().map { "\($0)=\(caps[$0]!.availability)" }.joined(separator: " "))
            if engine == "android-emulator" {
                saveFrame(session, "10-device-android")
                if let op = await store.run(id, "root") { check("tools: guest root", op.result?["uid"] == "0", "uid \(op.result?["uid"] ?? "?")") }
                else { check("tools: guest root", false, store.notices.last?.message ?? "") }
                let shell = await store.run(id, "shell", body: ["argv": ["sh", "-c", "id -u; getprop ro.product.cpu.abi"]])
                check("tools: guest shell", shell?.result?["exitCode"] == "0",
                      (shell?.result?["stdout"] ?? "").replacingOccurrences(of: "\n", with: " "))
                let fwd = await store.run(id, "forward", body: ["guestPort": 27042])
                let port = fwd?.result?["localPort"].flatMap(Int.init)
                check("tools: port forward", port != nil, "127.0.0.1:\(port ?? 0) -> 27042")
                if let port { await store.run(id, "unforward", body: ["localPort": port]) }
            } else if let image = await session.captureScreenshot(updateDisplay: false) {
                savePNG(image, "11-device-ios")
            }
            var logs = "", logError = ""
            for attempt in 1...2 where logs.isEmpty {
                let t0 = Date()
                do { logs = try await store.client?.logs(id, lines: 50) ?? "" }
                catch { logError = "attempt \(attempt) after \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(error.localizedDescription)"; log(logError) }
            }
            check("device logs \(profile)", !logs.isEmpty, logs.isEmpty ? logError : "\(logs.split(separator: "\n").count) lines")
            t = Date()
            await store.run(id, "stop")
            await store.refreshInstance(id)
            check("stop \(profile)", store.instance(id)?.state == "stopped", String(format: "%.1fs", Date().timeIntervalSince(t)))
            closeWindows(title: name)
        }
    }

    // MARK: Device IPA

    private func ipa() async {
        log("== Device IPA ==")
        guard let ipa = await store.importFiles([samples.appendingPathComponent("TouchProbeDevice.ipa")]).first else {
            check("IPA import", false); return
        }
        check("IPA import (classified as device IPA)", ipa.kind == "ipa", ipa.bundleId)
        let vphone = store.component("ios-vphone")
        log("ios-vphone: \(vphone?.status ?? "?") \(vphone?.reasonCode ?? "")")
        let blocker = store.launchBlocker(for: ipa)
        check("host blocker detected before launch", blocker != nil, blocker?.code ?? "")
        let before = Set(store.notices.map(\.id))
        await store.open(ipa)
        let notice = store.notices.last { !before.contains($0.id) }
        check("blocking prompt shown", notice != nil && notice?.code == vphone?.reasonCode && notice?.link != nil,
              "\(notice?.title ?? ""): \(notice?.message ?? "") link \(notice?.link?.absoluteString ?? "-")")
        await snapshotMain("08-ipa-blocked", select: .apps)
        // The backend path reports the same reason when a launch is forced.
        do {
            let accepted = try await store.submit { client, key in
                try await client.launch(ipa.id, instanceId: nil, profileId: nil, key: key)
            }
            _ = try await store.wait(accepted.operationId, timeout: 120)
            check("backend launch blocked", false, "launch unexpectedly succeeded")
        } catch let failure as OperationFailure {
            check("backend launch blocked", failure.body.code == vphone?.reasonCode, failure.body.code)
        } catch {
            check("backend launch blocked", false, error.localizedDescription)
        }
    }

    // MARK: Output

    private func fmt(_ size: CGSize?) -> String { size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "nil" }
    private func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }

    private func saveFrame(_ session: ScreenSession, _ name: String) {
        guard let buffer = session.lastFrame else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return }
        savePNG(cg, name)
    }

    private func savePNG(_ image: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    private func snapshotMain(_ name: String, select: SidebarItem) async {
        NotificationCenter.default.post(name: .twinsimSelect, object: select.rawValue)
        try? await Task.sleep(for: .seconds(1.5))
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "TwinSim" }) {
            snapshot(window, name)
        }
    }

    private func snapshotWindow(containing title: String, _ name: String) {
        if let window = NSApp.windows.first(where: { $0.title.contains(title) && $0.isVisible }) { snapshot(window, name) }
    }

    private func snapshot(_ window: NSWindow, _ name: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    private func renderOffscreen<V: View>(_ view: V, size: CGSize, _ name: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    private func closeWindows(title: String) {
        for window in NSApp.windows where window.isVisible && window.title.contains(title) { window.close() }
    }

    private func closeWindows() {
        for window in NSApp.windows where window.isVisible && window.title != "TwinSim" && window.styleMask.contains(.closable) {
            if window.identifier?.rawValue.contains("screen") == true || window.title.contains("TouchProbe") { window.close() }
        }
    }

    private func finish() {
        let passed = checks.filter(\.1).count
        var md = "# TwinSim 前端联调报告\n\n"
        md += "- 时间: \(ISO8601DateFormatter().string(from: started))\n"
        md += "- TWINSIM_HOME: `\(ProcessInfo.processInfo.environment["TWINSIM_HOME"] ?? "(default)")`\n"
        md += "- Helper: `\(store.helperPath ?? "?")`\n"
        md += "- 结果: \(passed)/\(checks.count) 通过\n\n| 检查 | 结果 | 说明 |\n| --- | --- | --- |\n"
        for (name, ok, detail) in checks {
            md += "| \(name) | \(ok ? "通过" : "**失败**") | \(detail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")) |\n"
        }
        md += "\n## 日志\n\n```\n" + lines.joined(separator: "\n") + "\n```\n"
        try? md.write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        log("Self-test finished: \(passed)/\(checks.count) passed")
        if ProcessInfo.processInfo.environment["TWINSIM_SELF_TEST_KEEP_OPEN"] == nil {
            Task {
                // Stop what the test started so quitting never waits on the "devices running" prompt.
                await store.stopAllRunning(timeout: 180)
                try? await Task.sleep(for: .seconds(2))
                NSApp.terminate(nil)
            }
        }
    }
}
