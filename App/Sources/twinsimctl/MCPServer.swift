import Foundation

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
final class MCPServer {
    private let agent: Agent
    private let out = FileHandle.standardOutput
    private let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    TwinSim runs Android emulators and iOS Simulators on this Mac and lets you drive them.
    Typical flow: status → open_app (path or imported app; returns a device ID) → screenshot / ui_tree → tap_element or tap / swipe / type_text / press_key → screenshot again to verify → logs when debugging → stop_device when done.
    Coordinates: tap/swipe use the pixel space of the latest screenshot image (ui_tree reports the same space). Prefer ui_tree + tap_element on Android over pixel guessing.
    Windows programs (.exe/.msi) run through Wine as native Mac windows: screenshot captures the program window; tap/type_text/press_key need the Accessibility permission; shell runs cmd /c; windows_tool opens winecfg/regedit/etc.
    iOS Simulator devices are screenshot + logs only (no input). Device IPAs need the iOS research VM, which usually requires manual host setup — report blockers to the user instead of retrying.
    Never accept SDK licenses (install_component acceptLicenses=true) without the user's explicit consent. Long operations (first boot, image downloads) can take minutes; if a tool reports an operation still running, call wait_operation.
    """

    init(agent: Agent) {
        self.agent = agent
        agent.bridge.log = { FileHandle.standardError.write(Data(("twinsim-mcp: " + $0 + "\n").utf8)) }
    }

    func run() {
        while let line = Swift.readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = message as? [[String: Any]] {
                let replies = batch.compactMap(handle)
                if !replies.isEmpty { sendRaw(replies) }
            } else if let object = message as? [String: Any], let reply = handle(object) {
                send(reply)
            }
        }
    }

    private func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else { return nil }   // responses from the client
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: Any) -> [String: Any]? { id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "result": value] }
        func failure(_ code: Int, _ text: String) -> [String: Any]? {
            id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": text]]
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? supported[0]
            return result([
                "protocolVersion": supported.contains(requested) ? requested : supported[1],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "twinsim", "title": "TwinSim", "version": Version.string],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": agent.tools.map(Self.describe)])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "Missing tool name") }
            guard agent.tool(name) != nil else { return failure(-32602, "Unknown tool: \(name)") }
            let output = agent.call(name, params["arguments"] as? [String: Any] ?? [:])
            return result(["content": output.content.map(Self.encode), "isError": output.isError])
        case "resources/list": return result(["resources": []])
        case "prompts/list": return result(["prompts": []])
        default:
            if method.hasPrefix("notifications/") { return nil }
            return failure(-32601, "Method not found: \(method)")
        }
    }

    static func describe(_ tool: Tool) -> [String: Any] {
        var annotations: [String: Any] = ["readOnlyHint": tool.readOnly]
        if !tool.readOnly { annotations["destructiveHint"] = tool.destructive }
        return ["name": tool.name, "description": tool.description, "inputSchema": tool.inputSchema, "annotations": annotations]
    }

    static func encode(_ content: Content) -> [String: Any] {
        switch content {
        case .text(let text): return ["type": "text", "text": text]
        case .image(let data, let mime): return ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
        }
    }

    private func send(_ object: [String: Any]) { sendRaw(object) }

    private func sendRaw(_ object: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(10)
        out.write(data)
    }
}
