import XCTest
@testable import TwinSimApp

final class ScrcpyControlTests: XCTestCase {
    func testTouchLayout() {
        let b = ScrcpyControl.touch(.down, x: 412, y: 860, width: 824, height: 1720)
        XCTAssertEqual(b.count, 32)                                   // scrcpy touch message size
        XCTAssertEqual(Array(b[0...1]), [2, 0])
        XCTAssertEqual(Array(b[2...9]), [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe])   // pointer -2
        XCTAssertEqual(Array(b[10...13]), [0, 0, 0x01, 0x9c])          // x = 412
        XCTAssertEqual(Array(b[14...17]), [0, 0, 0x03, 0x5c])          // y = 860
        XCTAssertEqual(Array(b[18...21]), [0x03, 0x38, 0x06, 0xb8])    // 824 x 1720
        XCTAssertEqual(Array(b[22...23]), [0xff, 0xff])                // pressure 1.0
        XCTAssertEqual(ScrcpyControl.touch(.up, x: 0, y: 0, width: 1, height: 1, pressure: 0)[22...23], [0, 0])
    }

    func testOtherMessages() {
        XCTAssertEqual(ScrcpyControl.key(.back, down: true), [0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(ScrcpyControl.scroll(x: 1, y: 2, width: 3, height: 4, horizontal: 0, vertical: 16).count, 21)
        XCTAssertEqual(Array(ScrcpyControl.scroll(x: 0, y: 0, width: 1, height: 1, horizontal: 0, vertical: 16)[15...16]), [0x7f, 0xff])
        XCTAssertEqual(ScrcpyControl.resize(width: 1000, height: 1400), [21, 0x03, 0xe8, 0x05, 0x78])
        XCTAssertEqual(ScrcpyControl.text("hi"), [1, 0, 0, 0, 2, 0x68, 0x69])
        let paste = ScrcpyControl.paste("中")
        XCTAssertEqual(paste[0], 9); XCTAssertEqual(paste[9], 1); XCTAssertEqual(Array(paste[10...13]), [0, 0, 0, 3])
        XCTAssertTrue(ScrcpyControl.needsPaste("你好"))
        XCTAssertFalse(ScrcpyControl.needsPaste("hello world!"))
        XCTAssertTrue(ScrcpyControl.needsPaste("tab\there"))
    }
}
