import AppKit
import CoreVideo
import Observation
import SwiftUI

/// Identifies a native-style Android app window.
struct AppWindowTarget: Codable, Hashable, Sendable {
    var instanceId: UUID
    var artifactId: UUID
}

/// WebSocket session for one app window: H.264 frames in, scrcpy control messages out.
@MainActor @Observable
final class AppWindowSession {
    /// Rendering density of the app's virtual display in pixels per point. The emulator only has
    /// software video encoders, so fewer pixels means more frames: 2 = Retina-sharp, 1.5 = balanced
    /// (default), 1 = smoothest. Layout is unaffected (1 dp = 1 point at every level).
    static let qualityKey = "androidAppWindowQuality"
    static var density: CGFloat {
        if let value = ProcessInfo.processInfo.environment["TWINSIM_APPWINDOW_DENSITY"].flatMap(Double.init) { return CGFloat(value) }
        switch UserDefaults.standard.string(forKey: qualityKey) ?? "balanced" {
        case "sharp": return 2
        case "smooth": return 1
        default: return 1.5
        }
    }
    enum Phase: Equatable { case connecting, running, failed(String), closed }

    let target: AppWindowTarget
    let package: String
    private(set) var phase: Phase = .connecting
    private(set) var frameSize: CGSize?          // decoded frame pixels = virtual display pixels
    private(set) var frames = 0
    private(set) var fps: Double = 0
    private(set) var hardwareDecoding: Bool?
    var stalledWithoutFrames = false
    let renderer = VideoRenderer()

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var urlSession: URLSession?
    @ObservationIgnored nonisolated(unsafe) private let queue = DispatchQueue(label: "com.twinsim.appwindow", qos: .userInteractive)
    @ObservationIgnored nonisolated(unsafe) private let decoder = H264Decoder()
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var resizeWork: Task<Void, Never>?
    @ObservationIgnored private(set) var requestedSize: CGSize = .zero

