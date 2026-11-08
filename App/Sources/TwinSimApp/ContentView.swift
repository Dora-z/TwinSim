import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case devices, apps, components, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .devices: "设备"
        case .apps: "应用"
        case .components: "组件"
        case .activity: "活动"
        }
    }
    var icon: String {
        switch self {
        case .devices: "iphone.and.arrow.forward"
        case .apps: "square.grid.2x2"
        case .components: "shippingbox"
        case .activity: "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarItem? = .devices
    @State private var promptedSetup = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach([SidebarItem.devices, .apps]) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                Section("准备") {
                    Label {
                        HStack {
                            Text(SidebarItem.components.title)
                            if store.needsSetup {
                                Spacer()
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            }
                        }
                    } icon: { Image(systemName: SidebarItem.components.icon) }
                    .tag(SidebarItem.components)
                    Label {
                        HStack {
                            Text(SidebarItem.activity.title)
                            let running = store.operations.values.filter { !$0.isTerminal && $0.action != "tap" && $0.action != "key" }.count
                            if running > 0 {
                                Spacer()
                                Text("\(running)").font(.caption).monospacedDigit()
                                    .padding(.horizontal, 6).background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                    } icon: { Image(systemName: SidebarItem.activity.icon) }
                    .tag(SidebarItem.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { ConnectionFooter().padding(10) }
        } detail: {
            Group {
                switch store.connection {
                case .connected:
                    switch selection ?? .devices {
                    case .devices: DevicesView()
                    case .apps: AppsView()
                    case .components: ComponentsView()
                    case .activity: ActivityView()
                    }
                case .failed(let message, let diagnostics):
                    BackendFailureView(message: message, diagnostics: diagnostics)
                case .idle, .starting:
                    ProgressView("正在启动后端…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .restarting(let attempt, let delay):
                    ProgressView("后端意外退出，\(delay) 秒后第 \(attempt) 次重启…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .bottom) { NoticeStack().padding() }
        }
        .onAppear { store.openWindowAction = openWindow }
        .onReceive(NotificationCenter.default.publisher(for: .twinsimSelect)) { note in
            if let raw = note.object as? String, let item = SidebarItem(rawValue: raw) { selection = item }
        }
        .onChange(of: store.components) { _, _ in
            if !promptedSetup, store.needsSetup {
                promptedSetup = true
                selection = .components
            }
        }
    }
}

struct ConnectionFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }
        .help(store.helperPath ?? "")
    }

    private var color: Color {
        switch store.connection {
        case .connected: store.eventsConnected ? .green : .yellow
        case .failed: .red
        default: .orange
        }
    }

    private var text: String {
        switch store.connection {
        case .connected: store.eventsConnected ? "后端已连接" : "后端已连接，事件流重连中"
        case .failed: "后端不可用"
        case .restarting: "后端重启中"
        default: "后端启动中"
        }
    }
}

struct BackendFailureView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let message: String
    let diagnostics: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("无法连接 TwinSim 后端", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.red)
            Text(message).textSelection(.enabled)
            if diagnostics.contains("already using this data directory") {
                Text("另一个 TwinSim 后端正在使用同一数据目录。请关闭其他 TwinSim 窗口或进程后重试。")
                    .foregroundStyle(.secondary)
            }
            if !diagnostics.isEmpty {
                GroupBox("后端输出") {
                    ScrollView {
                        Text(diagnostics).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(maxHeight: 220)
                }
            }
            HStack {
                Button("重新启动后端") { Task { await store.restartBackend() } }
                    .buttonStyle(.borderedProminent)
                Button("设置…") { openSettings() }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct NoticeStack: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.notices.suffix(3)) { notice in
                NoticeCard(notice: notice)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 560)
        .animation(.snappy, value: store.notices)
    }
}

struct NoticeCard: View {
    @Environment(AppStore.self) private var store
    let notice: UserNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.headline)
                Text(notice.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let link = notice.link {
                    Link("查看上游配置说明", destination: link).font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button { store.dismiss(notice) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
    }
}

/// Small coloured status capsule.
struct StatusBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    static func instance(_ state: String) -> StatusBadge {
        let color: Color = switch state {
        case "ready": .green
        case "failed": .red
        case "creating", "starting", "stopping": .orange
        case "unknown": .yellow
        default: .secondary
        }
        return StatusBadge(text: Labels.state(state), color: color)
    }
}
