import AppKit
import CoreVideo
import Foundation
import Observation
import QuartzCore

/// Displays decoded frames by handing their IOSurface to a CALayer.
final class VideoRenderer: @unchecked Sendable {
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        return layer
    }()
    private var recent: [CVPixelBuffer] = []   // keep surfaces alive while the layer shows them
    var onSize: ((CGSize) -> Void)?
    var lastBuffer: CVPixelBuffer? { recent.last }

    func show(_ buffer: CVPixelBuffer) {
        DispatchQueue.main.async { [self] in
            guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
            recent.append(buffer)
            if recent.count > 3 { recent.removeFirst() }
            onSize?(CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
        }
    }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
        recent.removeAll()
    }
}

/// State of one screen window: live video or screenshot polling, guest geometry and input.
@MainActor @Observable
final class ScreenSession {
    enum Source: Equatable { case none, video, screenshots }

    let instanceId: UUID
    private(set) var source: Source = .none
    var status = "正在连接画面…"
    var videoError: String?
    var contentSize: CGSize?        // size of what is displayed (decoded video or screenshot)
    var guestSize: CGSize?          // real guest display size, used for touch coordinates
    var fps: Double = 0
    var stats = VideoStream.Stats()
    var pendingInputs = 0
    var lastInputError: String?
    var lastTap: CGPoint?
    var paused = false

    let renderer = VideoRenderer()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var stream: VideoStream?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputQueue: [(String, [String: Any])] = []
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var userPrefersScreenshots = false

    init(instanceId: UUID, store: AppStore) {
        self.instanceId = instanceId
        self.store = store
        renderer.onSize = { [weak self] size in
            MainActor.assumeIsolated { self?.videoSizeChanged(size) }
        }
    }

    private var instance: Instance? { store?.instance(instanceId) }

    // MARK: Lifecycle

