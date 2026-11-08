import SwiftUI

struct ComponentsView: View {
    @Environment(AppStore.self) private var store
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("组件").font(.largeTitle.bold())
                        Text("运行设备和应用所需的引擎与镜像。按需安装，安装进度会实时显示。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { refreshing = true; await store.reloadComponents(); refreshing = false }
                    } label: {
                        if refreshing { ProgressView().controlSize(.small) } else { Label("重新检查", systemImage: "arrow.clockwise") }
                    }
                }
                if store.components.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(store.components) { component in
                    ComponentCard(component: component)
                }
            }
            .padding(24)
        }
    }
}

struct ComponentCard: View {
    @Environment(AppStore.self) private var store
    let component: Component
    @State private var showLicenses = false
    @State private var accepted = false
    @State private var rechecking = false

    private var operation: BackendOperation? { store.latestOperation(forComponent: component.id) }
    private var running: Bool { operation.map { !$0.isTerminal } ?? false }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Labels.component(component.id)).font(.headline)
                        Text(Labels.componentDetail(component.id)).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    badge
                }
                metadata
                if running, let operation {
                    progress(operation)
                } else if let operation, operation.state == "failed", let error = operation.error, !component.isReady {
                    failure(error)
                }
                switch component.status {
                case "needsConsent": consent
                case "downloadable": installButton(title: "安装", licenses: [])
                case "externalSetup": externalSetup
                case "blocked":
                    if let reason = component.reasonCode {
                        Label(Labels.reason(reason) ?? reason, systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                    }
                default: EmptyView()
                }
            }
            .padding(6)
        }
    }

    private var badge: some View {
        let color: Color = switch component.status {
        case "ready": .green
        case "needsConsent", "downloadable": .blue
        case "externalSetup": .orange
        default: .secondary
        }
        return StatusBadge(text: running ? "安装中" : Labels.componentStatus(component.status), color: running ? .orange : color)
    }

    @ViewBuilder private var metadata: some View {
        let items: [(String, String)] = [
            component.version.map { ("版本", $0) },
            component.downloadBytes.map { ("下载", Labels.bytes($0)) },
            component.requiredFreeBytes.map { ("所需空间", Labels.bytes($0)) },
        ].compactMap { $0 }
        if !items.isEmpty || component.source != nil {
            HStack(spacing: 14) {
                ForEach(items, id: \.0) { item in
                    Text("\(item.0) \(item.1)").font(.caption).foregroundStyle(.secondary)
                }
                if let source = component.source, let url = URL(string: source) {
                    Link(destination: url) { Text("来源 \(url.host ?? source)").font(.caption) }
                        .help(source)
                }
            }
        }
    }

    private func progress(_ op: BackendOperation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = op.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(Labels.stage(op.stage) ?? (op.state == "queued" ? "排队中" : "进行中"))
                Spacer()
                if let received = op.receivedBytes {
                    Text("\(Labels.bytes(received)) / \(Labels.bytes(op.totalBytes))").monospacedDigit()
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func failure(_ error: APIErrorBody) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(Labels.reason(error.code) ?? error.message).fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
            Text("\(error.code)\(error.retryable ? " · 可重试" : "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private func installButton(title: String, licenses: [LicenseText]) -> some View {
        let failedBefore = operation?.state == "failed"
        return Button(failedBefore ? "重试" : title) {
            Task { await store.installComponent(component, accepting: licenses) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(running)
    }

    @ViewBuilder private var consent: some View {
        let licenses = component.licenses ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text("安装前需要阅读并接受以下 \(licenses.count) 份许可。提交时会附带每份许可原文的 SHA-256 指纹。")
                .font(.callout)
            DisclosureGroup(isExpanded: $showLicenses) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(licenses) { license in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(license.id).font(.subheadline.bold())
                                Spacer()
                                Text(license.sha256.prefix(16) + "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .help(license.sha256)
                            }
                            ScrollView {
                                Text(license.text).font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
                            }
                            .frame(height: 260)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(showLicenses ? "隐藏许可原文" : "查看许可原文").font(.callout)
            }
            Toggle("我已阅读并接受以上许可", isOn: $accepted)
                .disabled(!showLicenses && !accepted)
                .help(showLicenses ? "" : "请先展开并阅读许可原文")
            installButton(title: "接受并安装", licenses: licenses).disabled(!accepted || running)
        }
    }

    @ViewBuilder private var externalSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(Labels.reason(component.reasonCode) ?? "该组件需要在 TwinSim 之外完成配置。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange) }
            .font(.callout)
            if let code = component.reasonCode {
                Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if let source = component.source, let url = URL(string: source) {
                    Link(destination: url) { Label("打开上游配置说明", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(.bordered)
                }
                Button {
                    Task { rechecking = true; await store.reloadComponents(); rechecking = false }
                } label: {
                    if rechecking { ProgressView().controlSize(.small) } else { Text("配置完成，重新检查") }
                }
            }
        }
    }
}
