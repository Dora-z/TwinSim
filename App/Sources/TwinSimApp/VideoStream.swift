import CoreVideo
import Foundation

/// One HTTP subscription to `/v1/instances/{id}/video`. Network chunks feed the Annex B parser,
/// complete access units go to the VideoToolbox decoder; everything runs on one serial queue.
final class VideoStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum End: Sendable {
        case finished                       // stream closed by the backend
        case network(String)
        case http(Int, APIErrorBody)
        case cancelled
    }

    struct Stats: Sendable {
        var receivedBytes: Int64 = 0
        var decodedFrames = 0
        var decodeErrors = 0
        var droppedBytes = 0
        var resyncs = 0
        var idleFlushes = 0
    }

    private let queue = DispatchQueue(label: "com.twinsim.video", qos: .userInteractive)
    private var urlSession: URLSession!
    private var task: URLSessionDataTask?
    private var parser = AnnexBParser(maxBuffered: 4 << 20)
    private var assembler = AccessUnitAssembler()
    private let decoder = H264Decoder()
    private var status = 0
    private var errorBody = Data()
    private var idleWork: DispatchWorkItem?
    private var finished = false
    private var stallReported = false
    private(set) var stats = Stats()

    /// Frames are delivered on the video queue.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called on the video queue when the first decodable picture arrives.
    var onStreaming: (() -> Void)?
    var onEnd: ((End) -> Void)?
    /// Called when the decoder has been waiting for a keyframe for too long.
    var onStall: (() -> Void)?

    /// Idle time after which the buffered tail is treated as a complete NAL unit. scrcpy writes a
    /// whole packet at once and repeats the last frame after 100 ms, so 45 ms keeps latency low.
    static let idleFlush: DispatchTimeInterval = .milliseconds(45)

    func start(_ request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 24 * 3600   // a static screen sends no data
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        decoder.onFrame = { [weak self] buffer in
            guard let self else { return }
            if self.stats.decodedFrames == 0 { self.onStreaming?() }
            self.stats.decodedFrames += 1
            self.onFrame?(buffer)
        }
        task = urlSession.dataTask(with: request)
        task?.resume()
    }

    /// Drops the connection as a network failure would (used by the self-test).
    func simulateDrop() {
        queue.async { [weak self] in
            self?.simulatedDrop = true
            self?.task?.cancel()
        }
    }
    private var simulatedDrop = false

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.finish(.cancelled)
            self.task?.cancel()
        }
    }

    private func finish(_ end: End) {
        guard !finished else { return }
        finished = true
        idleWork?.cancel()
        decoder.invalidate()
        urlSession?.finishTasksAndInvalidate()
        onEnd?(end)
        onEnd = nil
        onFrame = nil
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard status == 200 else {
            if errorBody.count < 16 << 10 { errorBody.append(data) }
            return
        }
        stats.receivedBytes += Int64(data.count)
        idleWork?.cancel()
        for unit in parser.feed(data) { consume(unit) }
        stats.droppedBytes = parser.droppedBytes
        stats.resyncs = parser.resyncs
        if !stallReported, let wait = decoder.keyframeWait, wait > 4, stats.decodedFrames > 0 || wait > 12 {
            stallReported = true
            onStall?()
        }
        if parser.hasPending {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.finished else { return }
                if let unit = self.parser.flushPending() {
                    self.stats.idleFlushes += 1
                    self.consume(unit)
                }
                if let au = self.assembler.flush() { self.decoder.decode(au) }
            }
            idleWork = work
            queue.asyncAfter(deadline: .now() + Self.idleFlush, execute: work)
        }
    }

    private func consume(_ unit: [UInt8]) {
        for au in assembler.push(unit) { decoder.decode(au) }
        stats.decodeErrors = decoder.decodeErrors
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if status != 0 && status != 200 {
            let body = (try? JSONDecoder().decode(APIErrorBody.self, from: errorBody))
                ?? APIErrorBody(code: "HTTP_\(status)", message: String(decoding: errorBody.prefix(300), as: UTF8.self))
            finish(.http(status, body))
        } else if simulatedDrop {
            finish(.network("simulated drop"))
        } else if let error {
            finish((error as? URLError)?.code == .cancelled ? .cancelled : .network(error.localizedDescription))
        } else {
            finish(.finished)
        }
    }
}
