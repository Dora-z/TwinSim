import CoreGraphics
import Foundation

enum Content {
    case text(String)
    case image(Data, String)
}

struct ToolOutput {
    var content: [Content]
    var isError = false
    static func text(_ s: String) -> ToolOutput { ToolOutput(content: [.text(s)]) }
    static func json(_ value: Any) -> ToolOutput { .text(JSON.string(value)) }
}

struct Args {
    let raw: [String: Any]
    func string(_ key: String) -> String? {
        switch raw[key] {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    func require(_ key: String) throws -> String {
        guard let value = string(key) else { throw AgentError("INVALID_ARGUMENT", "Missing required argument '\(key)'.") }
        return value
    }
    func double(_ key: String) -> Double? {
        switch raw[key] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    func requireDouble(_ key: String) throws -> Double {
        guard let value = double(key) else { throw AgentError("INVALID_ARGUMENT", "Missing numeric argument '\(key)'.") }
        return value
    }
    func int(_ key: String) -> Int? { double(key).map { Int($0) } }
    func bool(_ key: String) -> Bool? {
        switch raw[key] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["1", "true", "yes", "on"].contains(s.lowercased())
        default: return nil
        }
    }
}

/// Thrown when an operation is still running after the wait budget; reported as a normal result
/// telling the model to call wait_operation (MCP clients often time out tool calls at ~60 s).
struct PendingOperation: Error { let operation: [String: Any] }

struct Tool {
    let name: String
    let description: String
    var properties: [String: [String: Any]] = [:]
    var required: [String] = []
    var readOnly = false
    var destructive = false
    let run: (Args) throws -> ToolOutput

    var inputSchema: [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}

enum JSON {
    static func string(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }
}

private func prop(_ type: String, _ description: String, enum values: [String]? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": type, "description": description]
    if let values { p["enum"] = values }
    return p
}

private let deviceProp = prop("string", "Device ID (or unique ID prefix, or exact device name) from list_devices / open_app.")

/// TwinSim operations exposed to AI agents. Used by the MCP server, the CLI and the
/// function-calling schema export.
final class Agent {
    let bridge = BridgeClient()
    /// Long edge of screenshots returned to the model; 0 keeps guest pixels.
    var maxEdge: Int
    /// Longest a single tool call waits for a backend operation before returning "still running".
    let defaultWait: TimeInterval
    private var spaces: [String: ScreenSpace] = [:]

    init(maxEdge: Int, defaultWait: TimeInterval = 900) { self.maxEdge = maxEdge; self.defaultWait = defaultWait }

    func cap(_ seconds: TimeInterval) -> TimeInterval { min(seconds, defaultWait) }
    func wait(_ a: Args, _ fallback: TimeInterval) -> TimeInterval { a.double("waitSeconds") ?? cap(fallback) }

    lazy var tools: [Tool] = makeTools()
    func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }

    func call(_ name: String, _ arguments: [String: Any]) -> ToolOutput {
        guard let tool = tool(name) else {
            return ToolOutput(content: [.text("Unknown tool '\(name)'. Available: \(tools.map(\.name).joined(separator: ", "))")], isError: true)
        }
        do { return try tool.run(Args(raw: arguments)) }
        catch let pending as PendingOperation { return self.pending(pending.operation) ?? .text("Operation finished.") }
        catch let error as AgentError { return ToolOutput(content: [.text(error.description)], isError: true) }
        catch { return ToolOutput(content: [.text("ERROR: \(error.localizedDescription)")], isError: true) }
    }

    // MARK: Backend helpers

    func instances() throws -> [[String: Any]] { try bridge.get("/instances").array }
    func artifacts() throws -> [[String: Any]] { try bridge.get("/artifacts").array }
    func components() throws -> [[String: Any]] { try bridge.get("/components").array }

    func device(_ ref: String) throws -> [String: Any] {
        let all = try instances()
        let lower = ref.lowercased()
        if let exact = all.first(where: { ($0["id"] as? String)?.lowercased() == lower }) { return exact }
        let byPrefix = all.filter { ($0["id"] as? String)?.lowercased().hasPrefix(lower) == true }
        if byPrefix.count == 1 { return byPrefix[0] }
        let byName = all.filter { ($0["name"] as? String)?.lowercased() == lower }
        if byName.count == 1 { return byName[0] }
        let candidates = (byPrefix + byName).isEmpty ? all : byPrefix + byName
        throw AgentError("DEVICE_NOT_FOUND", "No unique device matches '\(ref)'.",
                         hint: "Known devices: " + candidates.map { "\($0["id"] ?? "") (\($0["name"] ?? ""), \($0["profileId"] ?? ""))" }.joined(separator: "; "))
    }

    func app(_ ref: String) throws -> [String: Any] {
        let all = try artifacts()
        let lower = ref.lowercased()
        for key in ["id", "bundleId", "name", "filename"] {
            let matches = all.filter { ($0[key] as? String)?.lowercased() == lower }
            if matches.count == 1 { return matches[0] }
        }
        let byPrefix = all.filter { ($0["id"] as? String)?.lowercased().hasPrefix(lower) == true }
        if byPrefix.count == 1 { return byPrefix[0] }
        throw AgentError("APP_NOT_FOUND", "No unique imported app matches '\(ref)'.",
                         hint: "Imported apps: " + all.map { "\($0["id"] ?? "") \($0["name"] ?? "") \($0["bundleId"] ?? "")" }.joined(separator: "; ")
                            + ". Use import_app or pass a file path to open_app.")
    }

    static func id(_ object: [String: Any]) -> String { object["id"] as? String ?? "" }

    func platform(_ engine: String?) -> String {
        switch engine {
        case "android-emulator": "android"
        case "ios-simulator": "ios-simulator"
        case "ios-vphone": "ios-device-vm"
        default: engine ?? "?"
        }
    }

    func summarize(device d: [String: Any]) -> [String: Any] {
        let caps = d["capabilities"] as? [String: [String: Any]] ?? [:]
        var out: [String: Any] = [
            "id": Self.id(d), "name": d["name"] ?? "", "platform": platform(d["engineId"] as? String),
            "profile": d["profileId"] ?? "", "state": d["state"] ?? "",
            "kind": (d["purpose"] as? String) == "app" ? "app-workspace" : "device",
            "available": caps.filter { $0.value["availability"] as? String == "available" }.keys.sorted(),
        ]
        let blocked = caps.filter { $0.value["availability"] as? String == "blocked" }
            .mapValues { $0["reasonCode"] as? String ?? "blocked" }
        if !blocked.isEmpty { out["blocked"] = blocked }
        if let uid = d["guestUid"] { out["guestUid"] = uid }
        if let selinux = d["selinux"] { out["selinux"] = selinux }
        return out
    }

    func summarize(app a: [String: Any]) -> [String: Any] {
        let kind = a["kind"] as? String ?? ""
        return ["id": Self.id(a), "name": a["name"] ?? "", "bundleId": a["bundleId"] ?? "",
                "type": kind == "simulatorApp" ? "ios-simulator-app" : kind,
                "runsOn": kind == "apk" ? "android" : kind == "ipa" ? "ios-device-vm" : "ios-simulator"]
    }

    /// Submits a 202 request and waits. Returns the operation; throws when it fails.
    func operation(_ path: String, body: [String: Any] = [:], wait: TimeInterval) throws -> [String: Any] {
        let key = UUID().uuidString
        let accepted = try bridge.http("POST", path, body: body, idempotencyKey: key).check().object
        guard let id = accepted["operationId"] as? String else { throw AgentError("INVALID_RESPONSE", "No operation ID.") }
        let op = try waitOperation(id, timeout: wait)
        if op["state"] as? String != "succeeded" { throw PendingOperation(operation: op) }
        return op
    }

    func waitOperation(_ id: String, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let op = try bridge.get("/operations/\(id)").object
            switch op["state"] as? String {
            case "succeeded": return op
            case "failed":
                let error = op["error"] as? [String: Any] ?? [:]
                let code = error["code"] as? String ?? "OPERATION_FAILED"
                throw AgentError(code, error["message"] as? String ?? "The operation failed.", hint: Hints.for(code))
            default:
                if Date() >= deadline { return op }   // still queued/running
                usleep(700_000)
            }
        }
    }

    func pending(_ op: [String: Any]) -> ToolOutput? {
        guard let state = op["state"] as? String, state != "succeeded" else { return nil }
        var info: [String: Any] = ["status": state, "operationId": op["id"] ?? "", "action": op["action"] ?? ""]
        if let stage = op["stage"] { info["stage"] = stage }
        if let r = op["receivedBytes"], let t = op["totalBytes"] { info["progress"] = "\(r)/\(t) bytes" }
        info["next"] = "Still running. Call wait_operation with this operationId."
        return .json(info)
    }

    func action(_ device: String, _ name: String, _ body: [String: Any] = [:], wait: TimeInterval = 600) throws -> [String: Any] {
        try operation("/instances/\(device)/actions/\(name)", body: body, wait: wait)
    }

    func screenshot(_ deviceID: String) throws -> Data {
        let result = try bridge.http("GET", "/instances/\(deviceID)/screenshot").check()
        guard let data = result.data else { throw AgentError("INVALID_RESPONSE", "No image data.") }
        if let size = Imaging.size(of: data) { spaces[deviceID] = ScreenSpace(guest: size, maxEdge: maxEdge) }
        return data
    }

    func space(_ deviceID: String) throws -> ScreenSpace {
        if let space = spaces[deviceID] { return space }
        _ = try screenshot(deviceID)
        return spaces[deviceID]!
    }

    func platformCan(_ d: [String: Any], _ name: String) -> Bool {
        ((d["capabilities"] as? [String: [String: Any]])?[name]?["availability"] as? String) == "available"
    }

    func requireCapability(_ d: [String: Any], _ name: String) throws {
        let caps = d["capabilities"] as? [String: [String: Any]] ?? [:]
        let cap = caps[name]?["availability"] as? String
        if cap == "available" { return }
        if cap == "blocked" {
            let reason = caps[name]?["reasonCode"] as? String ?? "BLOCKED"
            throw AgentError(reason, "'\(name)' is not available on this device right now (state \(d["state"] ?? "?")).", hint: Hints.for(reason))
        }
        throw AgentError("CAPABILITY_UNSUPPORTED", "Devices of type \(platform(d["engineId"] as? String)) do not support '\(name)'.",
                         hint: name == "input" && (d["engineId"] as? String) == "ios-simulator"
                            ? "iOS Simulator devices are screenshot-only in TwinSim (no touch input)." : nil)
    }

    func shellOutput(_ deviceID: String, _ command: String, timeout: TimeInterval = 120) throws -> (String, String, String) {
        let d = try device(deviceID)
        try requireCapability(d, "guestShell")
        let shell = (d["engineId"] as? String) == "android-emulator" ? "sh" : "/bin/sh"
        let op = try action(Self.id(d), "shell", ["argv": [shell, "-c", command]], wait: cap(timeout))
        let r = op["result"] as? [String: String] ?? [:]
        if let guest = r["guestResult"] { return (guest, "", "0") }
        return (r["stdout"] ?? "", r["stderr"] ?? "", r["exitCode"] ?? "?")
    }

    func uiNodes(_ deviceID: String) throws -> [UINode] {
        let d = try device(deviceID)
        guard (d["engineId"] as? String) == "android-emulator" else {
            throw AgentError("CAPABILITY_UNSUPPORTED", "ui_tree is available for Android devices.", hint: "Use screenshot for iOS.")
        }
        let file = "/data/local/tmp/twinsim-ui.xml"
        for attempt in 0..<3 {
            let (out, _, _) = try shellOutput(Self.id(d), "uiautomator dump \(file) >/dev/null 2>&1; cat \(file); rm -f \(file)")
            let nodes = UITreeParser.parse(out)
            if !nodes.isEmpty { return nodes }
            if attempt < 2 { usleep(800_000) }   // "could not get idle state" while animating
        }
        throw AgentError("UI_TREE_UNAVAILABLE", "uiautomator did not return a hierarchy (the screen may be animating).",
                         hint: "Retry, or use screenshot.")
    }

    func match(_ nodes: [UINode], text: String?, resourceId: String?, desc: String?) -> [UINode] {
        nodes.filter { n in
            if let text, !(n.text.caseInsensitiveCompare(text) == .orderedSame || n.text.localizedCaseInsensitiveContains(text)) { return false }
            if let resourceId, !(n.resourceId == resourceId || n.shortId == resourceId) { return false }
            if let desc, !n.contentDesc.localizedCaseInsensitiveContains(desc) { return false }
            return n.bounds.width > 0 && n.bounds.height > 0
        }
        .sorted { a, b in
            // Exact text matches and clickable nodes first.
            let ea = text.map { a.text.caseInsensitiveCompare($0) == .orderedSame } ?? false
            let eb = text.map { b.text.caseInsensitiveCompare($0) == .orderedSame } ?? false
            if ea != eb { return ea }
            if a.clickable != b.clickable { return a.clickable }
            return a.index < b.index
        }
    }

    static let keyAliases: [String: String] = [
        "back": "KEYCODE_BACK", "home": "KEYCODE_HOME", "recents": "KEYCODE_APP_SWITCH", "app_switch": "KEYCODE_APP_SWITCH",
        "enter": "KEYCODE_ENTER", "delete": "KEYCODE_DEL", "backspace": "KEYCODE_DEL", "tab": "KEYCODE_TAB",
        "escape": "KEYCODE_ESCAPE", "power": "KEYCODE_POWER", "menu": "KEYCODE_MENU", "search": "KEYCODE_SEARCH",
        "volume_up": "KEYCODE_VOLUME_UP", "volume_down": "KEYCODE_VOLUME_DOWN", "up": "KEYCODE_DPAD_UP",
        "down": "KEYCODE_DPAD_DOWN", "left": "KEYCODE_DPAD_LEFT", "right": "KEYCODE_DPAD_RIGHT", "space": "KEYCODE_SPACE",
    ]

    // MARK: Tool definitions

    private func makeTools() -> [Tool] {
        var t: [Tool] = []

        t.append(Tool(name: "status", description: "Overview of TwinSim: backend state, components (engines/runtimes), devices and imported apps. Call this first.", readOnly: true) { [unowned self] _ in
            let comps = try components().map { c -> [String: Any] in
                var v: [String: Any] = ["id": c["id"] ?? "", "status": c["status"] ?? ""]
                if let r = c["reasonCode"] { v["reason"] = r }
                return v
            }
            return .json(["components": comps, "devices": try instances().map(summarize(device:)),
                          "apps": try artifacts().map(summarize(app:)),
                          "notes": "Android: full touch/keys/UI tree/shell. iOS Simulator: screenshots and logs only. Device IPAs need the iOS research VM (vphone)."])
        })

        t.append(Tool(name: "list_components", description: "Engines and runtimes with install status (ready, downloadable, needsConsent, blocked, externalSetup) and reasons.", readOnly: true) { [unowned self] _ in
            .json(try components().map { c -> [String: Any] in
                var v = c
                if let licenses = c["licenses"] as? [[String: Any]] {
                    v["licenses"] = licenses.map { ["id": $0["id"] ?? "", "sha256": $0["sha256"] ?? "", "chars": ($0["text"] as? String)?.count ?? 0] }
                }
                return v
            })
        })

        t.append(Tool(name: "install_component", description: "Install an engine/runtime component (e.g. android-display, android-runtime, android-google-apis, ios-simulator-runtime). If the component needs license consent, the first call returns the license text: show it to the user and call again with acceptLicenses=true ONLY after the user explicitly agrees.",
                      properties: ["componentId": prop("string", "Component ID from list_components."),
                                   "acceptLicenses": prop("boolean", "Set true only after the user has read and accepted the returned license text."),
                                   "waitSeconds": prop("integer", "Max seconds to wait in this call; if still running, the result says so and gives an operationId for wait_operation.")],
                      required: ["componentId"]) { [unowned self] a in
            let id = try a.require("componentId")
            guard let comp = try components().first(where: { $0["id"] as? String == id }) else {
                throw AgentError("COMPONENT_NOT_FOUND", "No component '\(id)'.")
            }
            let status = comp["status"] as? String ?? ""
            if status == "ready" { return .text("\(id) is already installed.") }
            if status == "externalSetup" || status == "blocked" {
                throw AgentError(comp["reasonCode"] as? String ?? "EXTERNAL_SETUP_REQUIRED",
                                 "\(id) cannot be installed by TwinSim (\(status)). Setup guide: \(comp["source"] ?? "-")", hint: Hints.for(comp["reasonCode"] as? String ?? ""))
            }
            var body: [String: Any] = [:]
            if status == "needsConsent" {
                let licenses = comp["licenses"] as? [[String: Any]] ?? []
                guard a.bool("acceptLicenses") == true else {
                    var text = "\(id) requires accepting \(licenses.count) license(s). Show them to the user and ask for explicit consent before calling install_component again with acceptLicenses=true.\n"
                    for l in licenses { text += "\n=== \(l["id"] ?? "") (sha256 \(l["sha256"] ?? "")) ===\n\(l["text"] ?? "")\n" }
                    return .text(text)
                }
                body["acceptLicenses"] = Dictionary(uniqueKeysWithValues: licenses.map { ($0["id"] as? String ?? "", $0["sha256"] as? String ?? "") })
            }
            let op = try operation("/components/\(id)/install", body: body, wait: wait(a, 600))
            return pending(op) ?? .text("\(id) installed.")
        })

        t.append(Tool(name: "list_devices", description: "List devices (full devices and background app workspaces) with state and available capabilities.", readOnly: true) { [unowned self] _ in
            .json(try instances().map(summarize(device:)))
        })

        t.append(Tool(name: "create_device", description: "Create a full device. Profiles: android-aosp, android-research (adb root), android-magisk, android-google-apis (API 34 Google APIs, adb root), ios-development (iOS Simulator), ios-research (vphone VM). Set start=true to boot it.",
                      properties: ["profileId": prop("string", "Device profile.", enum: ["android-aosp", "android-research", "android-magisk", "android-google-apis", "ios-development", "ios-research"]),
                                   "name": prop("string", "Display name."),
                                   "start": prop("boolean", "Boot after creating (default true)."),
                                   "showWindow": prop("boolean", "Open the device window in the TwinSim UI (default false).")],
                      required: ["profileId", "name"]) { [unowned self] a in
            let profile = try a.require("profileId")
            let engine = profile.hasPrefix("android") ? "android-emulator" : profile == "ios-development" ? "ios-simulator" : "ios-vphone"
            let op = try operation("/instances", body: ["engineId": engine, "profileId": profile, "name": try a.require("name")], wait: cap(600))
            if let p = pending(op) { return p }
            let id = (op["result"] as? [String: String])?["instanceId"] ?? (op["instanceId"] as? String ?? "")
            if a.bool("start") ?? true {
                let started = try action(id, "start", wait: cap(600))
                if let p = pending(started) { return p }
            }
            if a.bool("showWindow") == true { try? bridge.showWindow(instanceId: id) }
            return .json(summarize(device: try device(id)))
        })

        for (name, verb, text) in [("start_device", "start", "Boot a device and wait until it is ready."),
                                   ("stop_device", "stop", "Shut a device down.")] {
            t.append(Tool(name: name, description: text,
                          properties: ["device": deviceProp, "waitSeconds": prop("integer", "Max seconds to wait in this call; if still running, the result says so and gives an operationId for wait_operation.")],
                          required: ["device"]) { [unowned self] a in
                let d = try device(try a.require("device"))
                let op = try action(Self.id(d), verb, wait: wait(a, 600))
                if let p = pending(op) { return p }
                return .json(summarize(device: try device(Self.id(d))))
            })
        }

        t.append(Tool(name: "show_device", description: "Open the device's live screen window in the TwinSim app so the user can watch.",
                      properties: ["device": deviceProp], required: ["device"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try bridge.showWindow(instanceId: Self.id(d))
            return .text("Opened the window for \(d["name"] ?? "").")
        })

        t.append(Tool(name: "list_apps", description: "List imported apps (APK, iOS Simulator .app, device IPA).", readOnly: true) { [unowned self] _ in
            .json(try artifacts().map(summarize(app:)))
        })

        t.append(Tool(name: "import_app", description: "Import an app from an absolute local path: .apk (Android), .app (iOS Simulator build) or .ipa (iOS device build).",
                      properties: ["path": prop("string", "Absolute path on this Mac.")], required: ["path"]) { [unowned self] a in
            let path = (try a.require("path") as NSString).expandingTildeInPath
            let result = try bridge.http("POST", "/artifacts/import", body: ["path": path]).check()
            return .json(summarize(app: result.object))
        })

        t.append(Tool(name: "open_app", description: "Open an app in single-app mode: reuses (or creates and boots) a background workspace device, installs if needed, launches the app and returns the device ID to use with screenshot/tap/etc. Accepts an imported app (id, bundle ID or name) or a file path, which is imported first.",
                      properties: ["app": prop("string", "Imported app ID, bundle ID or name."),
                                   "path": prop("string", "Absolute path to an .apk/.app/.ipa to import and open."),
                                   "device": prop("string", "Optional existing device to open it on."),
                                   "profileId": prop("string", "Optional workspace profile, e.g. android-google-apis."),
                                   "showWindow": prop("boolean", "Show the app window in TwinSim (default true)."),
                                   "waitSeconds": prop("integer", "Max seconds to wait in this call; if still running, the result says so and gives an operationId for wait_operation.")]) { [unowned self] a in
            var artifact: [String: Any]
            if let path = a.string("path") {
                artifact = try bridge.http("POST", "/artifacts/import", body: ["path": (path as NSString).expandingTildeInPath]).check().object
            } else {
                artifact = try app(try a.require("app"))
            }
            let kind = artifact["kind"] as? String ?? ""
            let comps = try components()
            func ready(_ id: String) -> Bool { comps.first { $0["id"] as? String == id }?["status"] as? String == "ready" }
            var body: [String: Any] = [:]
            if let ref = a.string("device") { body["instanceId"] = Self.id(try device(ref)) }
            else if let profile = a.string("profileId") { body["profileId"] = profile }
            else if kind == "apk" && !ready("android-runtime") && ready("android-google-apis") { body["profileId"] = "android-google-apis" }
            if kind == "ipa", body["instanceId"] == nil, let vphone = comps.first(where: { $0["id"] as? String == "ios-vphone" }),
               vphone["status"] as? String != "ready" {
                let reason = vphone["reasonCode"] as? String ?? "EXTERNAL_SETUP_REQUIRED"
                throw AgentError(reason, "This Mac cannot run device IPAs yet: the iOS research VM (vphone) needs host setup (\(vphone["source"] ?? "")).", hint: Hints.for(reason))
            }
            let op = try operation("/artifacts/\(Self.id(artifact))/launch", body: body, wait: wait(a, 600))
            if let p = pending(op) { return p }
            let instance = (op["result"] as? [String: String])?["instanceId"] ?? (op["instanceId"] as? String ?? "")
            if a.bool("showWindow") ?? true { try? bridge.showWindow(instanceId: instance, artifactId: Self.id(artifact)) }
            var out = summarize(device: try device(instance))
            out["app"] = summarize(app: artifact)
            out["next"] = "Use screenshot (and ui_tree on Android) with device=\(instance)."
            return .json(out)
        })

        t.append(Tool(name: "launch_app", description: "Launch an installed app by bundle ID / package name on a running device.",
                      properties: ["device": deviceProp, "bundleId": prop("string", "Android package or iOS bundle ID.")],
                      required: ["device", "bundleId"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            _ = try action(Self.id(d), "launch", ["bundleId": try a.require("bundleId")], wait: cap(180))
            return .text("Launched \(try a.require("bundleId")).")
        })

        t.append(Tool(name: "uninstall_app", description: "Uninstall an app that TwinSim installed on a device.", properties: ["device": deviceProp, "bundleId": prop("string", "Package / bundle ID.")],
                      required: ["device", "bundleId"], destructive: true) { [unowned self] a in
            let d = try device(try a.require("device"))
            _ = try action(Self.id(d), "uninstall", ["bundleId": try a.require("bundleId")], wait: cap(180))
            return .text("Uninstalled.")
        })

        t.append(Tool(name: "screenshot", description: "Capture the device screen. The image is scaled so its long edge is at most maxEdge; tap/swipe/ui_tree use this image's pixel coordinates.",
                      properties: ["device": deviceProp, "maxEdge": prop("integer", "Max long edge in pixels (default from server; 0 = full resolution)."),
                                   "savePath": prop("string", "Optional absolute path to also save the full-resolution PNG.")],
                      required: ["device"], readOnly: true) { [unowned self] a in
            let d = try device(try a.require("device"))
            let id = Self.id(d)
            if let edge = a.int("maxEdge") { maxEdge = edge }
            let png = try screenshot(id)
            if let save = a.string("savePath") { try png.write(to: URL(fileURLWithPath: (save as NSString).expandingTildeInPath)) }
            let space = try self.space(id)
            let (image, mime) = Imaging.prepare(png, maxEdge: maxEdge, format: maxEdge > 0 ? "jpeg" : "png")
            return ToolOutput(content: [.image(image, mime), .text("\(d["name"] ?? "") [\(platform(d["engineId"] as? String))]. \(space.summary)")])
        })

        t.append(Tool(name: "ui_tree", description: "Android only: list on-screen UI elements (text, resource id, content description, clickable) with centers/bounds in screenshot image coordinates. Prefer this over guessing from pixels.",
                      properties: ["device": deviceProp, "all": prop("boolean", "Include layout-only nodes (default false)."),
                                   "filter": prop("string", "Only nodes whose text/desc/id contains this.")],
                      required: ["device"], readOnly: true) { [unowned self] a in
            let id = Self.id(try device(try a.require("device")))
            let nodes = try uiNodes(id)
            let space = try self.space(id)
            var shown = a.bool("all") == true ? nodes : nodes.filter(\.interesting)
            if let f = a.string("filter") {
                shown = shown.filter { $0.text.localizedCaseInsensitiveContains(f) || $0.contentDesc.localizedCaseInsensitiveContains(f) || $0.resourceId.localizedCaseInsensitiveContains(f) }
            }
            let package = nodes.first(where: { !$0.package.isEmpty })?.package ?? "?"
            var text = "Foreground package: \(package). \(shown.count) of \(nodes.count) nodes. \(space.summary)\n"
            text += shown.prefix(400).map { $0.describe(space) }.joined(separator: "\n")
            return .text(text)
        })

        t.append(Tool(name: "tap", description: "Tap at a point. x/y are pixel coordinates of the latest screenshot image (or ui_tree centers); pass coordinateSpace='guest' for raw device pixels.",
                      properties: ["device": deviceProp, "x": prop("number", "X coordinate."), "y": prop("number", "Y coordinate."),
                                   "coordinateSpace": prop("string", "image (default) or guest.", enum: ["image", "guest"])],
                      required: ["device", "x", "y"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "input")
            let id = Self.id(d)
            let (gx, gy) = try guestPoint(id, a.requireDouble("x"), a.requireDouble("y"), a.string("coordinateSpace"))
            _ = try action(id, "tap", ["x": gx, "y": gy], wait: cap(60))
            return .text("Tapped guest pixel (\(gx), \(gy)). Take a screenshot to see the result.")
        })

        t.append(Tool(name: "tap_element", description: "Android only: find a UI element by visible text, resource id or content description and tap its center.",
                      properties: ["device": deviceProp, "text": prop("string", "Visible text (exact match preferred, else contains)."),
                                   "resourceId": prop("string", "Resource id, e.g. com.app:id/login or just login."),
                                   "contentDesc": prop("string", "Accessibility content description (contains)."),
                                   "index": prop("integer", "Which match to tap when several match (default 0)."),
                                   "scroll": prop("boolean", "Scroll the main list to find it when not visible (default true).")],
                      required: ["device"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "input")
            let id = Self.id(d)
            guard a.string("text") != nil || a.string("resourceId") != nil || a.string("contentDesc") != nil else {
                throw AgentError("INVALID_ARGUMENT", "Give text, resourceId or contentDesc.")
            }
            let index = a.int("index") ?? 0
            var nodes = try uiNodes(id)
            var matches = match(nodes, text: a.string("text"), resourceId: a.string("resourceId"), desc: a.string("contentDesc"))
            var scrolls = 0
            // Not visible: scroll the largest scrollable container down until it appears or stops moving.
            while matches.count <= index, a.bool("scroll") ?? true, scrolls < 8,
                  let container = nodes.filter({ $0.scrollable && $0.bounds.height > 100 }).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                let b = container.bounds
                _ = try shellOutput(id, "input swipe \(Int(b.midX)) \(Int(b.maxY - b.height * 0.2)) \(Int(b.midX)) \(Int(b.minY + b.height * 0.25)) 400")
                usleep(500_000)
                let next = try uiNodes(id)
                if next.map({ $0.text + $0.contentDesc }) == nodes.map({ $0.text + $0.contentDesc }) { break }   // end of list
                nodes = next
                matches = match(nodes, text: a.string("text"), resourceId: a.string("resourceId"), desc: a.string("contentDesc"))
                scrolls += 1
            }
            guard index < matches.count else {
                throw AgentError("ELEMENT_NOT_FOUND", "No matching element on screen (\(matches.count) matches\(scrolls > 0 ? " after scrolling \(scrolls)×" : "")).", hint: "Call ui_tree to see what is on screen.")
            }
            let node = matches[index]
            let space = try self.space(id)
            _ = try action(id, "tap", ["x": Int(node.center.x), "y": Int(node.center.y)], wait: cap(60))
            var text = "Tapped \(node.describe(space))" + (scrolls > 0 ? " (after scrolling \(scrolls)×)" : "")
            if matches.count > 1 { text += "\n(\(matches.count) matches; used index \(index).)" }
            return .text(text)
        })

        t.append(Tool(name: "swipe", description: "Android: swipe/drag between two points (image coordinates by default). Use to scroll: swipe up (y1 > y2) scrolls content down.",
                      properties: ["device": deviceProp, "x1": prop("number", "Start X."), "y1": prop("number", "Start Y."),
                                   "x2": prop("number", "End X."), "y2": prop("number", "End Y."),
                                   "durationMs": prop("integer", "Duration (default 300)."),
                                   "coordinateSpace": prop("string", "image (default) or guest.", enum: ["image", "guest"])],
                      required: ["device", "x1", "y1", "x2", "y2"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            guard (d["engineId"] as? String) == "android-emulator" else { throw AgentError("CAPABILITY_UNSUPPORTED", "swipe is available for Android devices.") }
            let id = Self.id(d)
            let p = try guestPoint(id, a.requireDouble("x1"), a.requireDouble("y1"), a.string("coordinateSpace"))
            let q = try guestPoint(id, a.requireDouble("x2"), a.requireDouble("y2"), a.string("coordinateSpace"))
            let ms = max(50, min(5000, a.int("durationMs") ?? 300))
            _ = try shellOutput(id, "input swipe \(p.0) \(p.1) \(q.0) \(q.1) \(ms)")
            return .text("Swiped guest (\(p.0),\(p.1)) → (\(q.0),\(q.1)) in \(ms) ms.")
        })

        t.append(Tool(name: "type_text", description: "Android: type text into the focused field (tap the field first). Use press_key enter to submit.",
                      properties: ["device": deviceProp, "text": prop("string", "Text to type.")], required: ["device", "text"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            guard (d["engineId"] as? String) == "android-emulator" else { throw AgentError("CAPABILITY_UNSUPPORTED", "type_text is available for Android devices.") }
            let text = try a.require("text")
            // `input text` cannot take spaces directly (%s) and needs shell quoting.
            let encoded = text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: " ", with: "%s")
            let quoted = "'" + encoded.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let (_, err, code) = try shellOutput(Self.id(d), "input text \(quoted)")
            if code != "0" { throw AgentError("INPUT_FAILED", err) }
            return .text("Typed \(text.count) characters.")
        })

        t.append(Tool(name: "press_key", description: "Press a key: back, home, recents, enter, delete, tab, escape, power, menu, search, volume_up, volume_down, up/down/left/right, space, or any Android KEYCODE_* name.",
                      properties: ["device": deviceProp, "key": prop("string", "Key name.")], required: ["device", "key"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "input")
            let key = try a.require("key")
            let value = (d["engineId"] as? String) == "android-emulator" ? (Self.keyAliases[key.lowercased()] ?? key.uppercased()) : key.lowercased()
            _ = try action(Self.id(d), "key", ["value": value], wait: cap(60))
            return .text("Pressed \(value).")
        })

        t.append(Tool(name: "wait_for_text", description: "Android: wait until an element with the given text (or content description) is on screen.",
                      properties: ["device": deviceProp, "text": prop("string", "Text to wait for (contains, case-insensitive)."),
                                   "timeoutSeconds": prop("integer", "Default 20."), "gone": prop("boolean", "Wait until it disappears instead.")],
                      required: ["device", "text"], readOnly: true) { [unowned self] a in
            let id = Self.id(try device(try a.require("device")))
            let text = try a.require("text")
            let deadline = Date().addingTimeInterval(Double(a.int("timeoutSeconds") ?? 20))
            let gone = a.bool("gone") == true
            while true {
                let nodes = (try? uiNodes(id)) ?? []
                let found = nodes.first { $0.text.localizedCaseInsensitiveContains(text) || $0.contentDesc.localizedCaseInsensitiveContains(text) }
                if gone ? (found == nil && !nodes.isEmpty) : (found != nil) {
                    return .text(gone ? "'\(text)' is gone." : "Found: \(found!.describe(try self.space(id)))")
                }
                if Date() >= deadline { throw AgentError("TIMEOUT", "'\(text)' \(gone ? "is still" : "did not appear") on screen.") }
                usleep(800_000)
            }
        })

        t.append(Tool(name: "logs", description: "Recent device logs (Android logcat, iOS Simulator unified log, vphone log). iOS Simulator logs can take up to a minute.",
                      properties: ["device": deviceProp, "lines": prop("integer", "Lines (default 200). With a filter on Android the whole logcat buffer is searched."),
                                   "filter": prop("string", "Only lines containing this text (case-insensitive).")],
                      required: ["device"], readOnly: true) { [unowned self] a in
            let d = try device(try a.require("device"))
            let id = Self.id(d)
            let lines = max(1, min(a.int("lines") ?? 200, 5000))
            // Android: filter in the guest over the whole logcat buffer, not just the tail.
            if let f = a.string("filter"), (d["engineId"] as? String) == "android-emulator", platformCan(d, "guestShell") {
                let quoted = "'" + f.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let (out, _, _) = try shellOutput(id, "logcat -d -v threadtime | grep -i -F -e \(quoted) | tail -n \(lines)")
                return .text(out.isEmpty ? "(no matching log lines)" : out)
            }
            var text = try bridge.get("/instances/\(id)/logs", query: ["lines": String(min(lines, 1000))]).object["text"] as? String ?? ""
            if let f = a.string("filter") {
                text = text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(f) }.joined(separator: "\n")
            }
            return .text(text.isEmpty ? "(no matching log lines)" : text)
        })

        t.append(Tool(name: "shell", description: "Run a shell command in the guest (Android: `sh -c` via adb, root on research profiles; vphone: /bin/sh). Returns stdout, stderr and exit code.",
                      properties: ["device": deviceProp, "command": prop("string", "Shell command line."),
                                   "timeoutSeconds": prop("integer", "Default 120.")],
                      required: ["device", "command"]) { [unowned self] a in
            let (out, err, code) = try shellOutput(try a.require("device"), try a.require("command"), timeout: Double(a.int("timeoutSeconds") ?? 120))
            return ToolOutput(content: [.text("exit \(code)\n--- stdout ---\n\(out)" + (err.isEmpty ? "" : "\n--- stderr ---\n\(err)"))], isError: false)
        })

        t.append(Tool(name: "verify_root", description: "Verify guest root on research profiles (returns UID 0 when available).",
                      properties: ["device": deviceProp], required: ["device"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "guestRoot")
            let op = try action(Self.id(d), "root", wait: cap(180))
            return .text("Guest UID \((op["result"] as? [String: String])?["uid"] ?? "?").")
        })

        t.append(Tool(name: "set_writable_system", description: "Android adb-root profiles: make /system writable (on) or restore read-only (off). Reboots the guest; takes minutes.",
                      properties: ["device": deviceProp, "enabled": prop("boolean", "true = writable.")], required: ["device", "enabled"], destructive: true) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "writableSystem")
            let op = try action(Self.id(d), "writable-system", ["value": a.bool("enabled") == true ? "on" : "off"], wait: cap(600))
            return pending(op) ?? .text("writable-system \(a.bool("enabled") == true ? "enabled" : "disabled").")
        })

        t.append(Tool(name: "snapshot", description: "Android: save or restore a named snapshot of the device state.",
                      properties: ["device": deviceProp, "action": prop("string", "save or load.", enum: ["save", "load"]),
                                   "name": prop("string", "Letters, digits, - and _ (max 48).")],
                      required: ["device", "action", "name"], destructive: true) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "snapshot")
            let verb = try a.require("action") == "load" ? "snapshot-load" : "snapshot-save"
            let op = try action(Self.id(d), verb, ["snapshot": try a.require("name")], wait: cap(300))
            if let p = pending(op) { return p }
            return .text("Snapshot \(verb == "snapshot-save" ? "saved" : "restored"): \(try a.require("name")).")
        })

        t.append(Tool(name: "push_file", description: "Copy a local file into the guest.",
                      properties: ["device": deviceProp, "localPath": prop("string", "Absolute local path."),
                                   "remotePath": prop("string", "Absolute guest path, e.g. /data/local/tmp/x.")],
                      required: ["device", "localPath", "remotePath"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "guestFiles")
            _ = try action(Self.id(d), "guest-push", ["localPath": (try a.require("localPath") as NSString).expandingTildeInPath,
                                                       "remotePath": try a.require("remotePath")], wait: cap(600))
            return .text("Copied to \(try a.require("remotePath")).")
        })

        t.append(Tool(name: "pull_file", description: "Copy a guest file (max 128 MB) to a local path.",
                      properties: ["device": deviceProp, "remotePath": prop("string", "Absolute guest path."),
                                   "localPath": prop("string", "Absolute local destination path.")],
                      required: ["device", "remotePath", "localPath"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "guestFiles")
            let result = try bridge.http("GET", "/instances/\(Self.id(d))/guest-file", query: ["path": try a.require("remotePath")]).check()
            let local = (try a.require("localPath") as NSString).expandingTildeInPath
            try (result.data ?? Data()).write(to: URL(fileURLWithPath: local))
            return .text("Saved \(result.data?.count ?? 0) bytes to \(local).")
        })

        t.append(Tool(name: "port_forward", description: "Android: forward a guest TCP port to a 127.0.0.1 port on this Mac (e.g. for Frida or a debug server). Returns the local port.",
                      properties: ["device": deviceProp, "guestPort": prop("integer", "Guest TCP port.")], required: ["device", "guestPort"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            try requireCapability(d, "portForward")
            guard let port = a.int("guestPort") else { throw AgentError("INVALID_ARGUMENT", "guestPort is required.") }
            let op = try action(Self.id(d), "forward", ["guestPort": port], wait: cap(60))
            let local = (op["result"] as? [String: String])?["localPort"] ?? "?"
            return .text("127.0.0.1:\(local) → guest port \(port)")
        })

        t.append(Tool(name: "remove_port_forward", description: "Remove a port forward created by port_forward.",
                      properties: ["device": deviceProp, "localPort": prop("integer", "Local port returned by port_forward.")], required: ["device", "localPort"]) { [unowned self] a in
            let d = try device(try a.require("device"))
            guard let port = a.int("localPort") else { throw AgentError("INVALID_ARGUMENT", "localPort is required.") }
            _ = try action(Self.id(d), "unforward", ["localPort": port], wait: cap(60))
            return .text("Removed 127.0.0.1:\(port).")
        })

        t.append(Tool(name: "wait_operation", description: "Wait for a long-running operation returned as still running.",
                      properties: ["operationId": prop("string", "Operation ID."), "timeoutSeconds": prop("integer", "Max seconds to wait in this call (default: the server's per-call budget).")],
                      required: ["operationId"], readOnly: true) { [unowned self] a in
            let op = try waitOperation(try a.require("operationId"), timeout: a.double("timeoutSeconds") ?? cap(300))
            return pending(op) ?? .json(["status": "succeeded", "result": op["result"] ?? [:], "action": op["action"] ?? ""])
        })

        return t
    }

    private func guestPoint(_ id: String, _ x: Double, _ y: Double, _ space: String?) throws -> (Int, Int) {
        let s = try self.space(id)
        if space == "guest" { return ScreenSpace(guest: s.guest, maxEdge: 0).toGuest(x, y) }
        return s.toGuest(x, y)
    }
}
