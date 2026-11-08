import Darwin
import Foundation

/// Local agent bridge shared by TwinSim.app (server) and the `twinsim` CLI / MCP server (client).
///
/// Transport: a Unix domain socket owned by the current user (mode 0600, peer UID checked), in the
/// per-user temporary directory and keyed by the data directory.
/// Framing: one JSON object per line in each direction. Requests carry an `id` that the
/// response echoes. The backend session token never leaves the app process; the app adds it
/// when it forwards `http` requests to twinsimd.
///
/// Request types:
///   {"id":1,"type":"hello"}
///   {"id":2,"type":"http","method":"GET|POST","path":"/v1/...","query":{"k":"v"},"body":{...},"idempotencyKey":"..."}
///   {"id":3,"type":"showWindow","instanceId":"UUID","artifactId":"UUID?"}
/// Responses: {"id":1,"ok":true,...} or {"id":1,"ok":false,"error":{"code":"...","message":"..."}}.
/// `http` responses: {"status":200,"contentType":"...","json":<value>} or {"status":200,"contentType":"image/png","base64":"..."}.
public enum AgentProtocol {
    public static let version = 1

    public static let defaultsDomain = "com.twinsim.app"
    public static let dataDirectoryKey = "dataDirectory"

    public static var defaultDataDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TwinSim").path
    }

    /// Data directory of the TwinSim instance: `TWINSIM_HOME`, else the location chosen in the
    /// app's settings (which may be on an external drive), else the default.
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["TWINSIM_HOME"], !home.isEmpty { return home }
        // Inside the app the domain is its own (UserDefaults rejects a suite equal to the bundle ID).
        let defaults = Bundle.main.bundleIdentifier == defaultsDomain ? UserDefaults.standard : UserDefaults(suiteName: defaultsDomain)
        if let chosen = defaults?.string(forKey: dataDirectoryKey), !chosen.isEmpty { return chosen }
        return defaultDataDirectory
    }

    /// Socket path for a data directory. It lives in the per-user temporary directory (keyed by the
    /// data directory) so it works when the data is on a drive that cannot hold sockets (exFAT)
    /// and stays short enough for sun_path.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        socketPath(forDataDirectory: dataDirectory(environment: environment))
    }

    public static func socketPath(forDataDirectory directory: String) -> String {
        let key = URL(fileURLWithPath: directory).standardizedFileURL.path
        var hash = UInt64(14_695_981_039_346_656_037)
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let tmp = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return (tmp as NSString).appendingPathComponent("twinsim-\(String(hash, radix: 16)).sock")
    }

    public static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}
