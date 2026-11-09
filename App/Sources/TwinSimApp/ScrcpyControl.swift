import Foundation

/// Encoder for scrcpy 4.0 control messages (big-endian, see ControlMessageReader.java).
enum ScrcpyControl {
    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }
    static let fingerPointer: Int64 = -2   // POINTER_ID_GENERIC_FINGER

    // Android key codes used by app windows.
    enum Key: Int32 {
        case home = 3, back = 4, dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22, tab = 61, space = 62
        case enter = 66, del = 67, pageUp = 92, pageDown = 93, escape = 111, forwardDel = 112, moveHome = 122, moveEnd = 123
        case appSwitch = 187
    }

    private static func be<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    /// x, y in video-frame pixels; width/height must equal the current frame size or the server drops it.
    static func touch(_ action: TouchAction, x: Int, y: Int, width: Int, height: Int, pressure: Double = 1) -> [UInt8] {
        var b: [UInt8] = [2, action.rawValue]
        b += be(fingerPointer)
        b += be(Int32(x)) + be(Int32(y)) + be(UInt16(clamping: width)) + be(UInt16(clamping: height))
        b += be(UInt16(min(max(pressure, 0), 1) * 0xffff))
        b += be(Int32(0)) + be(Int32(0))   // action button, buttons (touch, not mouse)
        return b
    }

    /// Scroll amounts are in "ticks" (positive = up/left), range -16...16.
    static func scroll(x: Int, y: Int, width: Int, height: Int, horizontal: Double, vertical: Double) -> [UInt8] {
        func fixed(_ v: Double) -> Int16 { Int16(min(max(v / 16, -1), 1) * Double(Int16.max)) }
        var b: [UInt8] = [3]
        b += be(Int32(x)) + be(Int32(y)) + be(UInt16(clamping: width)) + be(UInt16(clamping: height))
        b += be(fixed(horizontal)) + be(fixed(vertical)) + be(Int32(0))
        return b
    }

    static func key(_ code: Key, down: Bool, metaState: Int32 = 0) -> [UInt8] {
        [0, down ? 0 : 1] + be(code.rawValue) + be(Int32(0)) + be(metaState)
    }

    /// Text injected as key events: works for characters in the device key map (ASCII).
    static func text(_ text: String) -> [UInt8] {
        let utf8 = Array(text.utf8.prefix(300))
        return [1] + be(UInt32(utf8.count)) + utf8
    }

    /// Sets the device clipboard and pastes it: used for non-ASCII text (IME input) and ⌘V.
    static func paste(_ text: String, sequence: Int64 = 0) -> [UInt8] {
        let utf8 = Array(text.utf8.prefix(200_000))
        return [9] + be(sequence) + [1] + be(UInt32(utf8.count)) + utf8
    }

    static func resize(width: Int, height: Int) -> [UInt8] {
        [21] + be(UInt16(clamping: width)) + be(UInt16(clamping: height))
    }

    static func needsPaste(_ text: String) -> Bool {
        !text.unicodeScalars.allSatisfy { $0.isASCII && ($0.value >= 0x20 && $0.value < 0x7f) }
    }
}
