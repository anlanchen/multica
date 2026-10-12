import Foundation

// The agent's own MCP config document (upstream tabs/mcp-config-model.ts) and
// the guided server editor's form model (tabs/mcp-server-dialog.tsx).
extension AgentsUI {
    public enum McpContainer: String, Sendable, CaseIterable {
        case mcpServers, mcp
    }

    public struct ManagedMcpServer: Sendable, Hashable, Identifiable {
        public var name: String
        public var config: [String: JSONValue]
        public var container: McpContainer
        public var transport: String
        public var enabled: Bool
        public var id: String { "\(container.rawValue):\(name)" }

        public init(name: String, config: [String: JSONValue], container: McpContainer, transport: String, enabled: Bool) {
            self.name = name
            self.config = config
            self.container = container
            self.transport = transport
            self.enabled = enabled
        }
    }

    /// JavaScript truthiness of a JSON value.
    static func isTruthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null): return false
        case .some(.bool(let b)): return b
        case .some(.number(let n)): return n != 0 && !n.isNaN
        case .some(.string(let s)): return !s.isEmpty
        case .some(.array), .some(.object): return true
        }
    }

    public static func mcpTransport(_ config: [String: JSONValue]) -> String {
        var type = ""
        if case .string(let s)? = config["type"] { type = s.lowercased() }
        if isTruthy(config["command"]) || type == "local" || type == "stdio" { return "stdio" }
        if type == "sse" { return "sse" }
        if isTruthy(config["url"]) || type == "remote" || type == "http" || type == "streamable-http" { return "http" }
        return "unknown"
    }

    public static func mcpTransportLabel(_ transport: String) -> String {
        switch transport.trimmingCharacters(in: .whitespaces).lowercased() {
        case "local", "stdio": return "STDIO"
        case "remote", "http", "streamable-http": return "Streamable HTTP"
        case "sse": return "SSE"
        default:
            let t = transport.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "Unknown" : t
        }
    }

    public static func listManagedMcpServers(_ value: JSONValue?) -> [ManagedMcpServer] {
        guard let doc = value?.objectValue else { return [] }
        var out: [ManagedMcpServer] = []
        var seen = Set<String>()
        for container in McpContainer.allCases {
            guard let map = doc[container.rawValue]?.objectValue else { continue }
            for (name, entry) in map {
                guard !seen.contains(name), let cfg = entry.objectValue else { continue }
                seen.insert(name)
                let enabled = cfg["enabled"]?.boolValue != false && cfg["disabled"]?.boolValue != true
                out.append(ManagedMcpServer(name: name, config: cfg, container: container, transport: mcpTransport(cfg), enabled: enabled))
            }
        }
        return out.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Writes `name → config`, removing the previous entry (rename) and
    /// keeping it in the container it came from.
    public static func upsertManagedMcpServer(_ value: JSONValue?, previous: ManagedMcpServer?, name: String, config: [String: JSONValue]) -> [String: JSONValue] {
        var doc = value?.objectValue ?? [:]
        let container = previous?.container ?? .mcpServers
        if let previous {
            var prevMap = doc[previous.container.rawValue]?.objectValue ?? [:]
            prevMap[previous.name] = nil
            doc[previous.container.rawValue] = .object(prevMap)
        }
        var target = doc[container.rawValue]?.objectValue ?? [:]
        target[name] = .object(config)
        doc[container.rawValue] = .object(target)
        return doc
    }

    /// The document without `server`, or nil when nothing is left.
    public static func removeManagedMcpServer(_ value: JSONValue?, server: ManagedMcpServer) -> [String: JSONValue]? {
        guard var doc = value?.objectValue else { return nil }
        var map = doc[server.container.rawValue]?.objectValue ?? [:]
        map[server.name] = nil
        doc[server.container.rawValue] = map.isEmpty ? nil : .object(map)
        return doc.isEmpty ? nil : doc
    }

    public static func isValidMcpServerName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0 == "_" || $0 == "-" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    // MARK: Guided editor

    public struct KeyValue: Sendable, Hashable {
        public var key: String
        public var value: String
        public init(key: String = "", value: String = "") {
            self.key = key
            self.value = value
        }
    }

    public struct McpForm: Sendable, Hashable {
        public enum Transport: String, Sendable, CaseIterable { case stdio, http }
        public var transport: Transport = .stdio
        public var command = ""
        public var args: [String] = []
        public var env: [KeyValue] = []
        public var url = ""
        public var headers: [KeyValue] = []
        public var extras: [String: JSONValue] = [:]

        public init() {}

        /// Which required field is missing, if any.
        public var missingField: String? {
            switch transport {
            case .stdio: return command.trimmingCharacters(in: .whitespaces).isEmpty ? "command" : nil
            case .http: return url.trimmingCharacters(in: .whitespaces).isEmpty ? "url" : nil
            }
        }
    }

    private static func pairs(_ v: JSONValue?) -> [KeyValue] {
        guard let o = v?.objectValue else { return [] }
        return o.keys.sorted().compactMap { k in
            if case .string(let s) = o[k]! { return KeyValue(key: k, value: s) }
            return nil
        }
    }

    public static func mcpForm(from config: [String: JSONValue]) -> McpForm {
        var form = McpForm()
        var extras = config
        for key in ["type", "command", "args", "env", "environment", "url", "headers"] { extras[key] = nil }
        form.extras = extras
        form.transport = mcpTransport(config) == "stdio" ? .stdio : .http
        switch config["command"] {
        case .string(let s)?: form.command = s
        case .array(let a)?:
            let tokens = a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            form.command = tokens.first ?? ""
            form.args = Array(tokens.dropFirst())
        default: break
        }
        if case .array(let a)? = config["args"] {
            form.args = a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        form.env = pairs(config["env"] ?? config["environment"])
        if case .string(let s)? = config["url"] { form.url = s }
        form.headers = pairs(config["headers"])
        return form
    }

    private static func record(_ pairs: [KeyValue]) -> JSONValue? {
        var out: [String: JSONValue] = [:]
        for p in pairs {
            let k = p.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = .string(p.value) }
        }
        return out.isEmpty ? nil : .object(out)
    }

    public static func mcpConfig(from form: McpForm) -> [String: JSONValue] {
        var config = form.extras
        switch form.transport {
        case .stdio:
            config["command"] = .string(form.command.trimmingCharacters(in: .whitespaces))
            if !form.args.isEmpty { config["args"] = .array(form.args.map(JSONValue.string)) }
            if let env = record(form.env) { config["env"] = env }
        case .http:
            config["type"] = "http"
            config["url"] = .string(form.url.trimmingCharacters(in: .whitespaces))
            if let headers = record(form.headers) { config["headers"] = headers }
        }
        return config
    }

    private static let formExpressibleTypes: Set<String> = ["local", "stdio", "remote", "http", "streamable-http"]

    /// Whether saving through the form would round-trip this entry without
    /// changing its protocol (an explicit `type` decides, not the display
    /// classifier).
    public static func mcpFormCanExpress(_ config: [String: JSONValue]) -> Bool {
        var type = ""
        if case .string(let s)? = config["type"] { type = s.trimmingCharacters(in: .whitespaces).lowercased() }
        if !type.isEmpty { return formExpressibleTypes.contains(type) }
        return config["command"] != nil || config["url"] != nil
    }

    public static func mcpFormSupports(_ server: ManagedMcpServer) -> Bool {
        if server.container == .mcp { return false }
        if !server.config.isEmpty { return mcpFormCanExpress(server.config) }
        return server.transport == "stdio" || server.transport == "http"
    }

    public enum McpJSONError: Error, Sendable, Hashable {
        case notObject
        case missingTarget
        case invalid(String)
    }

    public static func parseMcpServerJSON(_ text: String) -> Result<[String: JSONValue], McpJSONError> {
        guard let data = text.data(using: .utf8) else { return .failure(.invalid("invalid JSON")) }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return .failure(.invalid(describeJSONError(error)))
        }
        guard let o = value.objectValue else { return .failure(.notObject) }
        if !isTruthy(o["command"]) && !isTruthy(o["url"]) { return .failure(.missingTarget) }
        return .success(o)
    }

    static func describeJSONError(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let ctx) = error {
            if let underlying = ctx.underlyingError as NSError?, let d = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return d
            }
            return ctx.debugDescription
        }
        return "invalid JSON"
    }

    /// Two-space indented JSON with stable key order.
    public static func prettyJSON(_ value: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
