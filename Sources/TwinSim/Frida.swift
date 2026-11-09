import Foundation

/// frida-server bundled with TwinSim.app (Contents/Resources/Android/frida-server, android-arm64).
/// Started as root in the guest and reached through an ADB port forward on 127.0.0.1.
enum FridaServer {
    static let remotePath = "/data/local/tmp/twinsim-frida-server"
    static let processName = "twinsim-frida-server"
    static let guestPort = 27042

    /// Bundled binary next to the helper (…/Contents/Helpers/twinsimd → …/Contents/Resources/Android),
    /// or TWINSIM_FRIDA_SERVER for development builds.
    static func binary(_ environment: [String: String]) -> URL? {
        if let override = environment["TWINSIM_FRIDA_SERVER"], FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = helper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Android/frida-server")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }

    static func version(_ environment: [String: String]) -> String? {
        if let explicit = environment["TWINSIM_FRIDA_VERSION"] { return explicit }
        guard let binary = binary(environment) else { return nil }
        let file = binary.deletingLastPathComponent().appendingPathComponent("frida-server.version")
        return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct FridaView: Encodable {
    let version: String?
    let running: Bool
    let host: String
    let localPort: Int?
}
