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
        snapshotMain("01-components", select: .components)

        if platforms.contains("android") { await android() }
        if platforms.contains("ios") { await ios() }
        if platforms.contains("ipa") { await ipa() }
        if platforms.contains("device") { await devices() }
        snapshotMain("09-devices", select: .devices)
        renderOffscreen(AISettingsView().environment(store), size: CGSize(width: 640, height: 1000), "12-ai-settings")
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
        snapshotMain("02-apps", select: .apps)

        var t = Date()
        await store.open(apk)
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
        await store.open(apk)
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
        snapshotMain("08-ipa-blocked", select: .apps)
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

    private func snapshotMain(_ name: String, select: SidebarItem) {
        NotificationCenter.default.post(name: .twinsimSelect, object: select.rawValue)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: { $0.title == "TwinSim" || $0.identifier?.rawValue.hasPrefix("main") == true }) {
                self.snapshot(window, name)
            }
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
                try? await Task.sleep(for: .seconds(3))
                NSApp.terminate(nil)
            }
        }
    }
}
