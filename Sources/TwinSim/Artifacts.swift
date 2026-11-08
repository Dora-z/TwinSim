import CryptoKit
import Foundation

struct Importer: Sendable {
    let directory: URL
    let scratch: URL

    func location(_ artifact: Artifact) -> URL {
        directory.appendingPathComponent(artifact.id.uuidString).appendingPathComponent(artifact.filename)
    }

    func load(_ source: URL, name: String? = nil) async throws -> Artifact {
        let filename = name ?? source.lastPathComponent
        guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.isEmpty else {
            throw BackendError("INVALID_ARTIFACT", "The artifact must have a filename.")
        }
        let kind: Artifact.Kind
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "apk": kind = .apk
        case "ipa": kind = .ipa
        case "app": kind = .simulatorApp
        case "exe": kind = .windowsExe
        case "msi": kind = .windowsMsi
        default: throw BackendError("UNSUPPORTED_ARTIFACT", "Select an APK, an IPA, an iOS Simulator .app bundle, or a Windows .exe/.msi.")
        }
        let source = source.resolvingSymlinksInPath()
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString)
        try Files.directory(folder)
        let saved = folder.appendingPathComponent(filename)
        do {
            let input = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard kind == .simulatorApp ? input.isDirectory == true : input.isRegularFile == true else {
                throw BackendError("INVALID_ARTIFACT", "The selected path does not match the artifact type.")
            }
            try FileManager.default.copyItem(at: source, to: saved)
            let bundle: String
            let digest: String
            switch kind {
            case .apk:
                let entries = try await zipEntries(saved)
                guard entries.contains("AndroidManifest.xml") else {
                    throw BackendError("INVALID_APK", "The APK does not contain AndroidManifest.xml.")
                }
                let abis = Set(entries.compactMap { entry -> String? in
                    let parts = entry.split(separator: "/")
                    return parts.count >= 3 && parts[0] == "lib" && entry.hasSuffix(".so") ? String(parts[1]) : nil
                })
                guard abis.isEmpty || abis.contains("arm64-v8a") else {
                    throw BackendError("APK_ABI_UNSUPPORTED", "The APK has no ARM64 native libraries.")
                }
                bundle = try AndroidManifest.package(try await zipEntry(saved, "AndroidManifest.xml", limit: 4 << 20))
                digest = try Files.sha256(saved)
            case .ipa:
                let entries = try await zipEntries(saved)
                let info = entries.filter { $0.hasPrefix("Payload/") && $0.hasSuffix(".app/Info.plist") && $0.split(separator: "/").count == 3 }
                guard info.count == 1, let manifest = info.first else {
                    throw BackendError("INVALID_IPA", "Expected one application in Payload.")
                }
                let properties = try Self.appProperties(try await zipEntry(saved, manifest, limit: 4 << 20))
                let executable = String(manifest.dropLast("Info.plist".count)) + properties.executable
                let data = try await zipEntry(saved, executable, limit: 256 << 20)
                try MachO.check(data, simulator: false)
                bundle = properties.bundle
                digest = try Files.sha256(saved)
            case .windowsExe, .windowsMsi:
                let handle = try FileHandle(forReadingFrom: saved)
                let header = try handle.read(upToCount: 1 << 20) ?? Data()
                try? handle.close()
                if kind == .windowsMsi {
                    guard PortableExecutable.isMSI(header) else {
                        throw BackendError("INVALID_MSI", "The file is not a Windows Installer package.")
                    }
                } else {
                    switch try PortableExecutable.machine(header) {
                    case .x86, .x64: break
                    case .arm64:
                        throw BackendError("APP_ARCH_UNSUPPORTED", "ARM64 Windows programs cannot run in Wine on macOS; use the x86 or x64 build.")
                    case .other(let machine):
                        throw BackendError("APP_ARCH_UNSUPPORTED", String(format: "Unsupported Windows machine type 0x%04x.", machine))
                    }
                }
                digest = try Files.sha256(saved)
                let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent.lowercased()
                    .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                bundle = "win." + (stem.isEmpty ? "app" : String(stem.prefix(60))) + "." + digest.prefix(8)
            case .simulatorApp:
                digest = try Self.bundleHash(saved)
                let manifest = saved.appendingPathComponent("Info.plist")
                guard (1...(4 << 20)).contains(Files.size(manifest)) else {
                    throw BackendError("INVALID_APP", "The app bundle has no readable Info.plist.")
                }
                let properties = try Self.appProperties(Data(contentsOf: manifest))
                let executable = saved.appendingPathComponent(properties.executable)
                try MachO.check(Data(contentsOf: executable, options: [.mappedIfSafe]), simulator: true)
                bundle = properties.bundle
            }
            guard Self.identifier(bundle) else {
                throw BackendError("INVALID_BUNDLE_ID", "The application identifier is not valid.")
            }
            return Artifact(id: id, name: filename, kind: kind, bundleId: bundle, sha256: digest, filename: filename)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func identifier(_ id: String) -> Bool {
        id.count <= 240 && id.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }

    private func zipEntries(_ url: URL) async throws -> Set<String> {
        let output = try await Command("/usr/bin/unzip", ["-Z1", url.path]).run(in: scratch, limit: 8 << 20)
        let entries = output.text.split(whereSeparator: \.isNewline).map(String.init)
        let unique = Set(entries)
        guard entries.count == unique.count, entries.count <= 100_000,
              unique.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("\\") && !$0.split(separator: "/").contains("..") }) else {
            throw BackendError("INVALID_ARCHIVE", "Archive entries are duplicated or contain unsafe paths.")
        }
        return unique
    }

    private func zipEntry(_ url: URL, _ entry: String, limit: Int) async throws -> Data {
        guard !entry.contains(where: { "*?[]".contains($0) }) else {
            throw BackendError("INVALID_ARCHIVE", "Unexpected wildcard in an archive path.")
        }
        return try await Command("/usr/bin/unzip", ["-p", url.path, entry]).run(in: scratch, limit: limit).data
    }

    private static func appProperties(_ data: Data) throws -> (bundle: String, executable: String) {
        guard let properties = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundle = properties["CFBundleIdentifier"] as? String,
              let executable = properties["CFBundleExecutable"] as? String,
              identifier(executable), executable != ".", executable != ".." else {
            throw BackendError("INVALID_APP", "The app bundle is missing a valid identifier or executable.")
        }
        return (bundle, executable)
    }

    private static func bundleHash(_ root: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw BackendError("INVALID_APP", "Cannot read the app bundle.")
        }
        var entries = [URL]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw BackendError("INVALID_APP", "The app bundle contains a link or special file.")
            }
            if values.isRegularFile == true { entries.append(url) }
        }
        var digest = SHA256()
        for url in entries.sorted(by: { $0.path < $1.path }) {
            digest.update(data: Data(url.path.dropFirst(root.path.count).utf8))
            digest.update(data: Data([0]))
            digest.update(data: Data(try Files.sha256(url).utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct Binary {
    let data: Data

    func uint(_ offset: Int, _ size: Int = 4, big: Bool = false) throws -> Int {
        guard offset >= 0, size > 0, offset <= data.count - size else {
            throw BackendError("TRUNCATED_BINARY", "The application metadata is truncated.")
        }
        var value: UInt64 = 0
        for index in 0..<size {
            let byte = data[offset + (big ? index : size - index - 1)]
            value = (value << 8) | UInt64(byte)
        }
        guard let result = Int(exactly: value) else { throw BackendError("INVALID_BINARY", "An application offset is out of range.") }
        return result
    }

    func string(_ offset: Int, _ count: Int, _ encoding: String.Encoding) throws -> String {
        guard offset >= 0, count >= 0, offset <= data.count - count,
              let value = String(data: data.subdata(in: offset..<(offset + count)), encoding: encoding) else {
            throw BackendError("TRUNCATED_BINARY", "An application metadata string is invalid.")
        }
        return value
    }
}

private enum AndroidManifest {
    static func package(_ data: Data) throws -> String {
        let file = Binary(data: data)
        guard try file.uint(0, 2) == 3 else {
            throw BackendError("INVALID_APK", "AndroidManifest.xml is not Android binary XML.")
        }
        var offset = try file.uint(2, 2)
        var pool: Int?
        while offset <= data.count - 8 {
            let type = try file.uint(offset, 2)
            let length = try file.uint(offset + 4)
            guard length >= 8, length <= data.count - offset else { break }
            if type == 1 { pool = offset }
            if type == 0x102, let pool {
                let end = offset + length
                let ext = offset + (try file.uint(offset + 2, 2))
                guard ext >= offset + 16, ext <= end - 20 else { break }
                if try string(file, pool, file.uint(ext + 4)) == "manifest" {
                    let start = ext + (try file.uint(ext + 8, 2))
                    let size = try file.uint(ext + 10, 2)
                    let count = try file.uint(ext + 12, 2)
                    guard size >= 20, start >= ext + 20, start <= end, count <= (end - start) / size else { break }
                    for index in 0..<count {
                        let attr = start + index * size
                        if try string(file, pool, file.uint(attr + 4)) == "package" {
                            let raw = try file.uint(attr + 8)
                            return try string(file, pool, raw == 0xffffffff ? file.uint(attr + 16) : raw)
                        }
                    }
                }
            }
            offset += length
        }
        throw BackendError("INVALID_APK", "No package name was found in the Android manifest.")
    }

    private static func string(_ file: Binary, _ pool: Int, _ index: Int) throws -> String {
        let count = try file.uint(pool + 8)
        let header = try file.uint(pool + 2, 2)
        let size = try file.uint(pool + 4)
        guard header >= 28, index < count, index < (size - header) / 4 else {
            throw BackendError("INVALID_APK", "Invalid Android manifest string index.")
        }
        let table = try file.uint(pool + 20)
        var offset = pool + table + (try file.uint(pool + header + index * 4))
        guard offset < pool + size else { throw BackendError("INVALID_APK", "Invalid Android manifest string offset.") }
        if try file.uint(pool + 16) & 0x100 != 0 {
            func length() throws -> Int {
                let first = try file.uint(offset, 1)
                offset += 1
                if first & 0x80 == 0 { return first }
                let second = try file.uint(offset, 1)
                offset += 1
                return ((first & 0x7f) << 8) | second
            }
            _ = try length()
            let bytes = try length()
            return try file.string(offset, bytes, .utf8)
        }
        var units = try file.uint(offset, 2)
        offset += 2
        if units & 0x8000 != 0 {
            units = ((units & 0x7fff) << 16) | (try file.uint(offset, 2))
            offset += 2
        }
        return try file.string(offset, units * 2, .utf16LittleEndian)
    }
}

private enum MachO {
    static func check(_ data: Data, simulator: Bool) throws {
        let file = Binary(data: data)
        let magic = try file.uint(0, big: true)
        let arm64 = 0x0100000c
        var base = 0
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = try file.uint(4, big: true)
            let wide = magic == 0xcafebabf
            let stride = wide ? 32 : 20
            guard count <= 64 else { throw BackendError("INVALID_MACHO", "Invalid universal application executable.") }
            for index in 0..<count {
                let entry = 8 + index * stride
                if try file.uint(entry, big: true) == arm64 {
                    base = try file.uint(entry + 8, wide ? 8 : 4, big: true)
                    break
                }
            }
        }
        guard base <= data.count - 32, try file.uint(base) == 0xfeedfacf, try file.uint(base + 4) == arm64 else {
            throw BackendError("APP_ARCH_UNSUPPORTED", "The application requires an ARM64 Mach-O slice.")
        }
        let count = try file.uint(base + 16)
        let size = try file.uint(base + 20)
        guard size <= data.count - base - 32, count <= size / 8 else {
            throw BackendError("INVALID_MACHO", "Invalid Mach-O load commands.")
        }
        let end = base + 32 + size
        var offset = base + 32
        var platform: Int?
        for _ in 0..<count {
            let command = try file.uint(offset)
            let length = try file.uint(offset + 4)
            guard length >= 8, length <= end - offset else { throw BackendError("INVALID_MACHO", "Invalid Mach-O command size.") }
            if command == 0x32, length >= 24 { platform = try file.uint(offset + 8) }
            if command == 0x25, platform == nil { platform = 2 }
            if (command == 0x21 || command == 0x2c), length >= 20, try file.uint(offset + 16) != 0 {
                throw BackendError("IPA_ENCRYPTED", "The app executable is encrypted. Import an authorized unencrypted build.")
            }
            offset += length
        }
        guard platform == (simulator ? 7 : 2) else {
            throw BackendError("APP_PLATFORM_MISMATCH", simulator ? "Build this app for iOS Simulator." : "This IPA must contain an iOS device executable.")
        }
    }
}
