import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import PDFKit

/// Windows programs on macOS through upstream Wine (WineHQ macOS builds by Gcenx), without
/// CrossOver. A "device" is a Wine prefix. x86 and x64 programs run through Rosetta 2 (Wine's new
/// WoW64 mode handles 32-bit programs without 32-bit host libraries). Direct3D goes through
/// Wine's Vulkan renderer -> MoltenVK -> Metal; DXVK can be enabled per device for D3D10/11.
struct Wine: Sendable {
    static let version = "11.21"
    static let source = "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-staging-11.21-osx64.tar.xz"
    static let downloadSize: Int64 = 228_148_688
    static let checksum = "d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452"
    static let bundleName = "Wine Staging.app"
    static let setupURL = "https://support.apple.com/102527"

    static let dxvkVersion = "1.10.3-async (DXVK-macOS 20230507 repack)"
    static let dxvkSource = "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"
    static let dxvkSize: Int64 = 2_785_833
    static let dxvkChecksum = "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00"
    static let dxvkFolder = "dxvk-macOS-async-v1.10.3-20230507-repack-builtin"

    /// Apple Game Porting Toolkit 3.0 Wine (built from Apple's open-source GPTK sources) with Apple's
    /// D3DMetal (Direct3D 11/12 -> Metal), as distributed by Gcenx. D3DMetal is licensed by Apple;
    /// the license document is fetched, shown verbatim and must be accepted before download.
    static let gptkVersion = "3.0-3"
    static let gptkSource = "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz"
    static let gptkSize: Int64 = 239_200_808
    static let gptkChecksum = "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e"
    static let gptkBundle = "Game Porting Toolkit.app"
    static let gptkLicenseURL = "https://github.com/user-attachments/files/23971305/License.pdf"
    static let gptkLicenseChecksum = "b099088947b67c1707de9b8e8f8dd5e03a4af8048451e455b9044553beeabcf8"
    static let gptkLicenseID = "apple-game-porting-toolkit-3.0"

    enum Runtime: String, Codable, Sendable { case upstream, gptk }

    let config: Configuration
    let scratch: URL

    var runtime: URL { config.root.appendingPathComponent("runtime/wine-staging-\(Self.version)") }
    var gptkRuntime: URL { config.root.appendingPathComponent("runtime/game-porting-toolkit-\(Self.gptkVersion)") }
    var gptkLicenseFile: URL { config.root.appendingPathComponent("runtime/licenses/game-porting-toolkit-3.0-License.pdf") }

    func root(_ kind: Runtime) -> URL {
        switch kind {
        case .upstream: runtime.appendingPathComponent("\(Self.bundleName)/Contents/Resources/wine")
        case .gptk: gptkRuntime.appendingPathComponent("\(Self.gptkBundle)/Contents/Resources/wine")
        }
    }

    static func executable(_ kind: Runtime) -> String { kind == .gptk ? "wine64" : "wine" }