    init(target: AppWindowTarget, package: String, store: AppStore) {
        self.target = target
        self.package = package
        self.store = store
        let renderer = self.renderer
        decoder.onFrame = { [weak self] buffer in
            renderer.show(buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frames += 1
                    self.frameCounter += 1
                    if self.phase == .connecting { self.phase = .running }
                }
            }
        }
        renderer.onSize = { [weak self] size in MainActor.assumeIsolated { self?.frameSize = size } }
    }

    /// Opens the virtual display at `pixels` (window size × backing scale), 1 dp = 1 point.
    func connect(pixels: CGSize, scale: CGFloat) {
        guard socket == nil, let client = store?.client else {
            if store?.client == nil { phase = .failed("后端未连接。") }
            return
        }
        requestedSize = pixels
        var components = URLComponents(url: client.url("/instances/\(target.instanceId.uuidString)/app-session"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.queryItems = [
            URLQueryItem(name: "package", value: package),
            URLQueryItem(name: "width", value: String(Int(pixels.width) & ~1)),
            URLQueryItem(name: "height", value: String(Int(pixels.height) & ~1)),
            URLQueryItem(name: "dpi", value: String(Int(160 * scale))),
            URLQueryItem(name: "fps", value: "60"),
        ]
        guard let url = components.url, var request = try? client.request("/health") else { return }
        request.url = url
        request.httpMethod = "GET"
        request.httpBody = nil
        request.timeoutInterval = 24 * 3600
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 24 * 3600
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        urlSession = session
        socket = task
        task.resume()
        tasks.append(Task { [weak self] in await self?.receiveLoop(task) })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.fps = Double(self.frameCounter)
                self.frameCounter = 0
                if self.frames > 0 { self.hardwareDecoding = self.queue.sync { self.decoder.usingHardware } }
            }
        })
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.frames == 0, self.phase != .closed else { return }
            self.stalledWithoutFrames = true
        })
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .data(let data):
                    queue.async { [weak self] in self?.ingest(data) }   // parser/decoder live on `queue`
                case .string(let text):
                    handle(text)
                @unknown default:
                    break
                }
            } catch {
                if phase != .closed {
                    phase = frames > 0 ? .failed("与应用画面的连接已断开。") : .failed(phaseError ?? error.localizedDescription)
                }
                return
            }
        }
    }

    @ObservationIgnored private var phaseError: String?

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if object["type"] as? String == "error", let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "ERROR"
            phaseError = Labels.reason(code) ?? "\(error["message"] as? String ?? "") (\(code))"
            phase = .failed(phaseError!)
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var ingestState = IngestState()
    private struct IngestState {
        var parser = AnnexBParser(maxBuffered: 8 << 20)
        var assembler = AccessUnitAssembler()
        var idle: DispatchWorkItem?
    }

    /// Runs on `queue`: same Annex B handling as the device view (idle flush of the last unit).
    nonisolated private func ingest(_ data: Data) {
        ingestState.idle?.cancel()
        for unit in ingestState.parser.feed(data) {
            for au in ingestState.assembler.push(unit) { decoder.decode(au) }
        }
        if ingestState.parser.hasPending {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if let unit = self.ingestState.parser.flushPending() {
                    for au in self.ingestState.assembler.push(unit) { self.decoder.decode(au) }
                }
                if let au = self.ingestState.assembler.flush() { self.decoder.decode(au) }
            }
            ingestState.idle = work
            queue.asyncAfter(deadline: .now() + .milliseconds(30), execute: work)
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let socket, phase == .running || phase == .connecting else { return }
        socket.send(.data(Data(bytes))) { _ in }
    }

    // MARK: Input (positions in frame pixels)

    func touch(_ action: ScrcpyControl.TouchAction, at p: CGPoint) {
        guard let size = frameSize else { return }
        send(ScrcpyControl.touch(action, x: Int(p.x), y: Int(p.y), width: Int(size.width), height: Int(size.height),
                                 pressure: action == .up ? 0 : 1))
    }

    func scroll(at p: CGPoint, dx: Double, dy: Double) {
        guard let size = frameSize else { return }
        send(ScrcpyControl.scroll(x: Int(p.x), y: Int(p.y), width: Int(size.width), height: Int(size.height),
                                  horizontal: dx, vertical: dy))
    }

    func key(_ key: ScrcpyControl.Key) {
        send(ScrcpyControl.key(key, down: true))
        send(ScrcpyControl.key(key, down: false))
    }

    func type(_ text: String) {
        guard !text.isEmpty else { return }
        send(ScrcpyControl.needsPaste(text) ? ScrcpyControl.paste(text) : ScrcpyControl.text(text))
    }

    func pasteFromMac() {
        if let text = NSPasteboard.general.string(forType: .string) { send(ScrcpyControl.paste(text)) }
    }

    /// Window resized: resize the virtual display (debounced); the app reflows.
    func resize(pixels: CGSize) {
        let w = Int(pixels.width) & ~1, h = Int(pixels.height) & ~1
        guard w >= 240, h >= 240, abs(CGFloat(w) - requestedSize.width) > 4 || abs(CGFloat(h) - requestedSize.height) > 4 else { return }
        resizeWork?.cancel()
        resizeWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.requestedSize = CGSize(width: w, height: h)
            self.send(ScrcpyControl.resize(width: w, height: h))
        }
    }

    func close() {
        phase = .closed
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        queue.async { [decoder] in decoder.invalidate() }
    }

    var lastFrame: CVPixelBuffer? { renderer.lastBuffer }
}

/// AppKit surface of an app window: continuous touch, scrolling, keyboard and input-method text.
final class AppCanvasNSView: NSView, NSTextInputClient {
    weak var session: AppWindowSession?
    var onBoundsChange: ((CGSize, CGFloat) -> Void)?
    private var marked = NSAttributedString()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    func attach(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        self.layer?.addSublayer(layer)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
        onBoundsChange?(bounds.size, window?.backingScaleFactor ?? 2)
    }

