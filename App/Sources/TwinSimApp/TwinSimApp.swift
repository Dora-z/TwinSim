import AppKit
import SwiftUI

@main
struct TwinSimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("TwinSim", id: "main") {
            ContentView()
                .environment(delegate.store)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入应用…") { NotificationCenter.default.post(name: .twinsimImport, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandMenu("后端") {
                Button("重新启动后端") { Task { await delegate.store.restartBackend() } }
                Button("重新同步") { Task { await delegate.store.reloadAll() } }
                    .keyboardShortcut("r")
            }
        }

        WindowGroup("画面", id: "screen", for: ScreenTarget.self) { $target in
            if let target {
                ScreenWindow(target: target)
                    .environment(delegate.store)
            }
        }
        .defaultSize(width: 420, height: 860)
        .windowToolbarStyle(.unifiedCompact)

        Settings {
            TabView {
                SettingsView().tabItem { Label("通用", systemImage: "gearshape") }
                AISettingsView().frame(width: 640).tabItem { Label("AI 集成", systemImage: "sparkles") }
            }
            .environment(delegate.store)
        }
    }
}

extension Notification.Name {
    static let twinsimImport = Notification.Name("TwinSimImport")
    static let twinsimSelect = Notification.Name("TwinSimSelect")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    private var pendingOpens: [URL] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        SelfTest.startIfRequested(store: store)
        let bridge = AgentBridge(store: store)
        store.agentBridge = bridge
        if AgentBridge.isEnabled { bridge.start() }
        Task {
            await store.startBackend()
            await flushPendingOpens()
        }
    }

    /// Finder "Open With" / double-click on an APK or IPA: import, then open in single-app mode.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens.append(contentsOf: urls.filter(\.isFileURL))
        Task { await flushPendingOpens() }
    }

    private func flushPendingOpens() async {
        guard store.isConnected, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens.removeAll()
        await store.importAndOpen(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        let running = store.instances.filter { ["ready", "starting", "unknown"].contains($0.state) }
        guard store.isConnected, !running.isEmpty else {
            store.shutdown()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "有 \(running.count) 台设备仍在运行"
        alert.informativeText = "可以先逐台停机再退出，也可以让设备继续由引擎管理，下次打开 TwinSim 时重新核对状态。"
        alert.addButton(withTitle: "停机后退出")
        alert.addButton(withTitle: "保持运行并退出")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            terminating = true
            Task {
                await store.stopAllRunning()
                store.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            store.shutdown()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }
}
