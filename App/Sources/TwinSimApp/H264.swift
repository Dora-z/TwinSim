import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Splits an Annex B byte stream into NAL units. Network chunks do not line up with NAL units or
/// frames, so bytes are buffered until the next start code proves the previous unit complete.
struct AnnexBParser {
    private(set) var buffer: [UInt8] = []
    private var nalStart: Int?          // payload start of the unit being collected
    private var scanIndex = 0
    let maxBuffered: Int
    private(set) var droppedBytes = 0
    private(set) var resyncs = 0

    init(maxBuffered: Int = 4 << 20) { self.maxBuffered = maxBuffered }

    var hasPending: Bool { nalStart.map { $0 < buffer.count } ?? false }
    var bufferedBytes: Int { buffer.count }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        nalStart = nil
        scanIndex = 0
    }

    mutating func feed<C: Collection>(_ bytes: C) -> [[UInt8]] where C.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var units: [[UInt8]] = []
        buffer.withUnsafeBufferPointer { raw in
            var i = scanIndex
            let n = raw.count
            while i + 2 < n {
                // Fast skip: a start code needs raw[i+2] == 1 and raw[i+1] == 0.
                if raw[i + 2] > 1 { i += 3; continue }
                if raw[i] == 0, raw[i + 1] == 0, raw[i + 2] == 1 {
                    if let start = nalStart {
                        var end = i
                        while end > start && raw[end - 1] == 0 { end -= 1 }  // trailing_zero_8bits / 4-byte start code
                        if end > start { units.append(Array(raw[start..<end])) }
                    }
                    nalStart = i + 3
                    i += 3
                } else {
                    i += 1
                }
            }
            scanIndex = max(i, nalStart ?? 0)
            // Keep up to two bytes unscanned: they may be the start of a split start code.
            scanIndex = min(scanIndex, max(n - 2, nalStart ?? 0))
        }
        compact()
        if buffer.count > maxBuffered {
            // No start code for too long: drop and wait for the next unit boundary.
            droppedBytes += buffer.count
            resyncs += 1
            reset()
        }
        return units
    }

    /// Treats the buffered tail as a complete unit (used after the stream goes idle). Further
    /// bytes without a leading start code are discarded until the next start code.
    mutating func flushPending() -> [UInt8]? {
        guard let start = nalStart, start < buffer.count else { return nil }
        var end = buffer.count
        while end > start && buffer[end - 1] == 0 { end -= 1 }
        let unit = end > start ? Array(buffer[start..<end]) : nil
        buffer.removeAll(keepingCapacity: true)
        nalStart = nil
        scanIndex = 0
        return unit
    }

    private mutating func compact() {
        let keepFrom: Int
        if let start = nalStart {
            keepFrom = max(0, start - 3)
        } else {
            keepFrom = max(0, buffer.count - 2)   // unsynced: only a possible partial start code matters
        }
        guard keepFrom > 0 else { return }
        buffer.removeFirst(keepFrom)
        if let start = nalStart { nalStart = start - keepFrom }
        scanIndex = max(0, scanIndex - keepFrom)
    }
}

enum NALType {
    static func of(_ unit: [UInt8]) -> UInt8 { unit.first.map { $0 & 0x1f } ?? 0 }
    static func isVCL(_ type: UInt8) -> Bool { (1...5).contains(type) }
}

/// Groups NAL units into access units (one coded picture each).
struct AccessUnitAssembler {
    private var current: [[UInt8]] = []
    private var hasVCL = false

    mutating func push(_ unit: [UInt8]) -> [[[UInt8]]] {
        guard !unit.isEmpty else { return [] }
        let type = NALType.of(unit)
        var finished: [[[UInt8]]] = []
        if hasVCL {
            let startsNew: Bool
            if NALType.isVCL(type) {
                // first_mb_in_slice == 0 (ue(v) coded as a single '1' bit) starts a new picture.
                startsNew = unit.count > 1 && (unit[1] & 0x80) != 0
            } else {
                startsNew = [6, 7, 8, 9, 10, 11, 14, 15, 16, 17, 18].contains(type)
            }
            if startsNew, let au = flush() { finished.append(au) }
        }
        if type == 9 || type == 10 || type == 11 { return finished }  // AUD / end markers carry no data
        current.append(unit)
        if NALType.isVCL(type) { hasVCL = true }
        return finished
    }

