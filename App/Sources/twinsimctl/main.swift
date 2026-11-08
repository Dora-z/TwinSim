import Foundation

/// Real path of this executable (argv[0] is only "twinsim" when found through PATH).
func executableURL() -> URL {
    (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
}

enum Version {
    /// Version of the enclosing TwinSim.app (Contents/Helpers/twinsim → Contents/Info.plist).
    static let string: String = {
        let exe = executableURL()
        let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: plist)
        return info?["CFBundleShortVersionString"] as? String ?? "dev"
    }()
}

let usage = """
twinsim — drive TwinSim (Android emulators / iOS Simulators) from AI agents and scripts.

USAGE
  twinsim mcp                          Run the MCP server on stdio (for Claude Code, Claude Desktop, Cursor, Codex, …)
  twinsim tools [--format F]           List tools. F: text (default), mcp, openai, anthropic, gemini
  twinsim call <tool> ['<json args>']  Run a tool with JSON arguments (function-calling executor)
  twinsim <tool> [--arg value …]       Same, with flags. e.g. twinsim open_app --path ~/app.apk
                                       twinsim screenshot --device <id> --output shot.png
                                       twinsim tap --device <id> --x 360 --y 640
  twinsim help

OPTIONS
  --output PATH   Where to write images returned by a tool (default: a temporary file)
  --json          Print the full result (content + isError) as JSON

ENVIRONMENT
  TWINSIM_HOME           Data directory of the TwinSim instance to use (default ~/Library/Application Support/TwinSim)
  TWINSIM_APP            TwinSim.app to launch when it is not running
  TWINSIM_NO_LAUNCH=1    Fail instead of launching TwinSim.app
  TWINSIM_MCP_WAIT       Seconds an MCP tool call waits for a long operation before returning
                         "still running" + operationId (default 50, for clients with ~60 s tool timeouts)
  TWINSIM_MAX_EDGE       Long edge of screenshots for MCP (default 1280; 0 = full resolution). The CLI uses full resolution.

The CLI talks to the running TwinSim.app over a user-only Unix socket. It starts the app in the
background when needed. Exit status: 0 success, 1 tool error, 2 usage error.
"""

func fail(_ text: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(code)
}

func parseFlags(_ args: ArraySlice<String>, tool: Tool?) -> ([String: Any], output: String?, json: Bool) {
    var result: [String: Any] = [:]
    var output: String?
    var json = false
    var i = args.startIndex
    while i < args.endIndex {
        let arg = args[i]
        guard arg.hasPrefix("--") else { fail("Unexpected argument '\(arg)'. Use --name value.") }
        let name = String(arg.dropFirst(2))
        if name == "json" { json = true; i += 1; continue }
        var value: String
        if let eq = name.firstIndex(of: "=") {
            value = String(name[name.index(after: eq)...])
            let key = String(name[..<eq])
            if key == "output" { output = value } else { result[key] = coerce(value, tool?.properties[key]) }
            i += 1; continue
        }
        if i + 1 < args.endIndex, !args[i + 1].hasPrefix("--") { value = args[i + 1]; i += 2 } else { value = "true"; i += 1 }
        if name == "output" { output = value } else { result[name] = coerce(value, tool?.properties[name]) }
    }
    return (result, output, json)
}

func coerce(_ value: String, _ schema: [String: Any]?) -> Any {
    switch schema?["type"] as? String {
    case "integer": return Int(value) ?? value
    case "number": return Double(value) ?? value
    case "boolean": return ["1", "true", "yes", "on"].contains(value.lowercased())
    default: return value
    }
}