    func activate() {
        guard !active else { return }
        active = true
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.fps = Double(self.frameCounter)
                self.frameCounter = 0
                if let stream = self.stream { self.stats = stream.stats }
            }
        }
        Task { await refreshGuestSize() }
        chooseSource()
    }

    func deactivate() {
        active = false
        stopVideo()
        pollTask?.cancel(); pollTask = nil
        statsTask?.cancel(); statsTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        inputTask?.cancel(); inputTask = nil
        inputQueue.removeAll()
        source = .none
    }

    /// Called when the instance changes (state or capabilities).
    func instanceChanged() {
        guard active else { return }
        guard let instance, instance.isReady else {
            stopVideo()
            pollTask?.cancel(); pollTask = nil
            source = .none
            status = instance.map { "设备\(Labels.state($0.state))" } ?? "设备已删除"
            return
        }
        if source == .none { chooseSource() }
    }

    func chooseSource() {
        guard active, let instance else { return }
        guard instance.isReady else {
            source = .none
            status = "设备\(Labels.state(instance.state))"
            return
        }
        if instance.can("liveVideo") && !userPrefersScreenshots {
            startVideo()
        } else {
            if let reason = instance.capability("liveVideo")?.reasonCode { videoError = Labels.reason(reason) ?? reason }
            startScreenshots()
        }
    }

    func setPreferScreenshots(_ value: Bool) {
        userPrefersScreenshots = value
        failures = 0
        stopVideo()
        pollTask?.cancel(); pollTask = nil
        source = .none
        chooseSource()
    }

    func retryVideo() {
        videoError = nil
        setPreferScreenshots(false)
    }

    // MARK: Video

    var reconnects = 0
    private(set) var totalFrames = 0
    @ObservationIgnored private(set) var videoLog: [String] = []
    private func trace(_ text: String) {
        videoLog.append(String(format: "%.2f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + text)
        if videoLog.count > 60 { videoLog.removeFirst(videoLog.count - 60) }
    }
    func simulateVideoDrop() {
        trace("simulate drop (stream \(stream == nil ? "nil" : "live"))")
        stream?.simulateDrop()
    }
    var lastFrame: CVPixelBuffer? { renderer.lastBuffer }

    private func startVideo() {
        guard let client = store?.client, let request = try? client.videoRequest(instanceId) else {
            // Backend restarting: keep the video source and try again once it is back.
            source = .video
            status = "等待后端恢复…"
            trace("no backend client; retry")
            scheduleReconnect(after: 1)
            return
        }
        pollTask?.cancel(); pollTask = nil
        stopVideo()
        source = .video
        status = failures == 0 ? "正在连接实时画面…" : "正在重新连接实时画面 (第 \(failures) 次)…"
        if failures > 0 { reconnects += 1 }
        trace("start video (failures \(failures))")
        let stream = VideoStream()
        let renderer = self.renderer
        stream.onFrame = { [weak self] buffer in
            renderer.show(buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.frameCounter += 1
                    self?.totalFrames += 1
                }
            }
        }
        stream.onStreaming = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.failures = 0
                    self?.status = "实时画面"
                    self?.videoError = nil
                }
            }
        }
        stream.onStall = { [weak self, weak stream] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let stream, self.stream === stream else { return }
                    self.trace("stall: waiting for keyframe")
                    self.status = "解码等待关键帧，重新连接…"
                    stream.cancel()
                    self.stream = nil
                    self.scheduleReconnect(after: 0.3)
                }
            }
        }
        stream.onEnd = { [weak self, weak stream] end in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.trace("stream end \(end) current=\(stream != nil && self?.stream === stream)")
                    guard let self, let stream, self.stream === stream else { return }
                    self.stream = nil
                    self.videoEnded(end, frames: stream.stats.decodedFrames)
                }
            }
        }
        self.stream = stream
        stream.start(request)
    }

    private func stopVideo() {
        stream?.cancel()
        stream = nil
    }

    private func videoEnded(_ end: VideoStream.End, frames: Int) {
        trace("ended frames=\(frames) active=\(active) source=\(source) failures=\(failures)")
        guard active, source == .video else { return }
        switch end {
        case .cancelled:
            return
        case let .http(httpStatus, body):
            if body.code == "RESOURCE_BUSY" {
                // Previous subscription is still closing on the backend.
                failures += 1
                if httpStatus == 409 && failures < 12 {
                    scheduleReconnect(after: 1)
                } else {
                    fallBack("实时画面被占用 (\(body.code))")
                }
            } else if body.code == "INSTANCE_NOT_READY" {
                source = .none
                status = "设备未运行"
                Task { await store?.refreshInstance(instanceId) }
            } else {
                fallBack(Labels.reason(body.code) ?? "\(body.message) (\(body.code))")
            }
        case .finished, .network:
            if frames > 0 { failures = 0 }
            failures += 1
            if failures > 5 {
                fallBack("实时画面多次断开，已切换为截图。")
            } else {
                let delay = min(8, 0.5 * pow(2, Double(failures - 1)))
                status = "画面连接中断，\(String(format: "%.1f", delay)) 秒后重连…"
                Task { await store?.refreshInstance(instanceId) }
                scheduleReconnect(after: delay)
            }
        }
    }

    private func scheduleReconnect(after delay: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.active else { return }
            self.trace("reconnect fire ready=\(self.instance?.isReady == true)")
            if self.instance?.isReady == true { self.startVideo() } else { self.instanceChanged() }
        }
    }

    private func fallBack(_ reason: String) {
        videoError = reason
        stopVideo()
        startScreenshots()
    }

    private func videoSizeChanged(_ size: CGSize) {
        guard size != contentSize else { return }
        let rotated = contentSize.map { ($0.width > $0.height) != (size.width > size.height) } ?? false
        contentSize = size
        if rotated || guestSize == nil { Task { await refreshGuestSize() } }
    }

    // MARK: Screenshots

    private func startScreenshots() {
        source = .screenshots
        status = "截图模式"
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                if !self.paused { await self.captureScreenshot(updateDisplay: true) }
                let interval: Double = self.instance?.isAndroid == true ? 1.0 : 1.5
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Fetches a screenshot. The PNG is full resolution, so it also defines the guest size.
    @discardableResult
    func captureScreenshot(updateDisplay: Bool) async -> CGImage? {
        guard let client = store?.client else { return nil }
        do {
            let data = try await client.screenshot(instanceId)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            guestSize = CGSize(width: image.width, height: image.height)
            if updateDisplay && self.source == .screenshots {
                renderer.show(image)
                contentSize = guestSize
                frameCounter += 1
                totalFrames += 1
            }
            return image
        } catch let error as APIError where error.code == "INSTANCE_NOT_READY" {
            await store?.refreshInstance(instanceId)
            return nil
        } catch {
            if self.source == .screenshots { status = "截图失败：\(error.localizedDescription)" }
            return nil
        }
    }

    func refreshGuestSize() async {
        guard instance?.isReady == true else { return }
        _ = await captureScreenshot(updateDisplay: source == .screenshots)
    }

    // MARK: Input

    /// Maps a point normalised to the displayed picture (0...1, origin top-left) to guest pixels.
    func guestPoint(normalized p: CGPoint) -> CGPoint? {
        guard let size = guestSize ?? contentSize else { return nil }
        let x = min(max(0, p.x), 1) * size.width
        let y = min(max(0, p.y), 1) * size.height
        return CGPoint(x: min(size.width - 1, x.rounded(.down)), y: min(size.height - 1, y.rounded(.down)))
    }

    func tap(normalized p: CGPoint) {
        guard instance?.can("input") == true, let point = guestPoint(normalized: p) else { return }
        lastTap = point
        enqueue("tap", ["x": Int(point.x), "y": Int(point.y)])
    }

    func swipe(from a: CGPoint, to b: CGPoint, duration: TimeInterval) {
        guard instance?.can("guestShell") == true, instance?.isAndroid == true,
              let p = guestPoint(normalized: a), let q = guestPoint(normalized: b) else {
            tap(normalized: b); return
        }
        let ms = max(80, min(2000, Int(duration * 1000)))
        enqueue("shell", ["argv": ["input", "swipe", "\(Int(p.x))", "\(Int(p.y))", "\(Int(q.x))", "\(Int(q.y))", "\(ms)"]])
    }

    func key(_ code: String) {
        guard instance?.can("input") == true else { return }
        enqueue("key", ["value": code])
    }

    func typeText(_ text: String) {
        if instance?.isWindows == true, instance?.can("input") == true, !text.isEmpty {
            enqueue("text", ["value": text]); return
        }
        guard instance?.can("guestShell") == true, instance?.isAndroid == true, !text.isEmpty else { return }
        // `input text` treats %s as space; other shell metacharacters are passed as one argv element.
        let encoded = text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: " ", with: "%s")
        enqueue("shell", ["argv": ["input", "text", encoded]])
    }

    /// Input actions are serialised: the backend runs one operation per instance at a time.
    private func enqueue(_ action: String, _ body: [String: Any]) {
        if inputQueue.count >= 8 { inputQueue.removeFirst() }
        inputQueue.append((action, body))
        pendingInputs = inputQueue.count + (inputTask == nil ? 0 : 1)
        guard inputTask == nil else { return }
        inputTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.inputQueue.isEmpty {
                let (action, body) = self.inputQueue.removeFirst()
                self.pendingInputs = self.inputQueue.count + 1
                await self.send(action, body)
            }
            self?.inputTask = nil
            self?.pendingInputs = 0
        }
    }

    private func send(_ action: String, _ body: [String: Any]) async {
        guard let store else { return }
        for attempt in 0..<4 {
            do {
                try await store.perform(instanceId, action, body: body, timeout: 60)
                lastInputError = nil
                if source == .screenshots { await captureScreenshot(updateDisplay: true) }
                return
            } catch let error as APIError where error.code == "RESOURCE_BUSY" && attempt < 3 {
                try? await Task.sleep(for: .milliseconds(400))
            } catch is CancellationError {
                return
            } catch {
                lastInputError = error.localizedDescription
                return
            }
        }
    }
}
