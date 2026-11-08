import Foundation

// Mirrors of the twinsimd JSON schema (Sources/TwinSim/Models.swift in the backend package).
// Decoding is deliberately lenient: unknown enum values are kept as raw strings so a newer
// backend does not break the frontend.

struct Handshake: Decodable, Sendable {
    let url: String
    let token: String
}

struct APIErrorBody: Decodable, Sendable, Hashable {
    let code: String
    let message: String
    var retryable: Bool = false

    enum CodingKeys: String, CodingKey { case code, message, retryable }
    init(code: String, message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        retryable = (try? c.decode(Bool.self, forKey: .retryable)) ?? false
    }
}

struct Capability: Decodable, Sendable, Hashable {
    let availability: String
    var reasonCode: String?

    var isAvailable: Bool { availability == "available" }
    var isSupported: Bool { availability != "unsupported" }
}

struct Instance: Decodable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var profileId: String
    var engineId: String
    var purpose: String
    var state: String
    var guestUid: Int?
    var selinux: String?
    var capabilities: [String: Capability]

    enum CodingKeys: String, CodingKey { case id, name, profileId, engineId, purpose, state, guestUid, selinux, capabilities }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        profileId = try c.decode(String.self, forKey: .profileId)
        engineId = try c.decode(String.self, forKey: .engineId)
        purpose = (try? c.decode(String.self, forKey: .purpose)) ?? "device"
        state = try c.decode(String.self, forKey: .state)
        guestUid = try? c.decode(Int.self, forKey: .guestUid)
        selinux = try? c.decode(String.self, forKey: .selinux)
        capabilities = (try? c.decode([String: Capability].self, forKey: .capabilities)) ?? [:]
    }

    var isAndroid: Bool { engineId == "android-emulator" }
    var isSimulator: Bool { engineId == "ios-simulator" }
    var isVPhone: Bool { engineId == "ios-vphone" }
    var isWindows: Bool { engineId == "windows-wine" }
    var isReady: Bool { state == "ready" }
    var isTransitioning: Bool { ["creating", "starting", "stopping"].contains(state) }
    var isAppWorkspace: Bool { purpose == "app" }
    /// The backend names app workspaces "Application workspace"; show a localized label.
    var displayName: String { isAppWorkspace && name == "Application workspace" ? "应用工作区" : name }

    func capability(_ name: String) -> Capability? { capabilities[name] }
    func can(_ name: String) -> Bool { capabilities[name]?.isAvailable == true }
}

struct Artifact: Decodable, Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let kind: String
    let bundleId: String
    let sha256: String
    let filename: String

    var engineId: String {
        switch kind {
        case "apk": "android-emulator"
        case "ipa": "ios-vphone"
        case "windowsExe", "windowsMsi": "windows-wine"
        default: "ios-simulator"
        }
    }

    var isWindows: Bool { kind == "windowsExe" || kind == "windowsMsi" }
}

struct BackendOperation: Decodable, Identifiable, Sendable, Hashable {
    let id: UUID
    let action: String
    var state: String
    var instanceId: UUID?
    var stage: String?
    var receivedBytes: Int64?
    var totalBytes: Int64?
    var result: [String: String]?
    var error: APIErrorBody?

    var isTerminal: Bool { state == "succeeded" || state == "failed" }
    var fraction: Double? {
        guard let r = receivedBytes, let t = totalBytes, t > 0 else { return nil }
        return min(1, max(0, Double(r) / Double(t)))
    }
}

struct OperationAccepted: Decodable, Sendable {
    let operationId: UUID
    let instanceId: UUID?
}

struct LicenseText: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let sha256: String
    let text: String
}

struct Component: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let status: String
    var version: String?
    var source: String?
    var downloadBytes: Int64?
    var requiredFreeBytes: Int64?
    var reasonCode: String?
    var licenses: [LicenseText]?

    var isReady: Bool { status == "ready" }
    var isInstallable: Bool { status == "downloadable" || status == "needsConsent" }
}

struct EngineInfo: Decodable, Identifiable, Sendable, Hashable {
    let engineId: String
    let profiles: [String]
    let componentIds: [String]
    var id: String { engineId }
}

struct GuestCommandResult: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: String?
}
