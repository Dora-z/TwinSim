import Foundation
import XCTest
@testable import TwinSim

final class WindowsTests: XCTestCase {
    private func pe(machine: UInt16) -> Data {
        var data = Data(count: 0x200)
        data[0] = 0x4d; data[1] = 0x5a                       // MZ
        data[0x3c] = 0x80                                     // e_lfanew
        data[0x80] = 0x50; data[0x81] = 0x45                  // PE\0\0
        data[0x84] = UInt8(machine & 0xff); data[0x85] = UInt8(machine >> 8)
        return data
    }

    func testMachineTypes() throws {
        guard case .x86 = try PortableExecutable.machine(pe(machine: 0x014c)) else { return XCTFail("x86") }
        guard case .x64 = try PortableExecutable.machine(pe(machine: 0x8664)) else { return XCTFail("x64") }
        guard case .arm64 = try PortableExecutable.machine(pe(machine: 0xaa64)) else { return XCTFail("arm64") }
        XCTAssertThrowsError(try PortableExecutable.machine(Data("hello world, not a PE file at all......................................".utf8)))
        var dos = pe(machine: 0x014c); dos[0x80] = 0                 // MZ without PE header (DOS program)
        XCTAssertThrowsError(try PortableExecutable.machine(dos))
    }

    func testMSISignature() {
        XCTAssertTrue(PortableExecutable.isMSI(Data([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0])))
        XCTAssertFalse(PortableExecutable.isMSI(pe(machine: 0x8664)))
    }

    func testProcessEnvironmentOfSelf() {
        let env = ProcessTable.environment(getpid())
        XCTAssertEqual(env["PATH"], ProcessInfo.processInfo.environment["PATH"])
        XCTAssertTrue(ProcessTable.pids().contains(getpid()))
        XCTAssertNotNil(ProcessTable.path(getpid()))
    }

    func testWindowsPathMapping() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("twinsim-wine-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let wine = Wine(config: try Configuration(["TWINSIM_HOME": home.path, "TWINSIM_ADB_PORT": "5999"]), scratch: home)
        let url = try wine.hostPath("p1", windowsPath: #"C:\users\Public\a.txt"#)
        XCTAssertTrue(url.path.hasSuffix("/wine/prefixes/p1/drive_c/users/Public/a.txt"), url.path)
        XCTAssertThrowsError(try wine.hostPath("p1", windowsPath: #"C:\..\..\etc\passwd"#))
        XCTAssertThrowsError(try wine.hostPath("p1", windowsPath: #"D:\x"#))
        XCTAssertThrowsError(try wine.hostPath("p1", windowsPath: "/etc/passwd"))
    }
}