    mutating func flush() -> [[UInt8]]? {
        guard hasVCL else { return nil }
        defer { current.removeAll(); hasVCL = false }
        return current
    }

    mutating func reset() { current.removeAll(); hasVCL = false }
}

/// VideoToolbox H.264 decoder for Annex B access units. Parameter-set changes (rotation,
/// resolution changes, reconnects) rebuild the session; decoding resumes at the next IDR.
final class H264Decoder {
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private(set) var waitingForKeyframe = true
    private(set) var decodedFrames = 0
    private(set) var decodeErrors = 0
    /// Whether VideoToolbox runs this session on the hardware decoder (Apple media engine).
    private(set) var usingHardware = false
    private var keyframeWaitStarted = Date()
    var onFrame: ((CVPixelBuffer) -> Void)?

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    func reset() {
        invalidate()
        sps = nil; pps = nil; format = nil
        waitingForKeyframe = true
        keyframeWaitStarted = Date()
    }

    /// Seconds spent waiting for a keyframe, or nil while decoding normally.
    var keyframeWait: TimeInterval? { waitingForKeyframe ? Date().timeIntervalSince(keyframeWaitStarted) : nil }

    func decode(_ accessUnit: [[UInt8]]) {
        var parametersChanged = false
        for unit in accessUnit {
            switch NALType.of(unit) {
            case 7 where unit != sps: sps = unit; parametersChanged = true
            case 8 where unit != pps: pps = unit; parametersChanged = true
            default: break
            }
        }
        if parametersChanged || session == nil, let sps, let pps {
            if !rebuild(sps: sps, pps: pps) { return }
        }
        let slices = accessUnit.filter { NALType.isVCL(NALType.of($0)) }
        guard !slices.isEmpty, let session, let format else { return }
        let isIDR = slices.contains { NALType.of($0) == 5 }
        if waitingForKeyframe {
            guard isIDR else { return }
            waitingForKeyframe = false
        }
        // Annex B -> AVCC: replace start codes with 4-byte big-endian lengths.
        let total = slices.reduce(0) { $0 + 4 + $1.count }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        var offset = 0
        for slice in slices {
            var length = UInt32(slice.count).bigEndian
            _ = withUnsafeBytes(of: &length) { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4) }
            offset += 4
            _ = slice.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: slice.count) }
            offset += slice.count
        }
        var sample: CMSampleBuffer?
        var size = total
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status == noErr, let image {
                self.decodedFrames += 1
                self.onFrame?(image)
            } else if status != noErr {
                self.markError()
            }
        }
        if status != noErr {
            markError()
            if status == kVTInvalidSessionErr { invalidate() }
        }
    }

    private func markError() {
        decodeErrors += 1
        if !waitingForKeyframe { waitingForKeyframe = true; keyframeWaitStarted = Date() }
    }

    private func rebuild(sps: [UInt8], pps: [UInt8]) -> Bool {
        invalidate()
        var description: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { decodeErrors += 1; return false }
        format = description
        // Native decoder output (4:2:0 YUV) in IOSurfaces: no per-frame colour conversion; the
        // display layer composites YUV on the GPU.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        func create(_ spec: [CFString: Any]) -> VTDecompressionSession? {
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                                                      decoderSpecification: spec as CFDictionary,
                                                      imageBufferAttributes: attributes as CFDictionary,
                                                      outputCallback: nil, decompressionSessionOut: &session)
            return status == noErr ? session : nil
        }
        // Require the hardware decoder; fall back to software only if the hardware path refuses
        // this stream (unusual sizes or profiles).
        guard let newSession = create([kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true])
                ?? create([kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]) else {
            decodeErrors += 1
            return false
        }
        var hardware: CFTypeRef?
        VTSessionCopyProperty(newSession, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: kCFAllocatorDefault, valueOut: &hardware)
        usingHardware = (hardware as? Bool) ?? false
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        waitingForKeyframe = true
        keyframeWaitStarted = Date()
        return true
    }

    /// Picture size from the active SPS (after cropping), if known.
    var dimensions: CMVideoDimensions? { format.map(CMVideoFormatDescriptionGetDimensions) }
}
