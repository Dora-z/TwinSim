import XCTest
@testable import TwinSimApp

final class AnnexBParserTests: XCTestCase {
    private let sps: [UInt8] = [0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01]
    private let pps: [UInt8] = [0x68, 0xce, 0x3c, 0x80]
    private let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x00, 0x03, 0x00, 0x21]   // contains emulation prevention
    private let slice: [UInt8] = [0x41, 0x9a, 0x02, 0x03]

    private var stream: [UInt8] {
        [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps + [0, 0, 1] + idr + [0, 0, 0, 1] + slice + [0, 0, 0, 1] + slice
    }

    func testWholeStream() {
        var parser = AnnexBParser()
        let units = parser.feed(stream)
        XCTAssertEqual(units, [sps, pps, idr, slice])        // last slice still pending
        XCTAssertEqual(parser.flushPending(), slice)
    }

    func testEveryChunkSplitPosition() {
        for split in 1..<stream.count {
            var parser = AnnexBParser()
            var units = parser.feed(stream[0..<split])
            units += parser.feed(stream[split...])
            if let tail = parser.flushPending() { units.append(tail) }
            XCTAssertEqual(units, [sps, pps, idr, slice, slice], "split at \(split)")
        }
    }

    func testByteByByte() {
        var parser = AnnexBParser()
        var units: [[UInt8]] = []
        for byte in stream { units += parser.feed([byte]) }
        units += parser.flushPending().map { [$0] } ?? []
        XCTAssertEqual(units, [sps, pps, idr, slice, slice])
    }

    func testGarbageBeforeFirstStartCodeIsSkipped() {
        var parser = AnnexBParser()
        let units = parser.feed([0x12, 0x34, 0x56] + stream)
        XCTAssertEqual(units.first, sps)
    }

    func testBufferCapResyncs() {
        var parser = AnnexBParser(maxBuffered: 64)
        _ = parser.feed([0, 0, 1, 0x65] + [UInt8](repeating: 0xff, count: 100))
        XCTAssertEqual(parser.resyncs, 1)
        XCTAssertEqual(parser.feed([0, 0, 1] + sps + [0, 0, 1]), [sps])
    }

    func testDataAfterIdleFlushIsDiscardedUntilStartCode() {
        var parser = AnnexBParser()
        _ = parser.feed([0, 0, 1] + slice)
        XCTAssertEqual(parser.flushPending(), slice)
        XCTAssertEqual(parser.feed([0x11, 0x22, 0, 0, 1] + sps + [0, 0, 1]), [sps])
    }

    func testAccessUnits() {
        var assembler = AccessUnitAssembler()
        var aus: [[[UInt8]]] = []
        for unit in [sps, pps, idr, slice, slice, [0x09, 0xf0], sps] { aus += assembler.push(unit) }
        XCTAssertEqual(aus, [[sps, pps, idr], [slice], [slice]])
        XCTAssertNil(assembler.flush())   // only SPS pending
    }

    func testMultiSlicePicture() {
        var assembler = AccessUnitAssembler()
        let second: [UInt8] = [0x41, 0x40, 0x01]  // first_mb_in_slice != 0
        var aus = assembler.push(slice) + assembler.push(second) + assembler.push(slice)
        aus += assembler.flush().map { [$0] } ?? []
        XCTAssertEqual(aus, [[slice, second], [slice]])
    }
}

final class SSEParserTests: XCTestCase {
    func testEventsAcrossChunks() {
        var parser = SSEParser()
        let text = "id: e:1\nevent: reset\ndata: {}\n\n: heartbeat\n\nid: e:2\nevent: operation\ndata: {\"a\":1}\n\n"
        let bytes = Array(text.utf8)
        var events: [SSEEvent] = []
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            events += parser.feed(Data(bytes[chunk..<min(bytes.count, chunk + 7)]))
        }
        XCTAssertEqual(events, [SSEEvent(id: "e:1", event: "reset", data: "{}"),
                                SSEEvent(id: "e:2", event: "operation", data: "{\"a\":1}")])
        XCTAssertEqual(parser.lastEventID, "e:2")
    }

    func testCRLFAndMultilineData() {
        var parser = SSEParser()
        let events = parser.feed(Data("event: x\r\ndata: a\r\ndata: b\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(id: nil, event: "x", data: "a\nb")])
    }
}

final class DecodingTests: XCTestCase {
    func testInstanceWithEmptyCapabilities() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","profileId":"android-aosp","engineId":"android-emulator","purpose":"app","state":"ready","capabilities":{}}"#
        let instance = try JSONDecoder().decode(Instance.self, from: Data(json.utf8))
        XCTAssertTrue(instance.isAppWorkspace)
        XCTAssertFalse(instance.can("input"))
    }

    func testOperationError() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","action":"open-app","state":"failed","error":{"code":"RESEARCH_GUESTS_DISABLED","message":"m","retryable":false}}"#
        let op = try JSONDecoder().decode(BackendOperation.self, from: Data(json.utf8))
        XCTAssertEqual(op.error?.code, "RESEARCH_GUESTS_DISABLED")
        XCTAssertTrue(op.isTerminal)
    }
}
