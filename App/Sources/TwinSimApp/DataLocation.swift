import Darwin
import Foundation
import TwinSimAgentProtocol

/// Validation and relocation of the TwinSim data directory (devices, Simulator device set, imported
/// apps, downloaded engines). It can live on an external APFS/HFS+ drive.
enum DataLocation {
    struct VolumeInfo {
        var name: String
        var format: String          // statfs f_fstypename, e.g. apfs, hfs, exfat
        var freeBytes: Int64
        var isRemovable: Bool
        var supported: Bool { ["apfs", "hfs"].contains(format) }
    }

    struct Problem: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func volume(of path: String) -> VolumeInfo? {
        var existing = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(existing.path, &info) == 0 else { return nil }
        let format = withUnsafePointer(to: &info.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        let values = try? existing.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeAvailableCapacityForImportantUsageKey,
                                                            .volumeIsRemovableKey, .volumeIsInternalKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? Int64(info.f_bavail) * Int64(info.f_bsize)
        return VolumeInfo(name: values?.volumeLocalizedName ?? existing.path, format: format, freeBytes: free,
                          isRemovable: values?.volumeIsRemovable == true || values?.volumeIsInternal == false)
    }

    /// Total allocated size of a directory tree.
    static func size(of path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                          includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Whether the configured data directory is reachable (an external drive may be unplugged).
    static func isAvailable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func hasData(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path + "/state.json") }

    /// Checks a destination folder (TwinSim stores its data in `<folder>/TwinSim`).
    static func validate(destination: String, current: String, requiredBytes: Int64) throws {
        let dest = URL(fileURLWithPath: destination).standardizedFileURL.path
        let cur = URL(fileURLWithPath: current).standardizedFileURL.path
        if dest == cur { throw Problem(message: "新位置与当前数据目录相同。") }
        if dest.hasPrefix(cur + "/") { throw Problem(message: "新位置不能在当前数据目录里面。") }
        if cur.hasPrefix(dest + "/") { throw Problem(message: "新位置不能包含当前数据目录。") }
        guard let volume = volume(of: dest) else { throw Problem(message: "无法读取目标磁盘信息。") }
        guard volume.supported else {
            throw Problem(message: "「\(volume.name)」的格式是 \(volume.format)。模拟器数据需要 APFS 或 Mac OS 扩展（HFS+）格式的磁盘，exFAT/FAT/NTFS 不支持文件权限、扩展属性和稀疏文件。请用「磁盘工具」把外置硬盘（或其中一个分区）格式化为 APFS。")
        }
        if FileManager.default.fileExists(atPath: dest), !hasData(dest),
           let items = try? FileManager.default.contentsOfDirectory(atPath: dest), !items.filter({ $0 != ".DS_Store" }).isEmpty {
            throw Problem(message: "\(dest) 已存在且不是空目录。请选择其他位置。")
        }
        let margin: Int64 = 1 << 30
        if !hasData(dest), volume.freeBytes < requiredBytes + margin {
            throw Problem(message: "「\(volume.name)」可用空间 \(Labels.bytes(volume.freeBytes))，移动需要约 \(Labels.bytes(requiredBytes + margin))。")
        }
        let parent = (dest as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: FileManager.default.fileExists(atPath: dest) ? dest : parent) else {
            throw Problem(message: "没有写入 \(dest) 的权限。")
        }
    }

    /// Names that are recreated by the backend and are not copied.
    static let transient: Set<String> = [".lock", "scratch", "agent.sock", ".DS_Store"]

    /// Copies `source` into `destination` with ditto (preserving permissions, extended attributes and
    /// sparse files), reporting byte-weighted progress. Then rewrites absolute paths in AVD config files.
    static func copy(from source: String, to destination: String,
                     progress: @escaping @Sendable (Double, String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = try fm.contentsOfDirectory(atPath: source).filter { !transient.contains($0) }
        // Pre-scan sizes so progress follows bytes, not file counts.
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for entry in entries {
            let base = URL(fileURLWithPath: source).appendingPathComponent(entry)
            let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            var files: [URL] = [base]
            while let next = walker?.nextObject() as? URL { files.append(next) }
            for url in files {
                let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                guard v?.isRegularFile == true else { continue }
                let size = Int64(v?.totalFileAllocatedSize ?? 0)
                sizes[url.standardizedFileURL.path] = size
                total += size
            }
        }
        var done: Int64 = 0
        for entry in entries {
            let from = URL(fileURLWithPath: source).appendingPathComponent(entry).path
            let to = URL(fileURLWithPath: destination).appendingPathComponent(entry).path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-V", from, to]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            try process.run()
            var buffer = Data()
            var previous: String?
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard line.hasPrefix("copying file ") else { continue }
                    if let previous { done += sizes[previous] ?? 0 }
                    var rel = String(line.dropFirst("copying file ".count))
                    if rel.hasSuffix(" ... ") { rel.removeLast(5) } else if rel.hasSuffix(" ...") { rel.removeLast(4) }
                    // ditto reports paths relative to the source item ("./x"), or the item itself.
                    let path = rel == "." || rel.isEmpty ? from
                        : URL(fileURLWithPath: from).appendingPathComponent(String(rel.hasPrefix("./") ? rel.dropFirst(2) : Substring(rel))).standardizedFileURL.path
                    previous = path
                    progress(total > 0 ? Double(done) / Double(total) : 0, entry)
                }
            }
            process.waitUntilExit()
            if let previous { done += sizes[previous] ?? 0 }
            guard process.terminationStatus == 0 else {
                throw Problem(message: "复制 \(entry) 失败（ditto 状态 \(process.terminationStatus)）。磁盘空间不足或磁盘被拔出时会出现这种情况。")
            }
            progress(total > 0 ? Double(done) / Double(total) : 1, entry)
        }
        try rewriteAndroidPaths(in: destination, from: source)
        progress(1, "")
    }

    /// AVD .ini files (and quick-boot snapshot hardware.ini) record absolute paths.
    static func rewriteAndroidPaths(in destination: String, from source: String) throws {
        let avd = URL(fileURLWithPath: destination).appendingPathComponent("jidr/data/avd")
        guard let walker = FileManager.default.enumerator(at: avd, includingPropertiesForKeys: nil) else { return }
        let old = URL(fileURLWithPath: source).standardizedFileURL.path
        let new = URL(fileURLWithPath: destination).standardizedFileURL.path
        for case let url as URL in walker where url.pathExtension == "ini" {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(old) else { continue }
            try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