func printOutput(_ output: ToolOutput, imagePath: String?, json: Bool) {
    var savedImages: [String] = []
    for (index, content) in output.content.enumerated() {
        if case let .image(data, mime) = content {
            let ext = mime == "image/png" ? "png" : "jpg"
            let path = imagePath.map { ($0 as NSString).expandingTildeInPath }
                ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("twinsim-\(Int(Date().timeIntervalSince1970))-\(index).\(ext)")
            do { try data.write(to: URL(fileURLWithPath: path)); savedImages.append(path) }
            catch { FileHandle.standardError.write(Data("cannot write \(path): \(error)\n".utf8)) }
        }
    }
    if json {
        var items: [[String: Any]] = []
        var images = savedImages.makeIterator()
        for content in output.content {
            switch content {
            case .text(let t): items.append(["type": "text", "text": t])
            case .image(_, let mime): items.append(["type": "image", "mimeType": mime, "path": images.next() ?? ""])
            }
        }
        print(JSON.string(["isError": output.isError, "content": items]))
        return
    }
    for path in savedImages { print("image: \(path)") }
    for content in output.content { if case .text(let t) = content { print(t) } }
}

let arguments = CommandLine.arguments.dropFirst()
let maxEdge = Int(ProcessInfo.processInfo.environment["TWINSIM_MAX_EDGE"] ?? "")
guard let command = arguments.first else { print(usage); exit(0) }

switch command {
case "help", "--help", "-h":
    print(usage)
case "--version", "version":
    print("twinsim \(Version.string)")
case "mcp":
    signal(SIGPIPE, SIG_IGN)
    let wait = Double(ProcessInfo.processInfo.environment["TWINSIM_MCP_WAIT"] ?? "") ?? 50
    MCPServer(agent: Agent(maxEdge: maxEdge ?? 1280, defaultWait: max(5, wait))).run()
case "tools":
    let agent = Agent(maxEdge: 0)
    let (flags, _, _) = parseFlags(arguments.dropFirst(), tool: nil)
    switch flags["format"] as? String ?? "text" {
    case "mcp": print(JSON.string(agent.tools.map(MCPServer.describe)))
    case "openai":
        print(JSON.string(agent.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.inputSchema]] }))
    case "anthropic":
        print(JSON.string(agent.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.inputSchema] }))
    case "gemini":
        print(JSON.string(["function_declarations": agent.tools.map { tool -> [String: Any] in
            var schema = tool.inputSchema
            schema["additionalProperties"] = nil   // not accepted by Gemini
            return ["name": tool.name, "description": tool.description, "parameters": schema]
        }]))
    default:
        for tool in agent.tools {
            let params = tool.properties.keys.sorted().map { tool.required.contains($0) ? "--\($0)" : "[--\($0)]" }.joined(separator: " ")
            print("\(tool.name) \(params)\n    \(tool.description)\n")
        }
    }
case "call":
    let rest = Array(arguments.dropFirst())
    guard let name = rest.first else { fail("usage: twinsim call <tool> ['<json>'] [--output PATH] [--json]") }
    let agent = Agent(maxEdge: maxEdge ?? 0)
    var json: [String: Any] = [:]
    var flagStart = 1
    if rest.count > 1, !rest[1].hasPrefix("--") {
        guard let parsed = (try? JSONSerialization.jsonObject(with: Data(rest[1].utf8))) as? [String: Any] else {
            fail("Arguments must be a JSON object.")
        }
        json = parsed
        flagStart = 2
    }
    let (_, output, asJSON) = parseFlags(rest[flagStart...], tool: nil)
    let result = agent.call(name, json)
    printOutput(result, imagePath: output, json: asJSON)
    exit(result.isError ? 1 : 0)
default:
    let agent = Agent(maxEdge: maxEdge ?? 0)
    guard let tool = agent.tool(command) else { fail("Unknown command '\(command)'. Run `twinsim help` or `twinsim tools`.") }
    let (flags, output, asJSON) = parseFlags(arguments.dropFirst(), tool: tool)
    let result = agent.call(tool.name, flags)
    printOutput(result, imagePath: output, json: asJSON)
    exit(result.isError ? 1 : 0)
}