    func bin(_ kind: Runtime) -> URL? {
        if kind == .upstream { return bin }
        if let override = config.environment["TWINSIM_GPTK"] {
            let dir = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("wine64").path) ? dir : nil
        }
        let dir = root(.gptk).appendingPathComponent("bin")
        return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("wine64").path) ? dir : nil
    }

    func installed(_ kind: Runtime) -> Bool { bin(kind) != nil }
    func runtime(_ driver: String) -> Runtime { settings(driver).runtime }
    var dxvk: URL { config.root.appendingPathComponent("runtime/dxvk-macos-1.10.3/\(Self.dxvkFolder)") }
    var prefixes: URL { config.root.appendingPathComponent("wine/prefixes") }
    var logs: URL { config.root.appendingPathComponent("wine/logs") }

    /// Directory with `wine` and `wineserver` (TWINSIM_WINE overrides it for testing).
    var bin: URL? {
        if let override = config.environment["TWINSIM_WINE"] {
            let url = URL(fileURLWithPath: override)
            let dir = url.lastPathComponent == "wine" ? url.deletingLastPathComponent() : url
            return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("wine").path) ? dir : nil
        }
        let dir = runtime.appendingPathComponent("\(Self.bundleName)/Contents/Resources/wine/bin")
        return FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("wine").path) ? dir : nil
    }
    var installed: Bool { bin != nil }
    var dxvkInstalled: Bool { FileManager.default.fileExists(atPath: dxvk.appendingPathComponent("x86_64-windows/d3d11.dll").path) }

    static var rosettaAvailable: Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        probe.arguments = ["-x86_64", "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    func prefix(_ driver: String) -> URL { prefixes.appendingPathComponent(driver) }
    func log(_ driver: String) -> URL { logs.appendingPathComponent(driver + ".log") }
    func settingsFile(_ driver: String) -> URL { prefix(driver).appendingPathComponent("twinsim.json") }

    struct Settings: Codable {
        var dxvk = false
        var retina = true
        var runtime: Runtime = .upstream

        init(runtime: Runtime = .upstream) { self.runtime = runtime }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dxvk = try c.decodeIfPresent(Bool.self, forKey: .dxvk) ?? false
            retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? true
            runtime = try c.decodeIfPresent(Runtime.self, forKey: .runtime) ?? .upstream
        }
    }

    func settings(_ driver: String) -> Settings {
        (try? JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsFile(driver)))) ?? Settings()
    }

    func save(_ settings: Settings, _ driver: String) throws {
        try JSONEncoder().encode(settings).write(to: settingsFile(driver), options: .atomic)
    }

    /// Environment for every Wine process of a device. Performance defaults: only error output
    /// (no fixme/trace logging), Rosetta AVX/AVX2 advertised, host menu integration off, MoltenVK
    /// recovers lost devices; DXVK (async shader compilation) when enabled for the device.
    func environment(_ driver: String) throws -> [String: String] {
        let kind = runtime(driver)
        guard let bin = bin(kind) else {
            throw kind == .gptk ? BackendError("D3DMETAL_MISSING", "Install the windows-d3dmetal component first.")
                : BackendError("WINE_MISSING", "Install the windows-wine component first.")
        }
        var env = config.environment.filter { !$0.key.hasPrefix("DYLD_") && $0.key != "WINEPREFIX" }
        env["WINEPREFIX"] = prefix(driver).path
        env["WINEDEBUG"] = config.environment["TWINSIM_WINEDEBUG"] ?? "fixme-all"
        env["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["MVK_CONFIG_RESUME_LOST_DEVICE"] = "1"
        env["MVK_CONFIG_LOG_LEVEL"] = config.environment["TWINSIM_MVK_LOG_LEVEL"] ?? "1"   // MoltenVK: errors only
        env["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        if kind == .gptk {
            // CrossOver-based GPTK Wine: Mach-semaphore synchronisation; D3DMetal handles D3D11/12.
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
            env["MTL_HUD_ENABLED"] = config.environment["TWINSIM_METAL_HUD"] ?? "0"
        } else if settings(driver).dxvk, dxvkInstalled {
            env["WINEDLLPATH_PREPEND"] = dxvk.path
            env["DXVK_ASYNC"] = "1"
            env["DXVK_LOG_LEVEL"] = "none"
        }
        return env
    }

    // MARK: Components

    func setup(_ update: @escaping ProgressUpdate) async throws {
        if installed { return }
        try await download(Self.source, size: Self.downloadSize, checksum: Self.checksum, stage: "downloading-wine",
                           into: runtime, update: update) { archive, stage in
            await update("extracting-wine", nil, nil)
            _ = try await Command("/usr/bin/tar", ["-xJf", archive.path, "-C", stage.path], timeout: 900).run(in: scratch)
            guard FileManager.default.fileExists(atPath: stage.appendingPathComponent(Self.bundleName).path) else {
                throw BackendError("INVALID_ARCHIVE", "The Wine archive does not contain \(Self.bundleName).")
            }
        }
    }

    func setupGPTK(_ update: @escaping ProgressUpdate) async throws {
        if installed(.gptk) { return }
        try await download(Self.gptkSource, size: Self.gptkSize, checksum: Self.gptkChecksum, stage: "downloading-d3dmetal",
                           into: gptkRuntime, update: update) { archive, stage in
            await update("extracting-d3dmetal", nil, nil)
            _ = try await Command("/usr/bin/tar", ["-xJf", archive.path, "-C", stage.path], timeout: 900).run(in: scratch)
            guard FileManager.default.fileExists(atPath: stage.appendingPathComponent(Self.gptkBundle).path) else {
                throw BackendError("INVALID_ARCHIVE", "The archive does not contain \(Self.gptkBundle).")
            }
        }
    }

    /// Apple's license for the Game Porting Toolkit / D3DMetal, fetched (pinned SHA-256) and shown verbatim.
    func gptkLicense() async throws -> LicenseText {
        if Files.size(gptkLicenseFile) == 0 || (try? Files.sha256(gptkLicenseFile)) != Self.gptkLicenseChecksum {
            try Files.directory(gptkLicenseFile.deletingLastPathComponent())
            let partial = gptkLicenseFile.appendingPathExtension("download")
            _ = try await Command("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--connect-timeout", "15",
                                                   "--max-time", "60", "--output", partial.path, Self.gptkLicenseURL], timeout: 90)
                .run(in: scratch)
            guard try Files.sha256(partial) == Self.gptkLicenseChecksum else {
                try? FileManager.default.removeItem(at: partial)
                throw BackendError("LICENSE_UNAVAILABLE", "The Game Porting Toolkit license did not match its pinned checksum.", retryable: true)
            }
            try? FileManager.default.removeItem(at: gptkLicenseFile)
            try FileManager.default.moveItem(at: partial, to: gptkLicenseFile)
        }
        guard let text = PDFDocument(url: gptkLicenseFile)?.string, !text.isEmpty else {
            throw BackendError("LICENSE_UNAVAILABLE", "The Game Porting Toolkit license could not be read.", retryable: true)
        }
        let body = "Source: \(Self.gptkLicenseURL) (SHA-256 \(Self.gptkLicenseChecksum))\n\n" + text
        return LicenseText(id: Self.gptkLicenseID, sha256: SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined(), text: body)
    }

    func setupDXVK(_ update: @escaping ProgressUpdate) async throws {
        if dxvkInstalled { return }
        try await download(Self.dxvkSource, size: Self.dxvkSize, checksum: Self.dxvkChecksum, stage: "downloading-dxvk",
                           into: dxvk.deletingLastPathComponent(), update: update) { archive, stage in
            _ = try await Command("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path], timeout: 120).run(in: scratch)
        }
    }

    /// Resumable, checksum-verified download, extracted into a staging folder and moved into place.
    private func download(_ url: String, size: Int64, checksum: String, stage label: String, into target: URL,
                          update: @escaping ProgressUpdate, extract: (URL, URL) async throws -> Void) async throws {
        try Files.directory(target.deletingLastPathComponent())
        let archive = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".download")
        if Files.size(archive) != size {
            _ = try await Command("/usr/bin/curl", ["--fail", "--location", "--silent", "--show-error", "--connect-timeout", "20",
                                                   "--retry", "3", "--continue-at", "-", "--output", archive.path, url],
                                  timeout: 3600)
                .run(in: scratch, heartbeat: { await update(label, Files.size(archive), size) })
        }
        await update("verifying", size, size)
        guard Files.size(archive) == size, try Files.sha256(archive) == checksum else {
            try? FileManager.default.removeItem(at: archive)
            throw BackendError("CHECKSUM_MISMATCH", "The download did not match its pinned SHA-256.", retryable: true)
        }
        let stage = try Files.scratch(in: scratch)
        defer { try? FileManager.default.removeItem(at: stage) }
        try await extract(archive, stage)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: stage, to: target)
        try? FileManager.default.removeItem(at: archive)
    }

    // MARK: Prefix lifecycle

    func create(_ device: Device) async throws -> String {
        let kind: Runtime = device.profileId == .d3dmetal ? .gptk : .upstream
        guard installed(kind) else {
            throw BackendError("COMPONENT_REQUIRED", kind == .gptk ? "Install windows-d3dmetal first." : "Install windows-wine first.")
        }
        guard Self.rosettaAvailable else { throw BackendError("ROSETTA_MISSING", "Install Rosetta 2 to run Windows programs.") }
        let driver = device.driverName
        try Files.directory(prefixes)
        try Files.directory(logs)
        try Files.directory(prefix(driver))
        try save(Settings(runtime: kind), driver)
        try await wine(driver, ["wineboot", "--init"], timeout: 900)
        try await applyDisplay(driver, retina: true)
        try await server(driver, ["-w"], timeout: 120)
        return driver
    }

    /// Runs a Wine command to completion, appending its output to the device log.
    @discardableResult
    func wine(_ driver: String, _ args: [String], timeout: TimeInterval = 120, check: Bool = true) async throws -> Command.Output {
        let kind = runtime(driver)
        guard let bin = bin(kind) else { throw BackendError("WINE_MISSING", "Install the Windows runtime for this device first.") }
        let output = try await Command(bin.appendingPathComponent(Self.executable(kind)).path, args, environment: environment(driver), timeout: timeout)
            .run(in: scratch, check: false)
        appendLog(driver, output.text + output.stderr)
        if check && output.code != 0 {
            throw BackendError("WINE_FAILED", "wine \(args.joined(separator: " ")) exited with \(output.code): \(String(output.stderr.suffix(800)))")
        }
        return output
    }

    @discardableResult
    func server(_ driver: String, _ args: [String], timeout: TimeInterval = 60) async throws -> Command.Output {
        guard let bin = bin(runtime(driver)) else { throw BackendError("WINE_MISSING", "Install the Windows runtime for this device first.") }
        return try await Command(bin.appendingPathComponent("wineserver").path, args, environment: environment(driver), timeout: timeout)
            .run(in: scratch, check: false)
    }

    /// Retina rendering at 192 DPI for sharp text (default), or standard 96 DPI for programs that
    /// do not handle scaling.
    func applyDisplay(_ driver: String, retina: Bool) async throws {
        let dpi = retina ? "000000c0" : "00000060"
        let reg = """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]
        "RetinaMode"="\(retina ? "y" : "n")"

        [HKEY_CURRENT_USER\\Control Panel\\Desktop]
        "LogPixels"=dword:\(dpi)

        [HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts]
        "LogPixels"=dword:\(dpi)

        [HKEY_CURRENT_USER\\Software\\Wine\\WineDbg]
        "ShowCrashDialog"=dword:00000000

        [HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunServices]
        "winemenubuilder"=-

        [HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Run]
        "winemenubuilder"=-

        """
        let file = prefix(driver).appendingPathComponent("twinsim-display.reg")
        try reg.write(to: file, atomically: true, encoding: .utf8)
        try await wine(driver, ["regedit", "/S", file.path])
        var s = settings(driver)
        s.retina = retina
        try save(s, driver)
    }

    func start(_ driver: String) async throws {
        try Files.directory(logs)
        // Persistent server so programs start quickly; wineboot brings services up to date.
        try await server(driver, ["-p"])
        try await wine(driver, ["wineboot"], timeout: 300, check: false)
        guard isRunning(driver) else { throw BackendError("WINE_START_FAILED", "wineserver did not stay running.", retryable: true) }
    }

    func stop(_ driver: String) async throws {
        try await server(driver, ["-k"])
        try await server(driver, ["-w"], timeout: 60)
    }

    /// Whether any Wine process (wineserver or a Windows program) runs for this prefix.
    func isRunning(_ driver: String) -> Bool { !processes(driver).isEmpty }

    /// PIDs of processes from the Wine runtime whose WINEPREFIX is this device's prefix.
    func processes(_ driver: String) -> [pid_t] {
        let kind = runtime(driver)
        let root = bin(kind)?.deletingLastPathComponent().path ?? self.root(kind).path
        let base = kind == .gptk ? gptkRuntime.path : runtime.path
        let wanted = prefix(driver).standardizedFileURL.path
        return ProcessTable.pids().filter { pid in
            guard let path = ProcessTable.path(pid), path.hasPrefix(root) || path.hasPrefix(base) else { return false }
            return ProcessTable.environment(pid)["WINEPREFIX"].map { URL(fileURLWithPath: $0).standardizedFileURL.path } == wanted
        }
    }

    // MARK: Programs

    /// Starts a program detached (it keeps running after this request); output goes to the log.
    func spawn(_ driver: String, _ args: [String], workingDirectory: URL? = nil) throws {
        let kind = runtime(driver)
        guard let bin = bin(kind) else { throw BackendError("WINE_MISSING", "Install the Windows runtime for this device first.") }
        try Files.directory(logs)
        let logURL = log(driver)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        let process = Process()
        process.executableURL = bin.appendingPathComponent(Self.executable(kind))
        process.arguments = args
        process.environment = try environment(driver)
        process.currentDirectoryURL = workingDirectory ?? prefix(driver)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try? handle.close()
    }

    func appDirectory(_ driver: String, _ artifact: Artifact) -> URL {
        prefix(driver).appendingPathComponent("drive_c/TwinSim/Apps/\(artifact.id.uuidString)")
    }

    /// Copies the program into C:\TwinSim\Apps\<id>\ so it runs from inside the prefix.
    func install(_ driver: String, _ artifact: Artifact, from source: URL) throws {
        let dir = appDirectory(driver, artifact)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(artifact.filename)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }

    func launch(_ driver: String, _ artifact: Artifact) throws {
        let file = appDirectory(driver, artifact).appendingPathComponent(artifact.filename)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BackendError("APP_NOT_INSTALLED", "Install the program on this device first.")
        }
        appendLog(driver, "[twinsim] launch \(artifact.filename)\n")
        switch artifact.kind {
        case .windowsMsi: try spawn(driver, ["msiexec", "/i", file.path], workingDirectory: file.deletingLastPathComponent())
        default: try spawn(driver, ["start", "/unix", file.path], workingDirectory: file.deletingLastPathComponent())
        }
    }

    static let tools = ["winecfg": ["winecfg"], "regedit": ["regedit"], "taskmgr": ["taskmgr"], "cmd": ["wineconsole", "cmd"],
                        "explorer": ["explorer"], "control": ["control"], "uninstaller": ["uninstaller"], "notepad": ["notepad"]]

    /// Maps an absolute Windows path (C:\x\y) to the host file inside the prefix.
    func hostPath(_ driver: String, windowsPath: String) throws -> URL {
        var path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.count >= 3, path.dropFirst().hasPrefix(":/") else {
            throw BackendError("INVALID_PATH", "Use an absolute Windows path such as C:\\\\Users\\\\Public\\\\file.txt.")
        }
        let drive = path.prefix(1).lowercased()
        path.removeFirst(3)
        guard drive == "c", !path.split(separator: "/").contains("..") else {
            throw BackendError("INVALID_PATH", "Only paths on drive C: inside the prefix are supported.")
        }
        return prefix(driver).appendingPathComponent("drive_c").appendingPathComponent(path)
    }

    func appendLog(_ driver: String, _ text: String) {
        guard !text.isEmpty else { return }
        try? Files.directory(logs)
        let url = log(driver)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
        // Keep the log bounded.
        if Files.size(url) > 8 << 20, let data = try? Data(contentsOf: url) {
            try? data.suffix(4 << 20).write(to: url, options: .atomic)
        }
    }

    func logs(_ driver: String, lines: Int) -> String {
        guard let data = try? Data(contentsOf: log(driver)) else { return "" }
        return String(decoding: data.suffix(2 << 20), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    // MARK: Windows on screen

    struct WindowCapture: Sendable {
        let windowID: CGWindowID
        let bounds: CGRect        // global display points, top-left origin
        let pixelSize: CGSize     // size of the captured image
        let owner: pid_t
    }

    /// Frontmost normal window of this device's Wine processes.
    func mainWindow(_ driver: String) -> (CGWindowID, CGRect, pid_t)? {
        let pids = Set(processes(driver))
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // The list is front-to-back; prefer the first reasonably sized layer-0 window.
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 60 else { continue }
            return (id, bounds, pid)
        }
        return nil
    }

    func capture(_ driver: String) async throws -> (Data, WindowCapture) {
        guard let (id, bounds, pid) = mainWindow(driver) else {
            throw BackendError("NO_WINDOW", "No window of this Windows device is on screen. Open a program first.", retryable: true)
        }
        let folder = try Files.scratch(in: scratch)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("window.png")
        _ = try? await Command("/usr/sbin/screencapture", ["-x", "-o", "-t", "png", "-l\(id)", file.path], timeout: 30).run(in: scratch)
        guard let data = try? Data(contentsOf: file), data.starts(with: [0x89, 0x50, 0x4e, 0x47]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw BackendError("SCREEN_RECORDING_REQUIRED",
                               "macOS did not allow capturing the window. Allow TwinSim under System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
        return (data, WindowCapture(windowID: id, bounds: bounds, pixelSize: CGSize(width: w, height: h), owner: pid))
    }

    // MARK: Input (CGEvent; needs the Accessibility permission for TwinSim)

    static var inputAllowed: Bool { AXIsProcessTrusted() }

    @MainActor
    static func activate(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static func click(at point: CGPoint) throws {
        guard inputAllowed else {
            throw BackendError("ACCESSIBILITY_REQUIRED", "Allow TwinSim under System Settings > Privacy & Security > Accessibility to send input.")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.post(tap: .cghidEventTap)
            usleep(type == .leftMouseDown ? 40_000 : 15_000)
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
        "forward_delete": 117, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
        "page_up": 116, "page_down": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static func key(_ name: String) throws {
        guard inputAllowed else {
            throw BackendError("ACCESSIBILITY_REQUIRED", "Allow TwinSim under System Settings > Privacy & Security > Accessibility to send input.")
        }
        guard let code = keyCodes[name.lowercased()] else {
            throw BackendError("INVALID_INPUT", "Unknown key \(name). Use enter, tab, space, backspace, escape, arrows, home, end, page_up/down or f1-f12.")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    static func type(_ text: String) throws {
        guard inputAllowed else {
            throw BackendError("ACCESSIBILITY_REQUIRED", "Allow TwinSim under System Settings > Privacy & Security > Accessibility to send input.")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(units.count, index + 16)])
            index += chunk.count
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                event?.post(tap: .cghidEventTap)
            }
            usleep(15_000)
        }
    }
}

/// Process-table helpers (own-user processes only).
enum ProcessTable {
    static func pids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = buffer.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) }
        return Array(buffer.prefix(Int(max(0, filled)))).filter { $0 > 0 }
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Environment of a process via KERN_PROCARGS2 (argc, exec path, argv, then env strings).
    static func environment(_ pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return [:] }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && data[index] != 0 { index += 1 }       // exec path
        while index < size && data[index] == 0 { index += 1 }       // padding
        var strings: [String] = []
        var start = index
        while index < size {
            if data[index] == 0 {
                if index > start { strings.append(String(decoding: data[start..<index], as: UTF8.self)) }
                else if strings.count > Int(argc) { break }
                start = index + 1
            }
            index += 1
        }
        var env: [String: String] = [:]
        for entry in strings.dropFirst(Int(argc)) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }
}

/// Windows PE (.exe) and MSI checks for the importer.
enum PortableExecutable {
    enum Machine { case x86, x64, arm64, other(UInt16) }

    static func machine(_ data: Data) throws -> Machine {
        guard data.count > 0x40, data[0] == 0x4d, data[1] == 0x5a else {
            throw BackendError("INVALID_EXE", "The file is not a Windows executable (missing MZ header).")
        }
        let offset = Int(data.subdata(in: 0x3c..<0x40).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard offset > 0, offset + 6 <= data.count, data[offset] == 0x50, data[offset + 1] == 0x45,
              data[offset + 2] == 0, data[offset + 3] == 0 else {
            throw BackendError("INVALID_EXE", "The file is a DOS program or is damaged (no PE header).")
        }
        let value = data.subdata(in: (offset + 4)..<(offset + 6)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
        switch value {
        case 0x014c: return .x86
        case 0x8664: return .x64
        case 0xaa64: return .arm64
        default: return .other(value)
        }
    }

    static func isMSI(_ data: Data) -> Bool {
        data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
    }
}