    /// Point in the decoded frame (the picture is aspect-fit in the view).
    private func framePoint(_ event: NSEvent) -> CGPoint? {
        guard let size = MainActor.assumeIsolated({ session?.frameSize }), size.width > 0, size.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let rect = CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2,
                          width: size.width * scale, height: size.height * scale)
        let x = min(max(p.x, rect.minX), rect.maxX - 1), y = min(max(p.y, rect.minY), rect.maxY - 1)
        return CGPoint(x: (x - rect.minX) / scale, y: (y - rect.minY) / scale)
    }

    private func onMain(_ body: (AppWindowSession) -> Void) {
        MainActor.assumeIsolated { if let session { body(session) } }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = framePoint(event) else { return }
        onMain { $0.touch(.down, at: p) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let p = framePoint(event) else { return }
        onMain { $0.touch(.move, at: p) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let p = framePoint(event) else { return }
        onMain { $0.touch(.up, at: p) }
    }
    /// Right click = Back, as on Android desktop mode.
    override func rightMouseDown(with event: NSEvent) { onMain { $0.key(.back) } }

    override func scrollWheel(with event: NSEvent) {
        guard let p = framePoint(event) else { return }
        let factor = event.hasPreciseScrollingDeltas ? 0.08 : 1.0
        let dx = Double(event.scrollingDeltaX) * factor, dy = Double(event.scrollingDeltaY) * factor
        guard dx != 0 || dy != 0 else { return }
        onMain { $0.scroll(at: p, dx: dx, dy: dy) }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v" { onMain { $0.pasteFromMac() } }
            else { super.keyDown(with: event) }
            return
        }
        let special: [UInt16: ScrcpyControl.Key] = [
            53: .back, 51: .del, 117: .forwardDel, 36: .enter, 76: .enter, 48: .tab,
            123: .dpadLeft, 124: .dpadRight, 125: .dpadDown, 126: .dpadUp, 115: .moveHome, 119: .moveEnd,
            116: .pageUp, 121: .pageDown,
        ]
        if !hasMarkedText(), let key = special[event.keyCode] {
            onMain { $0.key(key) }
            return
        }
        interpretKeyEvents([event])   // input methods (Pinyin etc.) call insertText
    }

    // MARK: NSTextInputClient (committed text is sent; composition happens in the Mac IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSAttributedString()
        onMain { $0.type(text) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    }
    func unmarkText() { marked = NSAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.maxY - 40, width: 1, height: 20), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}
}

struct AppCanvas: NSViewRepresentable {
    let session: AppWindowSession

    func makeNSView(context: Context) -> AppCanvasNSView {
        let view = AppCanvasNSView()
        view.session = session
        view.attach(session.renderer.layer)
        view.onBoundsChange = { [weak session] size, scale in
            MainActor.assumeIsolated {
                guard let session else { return }
                let density = AppWindowSession.density
                let pixels = CGSize(width: (size.width * density).rounded(), height: (size.height * density).rounded())
                if session.requestedSize == .zero { session.connect(pixels: pixels, scale: density) }
                else { session.resize(pixels: pixels) }
            }
        }
        return view
    }

    func updateNSView(_ view: AppCanvasNSView, context: Context) { view.session = session }
}

/// Window for one Android app: only the app's own UI, sized 1 dp = 1 point.
struct AppWindowView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let target: AppWindowTarget
    @State private var session: AppWindowSession?

    private var artifact: Artifact? { store.artifact(target.artifactId) }

    var body: some View {
        ZStack {
            Color.black
            if let session {
                AppCanvas(session: session)
                overlay(session)
            }
        }
        .frame(minWidth: 240, minHeight: 320)
        .navigationSubtitle(session.map { s in
            s.phase == .running ? "\(Int(s.fps)) fps · \(s.hardwareDecoding == false ? "软件解码" : "硬件解码")" : ""
        } ?? "")
        .navigationTitle(artifact.map { $0.name.replacingOccurrences(of: ".apk", with: "") } ?? "应用")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { session?.key(.back) } label: { Label("返回", systemImage: "chevron.backward") }
                    .help("返回（Esc 或右键）")
                Button { switchToDeviceView() } label: {
                    Label("改用设备视图", systemImage: "iphone")
                }
                .help("在完整设备视图中运行此应用，并记住这个选择（部分银行、支付类应用不允许在独立窗口中运行）")
            }
        }
        .onAppear {
            if session == nil, let artifact {
                let s = AppWindowSession(target: target, package: artifact.bundleId, store: store)
                session = s
                store.registerAppWindow(s)
            }
        }
        .onDisappear { session?.close() }
    }

    @ViewBuilder private func overlay(_ session: AppWindowSession) -> some View {
        switch session.phase {
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("正在打开…").foregroundStyle(.white.opacity(0.8)).font(.callout)
                if session.stalledWithoutFrames { fallback }
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message).foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal)
                fallback
            }
        default:
            EmptyView()
        }
    }

    private var fallback: some View {
        Button("改用设备视图打开") { switchToDeviceView() }
            .buttonStyle(.borderedProminent)
    }

    /// Reopens the app on the main display (device view) and remembers that for this app.
    private func switchToDeviceView() {
        guard let artifact else { return }
        store.setPrefersDeviceView(artifact, true)
        session?.close()
        dismiss()
        Task { await store.open(artifact, forceDeviceView: true) }
    }
}
