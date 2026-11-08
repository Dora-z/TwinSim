import AppKit
import SwiftUI

struct LogsView: View {
    @Environment(AppStore.self) private var store
    let instanceId: UUID
    var compact: Bool
    @State private var text = ""
    @State private var lines = 200
    @State private var filter = ""
    @State private var follow = false
    @State private var loading = false
    @State private var error: String?

    private var instance: Instance? { store.instance(instanceId) }
    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !compact { Text("日志").font(.headline) }
                TextField("过滤", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Picker("", selection: $lines) {
                    ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) 行").tag($0) }
                }
                .labelsHidden().frame(width: 90)
                Toggle("自动刷新", isOn: $follow).toggleStyle(.checkbox)
                Spacer()
                Button { Task { await load() } } label: {
                    if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("刷新")
                .disabled(instance?.can("logs") != true)
                Button { copy() } label: { Image(systemName: "doc.on.doc") }.help("复制").disabled(text.isEmpty)
            }
            if instance?.can("logs") != true {
                Text("设备运行后可查看日志。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        Text(shown.isEmpty ? (error ?? "（无日志）") : shown)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(error == nil ? .primary : Color.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(6)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .padding(compact ? 0 : 12)
        .task(id: "\(instanceId)-\(lines)-\(follow)-\(instance?.state ?? "")") {
            guard instance?.can("logs") == true else { return }
            await load()
            while follow, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func load() async {
        guard let client = store.client else { return }
        loading = true
        defer { loading = false }
        do {
            text = try await client.logs(instanceId, lines: lines)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown, forType: .string)
    }
}
