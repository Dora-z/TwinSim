import Foundation

enum Engine: String, CaseIterable, Codable, Sendable {
    case android = "android-emulator"
    case simulator = "ios-simulator"
    case vphone = "ios-vphone"
    case windows = "windows-wine"
}

enum Profile: String, CaseIterable, Codable, Sendable {
    case android = "android-aosp"
    case research = "android-research"
    case magisk = "android-magisk"
    case google = "android-google-apis"
    case simulator = "ios-development"
    case vphone = "ios-research"
    case windows = "windows-desktop"
    case d3dmetal = "windows-d3dmetal"

    var engine: Engine {
        switch self {
        case .simulator: .simulator
        case .vphone: .vphone
        case .windows, .d3dmetal: .windows
        default: .android
        }
    }

    var image: String {
        "system-images;android-34;\(self == .google ? "google_apis" : "default");arm64-v8a"
    }

    var rootMode: String {
        switch self {
        case .research, .google: "adb"
        case .magisk: "magisk"
        default: "none"
        }
    }

    var component: String {
        switch engine {
        case .android: self == .google ? "android-google-apis" : "android-runtime"
        case .simulator: "ios-simulator-runtime"
        case .vphone: "ios-vphone"
        case .windows: self == .d3dmetal ? "windows-d3dmetal" : "windows-wine"
        }
    }
}

struct Capability: Codable, Sendable {
    let availability: String
    var reasonCode: String? = nil

    static let available = Self(availability: "available")
    static let unsupported = Self(availability: "unsupported")
    static func blocked(_ code: String) -> Self { Self(availability: "blocked", reasonCode: code) }
}

struct Device: Codable, Sendable {
    let id: UUID
    let name: String
    let profileId: Profile
    let engineId: Engine
    let purpose: String
    var externalName: String? = nil
    var driverID: String?
    var state: String
    var guestUid: Int? = nil
    var selinux: String? = nil
    var installed: [String: UUID] = [:]
    var forwardedPorts: [Int]? = nil
    /// Hardware tuning level applied to the engine device (Android: CPU cores and RAM).
    var hardwareTuning: Int? = nil
    /// Android CPU cores / RAM chosen for this device (nil = the default from Settings).
    var cpus: Int? = nil
    var ramMB: Int? = nil
    /// "cpus/ramMB" last written to the engine; differs from the desired values until applied.
    var appliedHardware: String? = nil
    /// Local port forwarded to the guest's frida-server while it runs.
    var fridaPort: Int? = nil

    var driverName: String { "twinsim-" + id.uuidString.lowercased() }
}

struct InstanceView: Encodable {
    let id: UUID
    let name: String
    let profileId: Profile
    let engineId: Engine
    let purpose: String
    let state: String
    let guestUid: Int?
    let selinux: String?
    let capabilities: [String: Capability]
    var hardware: HardwareView? = nil
    var frida: FridaView? = nil

    init(_ device: Device, capabilities: [String: Capability]) {
        id = device.id
        name = device.name
        profileId = device.profileId
        engineId = device.engineId
        purpose = device.purpose
        state = device.state
        guestUid = device.guestUid
        selinux = device.selinux
        self.capabilities = capabilities
    }
}

struct HardwareView: Encodable {
    let cpus: Int
    let ramMB: Int
    /// Whether these values come from the device itself (false: the default).
    let custom: Bool
    /// true when the device runs with different values that apply on its next start.
    let pending: Bool
    let maxCpus: Int
    let maxRamMB: Int
}

struct Artifact: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case apk, ipa, simulatorApp, windowsExe, windowsMsi
        var engine: Engine {
            switch self {
            case .apk: .android
            case .ipa: .vphone
            case .simulatorApp: .simulator
            case .windowsExe, .windowsMsi: .windows
            }
        }
    }

    let id: UUID
    let name: String
    let kind: Kind
    let bundleId: String
    let sha256: String
    let filename: String
}

struct Operation: Codable, Sendable {
    let id: UUID
    let action: String
    var state: String
    var instanceId: UUID?
    var stage: String?
    var receivedBytes: Int64?
    var totalBytes: Int64?
    var result: [String: String]?
    var error: BackendError?
}

struct State: Codable {
    var instances: [UUID: Device] = [:]
    var artifacts: [UUID: Artifact] = [:]
    var operations: [UUID: Operation] = [:]
    var idempotency: [String: Idempotency] = [:]
}

struct Idempotency: Codable {
    let fingerprint: String
    let operation: UUID
}

struct LicenseText: Codable, Sendable {
    let id: String
    let sha256: String
    let text: String
}

struct Component: Codable, Sendable {
    let id: String
    let status: String
    var version: String? = nil
    var source: String? = nil
    var downloadBytes: Int64? = nil
    var requiredFreeBytes: Int64? = nil
    var reasonCode: String? = nil
    var licenses: [LicenseText]? = nil
}

struct CreateRequest: Decodable {
    let engineId: Engine
    let profileId: Profile
    let name: String
    let externalName: String?
    var cpus: Int? = nil
    var ramMB: Int? = nil
}

struct ImportRequest: Decodable { let path: String }

struct InstallComponentRequest: Decodable {
    var acceptLicenses: [String: String]?
}

struct ActionRequest: Decodable {
    var artifactId: UUID?
    var bundleId: String?
    var snapshot: String?
    var x: Int?
    var y: Int?
    var value: String?
    var argv: [String]?
    var localPath: String?
    var remotePath: String?
    var guestPort: Int?
    var localPort: Int?
    var cpus: Int?
    var ramMB: Int?
    /// Clear the device's own values and follow the default again.
    var useDefault: Bool?
}

struct LaunchRequest: Decodable {
    var instanceId: UUID?
    var profileId: Profile?
    /// false: prepare the instance and install only (the frontend starts the app in its own window).
    var launch: Bool?
}

struct DeleteArtifactRequest: Decodable {
    /// Also uninstall the app from devices it was installed on (default true).
    var uninstall: Bool?
}
