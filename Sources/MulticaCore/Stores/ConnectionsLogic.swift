import Foundation

// Pure logic behind the Settings › Connections tabs (code, channels, MCP,
// plugins, connected apps).

// MARK: - Code

public enum ConnectionsRepository {
    private static let defaultPorts: [String: Int] = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21, "ssh": 22, "git": 9418]

    /// Host + path identity of a clone URL so HTTPS and SSH forms of the same
    /// repository compare equal. Hosts fold case, paths keep it; a
    /// non-default port stays part of the identity.
    public static func identity(_ rawURL: String) -> String? {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var host = ""
        var path = ""
        if !value.contains("://"), let scp = scpLike(value) {
            host = scp.host
            path = scp.path
        }
        if host.isEmpty {
            guard let c = URLComponents(string: value), let scheme = c.scheme?.lowercased(), let h = c.host, !h.isEmpty else { return nil }
            host = h
            if let port = c.port, port != defaultPorts[scheme] { host += ":\(port)" }
            path = c.path
        }
        var normalized = Substring(path)
        while normalized.hasPrefix("/") { normalized = normalized.dropFirst() }
        while normalized.hasSuffix("/") { normalized = normalized.dropLast() }
        if normalized.lowercased().hasSuffix(".git") { normalized = normalized.dropLast(4) }
        guard !host.isEmpty, !normalized.isEmpty else { return nil }
        return "\(host.lowercased())/\(normalized)"
    }

    /// `[user@]host:path` (no scheme, no slash or whitespace in user/host).
    private static func scpLike(_ s: String) -> (host: String, path: String)? {
        var rest = Substring(s)
        if let at = rest.firstIndex(of: "@") {
            let user = rest[..<at]
            if !user.isEmpty, !user.contains(where: { $0 == "/" || $0.isWhitespace }) {
                rest = rest[rest.index(after: at)...]
            }
        }
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let host = rest[..<colon]
        let path = rest[rest.index(after: colon)...]
        guard !host.isEmpty, !path.isEmpty, !host.contains(where: { $0 == "/" || $0 == "@" || $0.isWhitespace }) else { return nil }
        return (String(host), String(path))
    }

    public static func isGitHub(_ url: String) -> Bool {
        identity(url)?.hasPrefix("github.com/") ?? false
    }
}

/// GitHub feature flags read off the workspace settings JSONB; every flag
/// defaults on for workspaces that predate them.
public struct ConnectionsGitHubSettings: Sendable, Hashable {
    public var enabled: Bool
    public var prSidebar: Bool
    public var coAuthor: Bool
    public var autoLinkPRs: Bool

    public init(settings: [String: JSONValue]) {
        enabled = settings["github_enabled"]?.boolValue != false
        prSidebar = enabled && settings["github_pr_sidebar_enabled"]?.boolValue != false
        coAuthor = enabled && settings["co_authored_by_enabled"]?.boolValue != false
        autoLinkPRs = enabled && settings["github_auto_link_prs_enabled"]?.boolValue != false
    }
}

public enum ConnectionsPRMergeStatus {
    public static let none = "none"

    /// `"none"` or the status key merged issues move to; without the key it
    /// follows the retired `pr_auto_complete_enabled` switch.
    public static func derive(settings: [String: JSONValue]) -> String {
        guard let value = settings["pr_merge_status"], !value.isNull else {
            let legacy = settings["pr_auto_complete_enabled"]
            return legacy == nil || legacy!.isNull || legacy!.boolValue == true ? "done" : none
        }
        guard case .string(let s) = value else { return none }
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? none : trimmed
    }

    /// Statuses a merge may move an issue into, per category; built-ins are
    /// always offered, `blocked` never.
    public static func groups(entries: [IssueStatusEntry]) -> [(category: StatusCategory, keys: [String])] {
        let targets: [(StatusCategory, [String])] = [(.started, ["in_progress", "in_review"]), (.done, ["done"])]
        return targets.map { category, builtIns in
            let listed = entries.filter { $0.category == category && $0.archivedAt == nil }
                .sorted { $0.position < $1.position }
                .map(\.key.rawValue)
                .filter { $0 != "blocked" }
            return (category, builtIns.filter { !listed.contains($0) } + listed)
        }
    }
}

// MARK: - Channels

public enum ConnectionsChannels {
    /// Channel installations soft-revoke, so only an active row counts.
    public static func hasActive(_ statuses: [String]) -> Bool {
        statuses.contains("active")
    }

    public static func dingTalkBotIdentity(groups: [DingTalkGroup], installationID: String) -> DingTalkGroupBot? {
        let bots = groups.flatMap { $0.bots.filter { $0.installationId == installationID } }
        guard var identity = bots.first(where: { !$0.botName.isEmpty }) ?? bots.first else { return nil }
        if let issue = bots.first(where: { !$0.botIdentityIssue.isEmpty })?.botIdentityIssue {
            identity.botIdentityIssue = issue
        }
        return identity
    }

    /// The groups an installation's bot was seen in: most recently active
    /// first, then titled before untitled, then by id.
    public static func observedGroups(_ groups: [DingTalkGroup], installationID: String) -> [(group: DingTalkGroup, bot: DingTalkGroupBot)] {
        let entries = groups.compactMap { g -> (group: DingTalkGroup, bot: DingTalkGroupBot)? in
            guard let bot = g.bots.first(where: { $0.installationId == installationID }) else { return nil }
            return (g, bot)
        }
        return entries.sorted { l, r in
            let la = l.bot.lastActiveAt.flatMap { Timestamp.parse($0) }, ra = r.bot.lastActiveAt.flatMap { Timestamp.parse($0) }
            if let la, let ra, la != ra { return la > ra }
            if (la != nil) != (ra != nil) { return la != nil }
            let lt = l.group.conversationTitle, rt = r.group.conversationTitle
            if lt != rt {
                if lt.isEmpty { return false }
                if rt.isEmpty { return true }
                return lt < rt
            }
            return l.group.conversationId < r.group.conversationId
        }
    }

    /// `—` for an empty or zero-value (year-1) install timestamp.
    public static func installedAt(_ value: String) -> Date? {
        guard !value.isEmpty, let d = Timestamp.parse(value), d.timeIntervalSince1970 > 0 else { return nil }
        return d
    }
}

// MARK: - Connected apps

public enum ConnectionsComposio {
    public static func filter(_ toolkits: [ComposioToolkit], query: String) -> [ComposioToolkit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return toolkits }
        return toolkits.filter {
            $0.name.lowercased().contains(q) || $0.slug.lowercased().contains(q) || ($0.category ?? "").lowercased().contains(q)
        }
    }

    public struct State: Sendable, Hashable {
        public var activeConnectionBySlug: [String: String] = [:]
        public var expiredSlugs: Set<String> = []
        public var lastUsedBySlug: [String: String] = [:]

        public init(_ connections: [ComposioConnection]) {
            for c in connections {
                if c.status == "active" {
                    activeConnectionBySlug[c.toolkitSlug] = c.id
                    if let used = c.lastUsedAt { lastUsedBySlug[c.toolkitSlug] = used }
                } else if c.status == "expired" {
                    expiredSlugs.insert(c.toolkitSlug)
                }
            }
        }
    }

    /// Logo candidates per appearance: the toolkit's own logo and the
    /// Composio logo service, deduplicated.
    public static func logoURLs(slug: String, fallback: String?, dark: Bool) -> [String] {
        let normalized = slug.trimmingCharacters(in: .whitespaces).lowercased()
        let base = normalized.isEmpty ? "" : "https://logos.composio.dev/api/\(normalized.pathEscaped)"
        let candidates = dark ? [base.isEmpty ? "" : base + "?theme=dark", fallback ?? "", base] : [fallback ?? "", base]
        var seen = Set<String>()
        return candidates.compactMap { s in
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, seen.insert(t).inserted else { return nil }
            return t
        }
    }
}

// MARK: - MCP

public enum ConnectionsMcp {
    public static func transportLabel(_ transport: String) -> String {
        switch transport.trimmingCharacters(in: .whitespaces).lowercased() {
        case "local", "stdio": return "STDIO"
        case "remote", "http", "streamable-http": return "Streamable HTTP"
        case "sse": return "SSE"
        default:
            let t = transport.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "Unknown" : t
        }
    }

    public enum TransportKind: Sendable { case stdio, http, other }

    public static func transportKind(_ transport: String) -> TransportKind {
        switch transport.trimmingCharacters(in: .whitespaces).lowercased() {
        case "stdio", "local": return .stdio
        case "http", "remote", "streamable-http": return .http
        default: return .other
        }
    }

    /// Display classifier for a saved config.
    public static func transport(of config: [String: JSONValue]) -> String {
        let type = config["type"]?.stringValue?.lowercased() ?? ""
        if truthy(config["command"]) || type == "local" || type == "stdio" { return "stdio" }
        if type == "sse" { return "sse" }
        if truthy(config["url"]) || type == "remote" || type == "http" || type == "streamable-http" { return "http" }
        return "unknown"
    }

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        }
    }

    public enum JSONParse: Sendable, Equatable {
        case ok([String: JSONValue])
        case notObject
        case missingTarget
        case invalid(String)
    }

    public static func parseServerJSON(_ text: String) -> JSONParse {
        let value: JSONValue
        do {
            value = try JSONCoders.decoder.decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            return .invalid(describe(error))
        }
        guard case .object(let obj) = value else { return .notObject }
        guard truthy(obj["command"]) || truthy(obj["url"]) else { return .missingTarget }
        return .ok(obj)
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let ctx) = error {
            if let underlying = ctx.underlyingError as NSError?, let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return detail
            }
            return ctx.debugDescription
        }
        return "invalid JSON"
    }

    public static func prettyJSON(_ config: [String: JSONValue]) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? e.encode(JSONValue.object(config)), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s.replacingOccurrences(of: " : ", with: ": ")
    }
}

public struct ConnectionsKeyValue: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var key: String
    public var value: String

    public init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
}

/// The MCP server dialog's visual editor state.
public struct ConnectionsMcpForm: Sendable, Hashable {
    public enum Transport: String, Sendable { case stdio, http }

    public var transport: Transport = .stdio
    public var command = ""
    public var args: [String] = []
    public var env: [ConnectionsKeyValue] = []
    public var url = ""
    public var headers: [ConnectionsKeyValue] = []
    public var extras: [String: JSONValue] = [:]

    public init(transport: Transport = .stdio) {
        self.transport = transport
    }

    public init(config: [String: JSONValue]) {
        var extras = config
        for key in ["type", "command", "args", "env", "environment", "url", "headers"] { extras[key] = nil }
        self.extras = extras
        transport = ConnectionsMcp.transport(of: config) == "stdio" ? .stdio : .http
        switch config["command"] {
        case .string(let s)?: command = s
        case .array(let a)?:
            let tokens = a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            command = tokens.first ?? ""
            args = Array(tokens.dropFirst())
        default: break
        }
        if case .array(let a)? = config["args"] {
            args = a.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        env = Self.pairs(config["env"] ?? config["environment"])
        if case .string(let s)? = config["url"] { url = s }
        headers = Self.pairs(config["headers"])
    }

    private static func pairs(_ value: JSONValue?) -> [ConnectionsKeyValue] {
        guard case .object(let o)? = value else { return [] }
        return o.keys.sorted().compactMap { k in
            if case .string(let v)? = o[k] { return ConnectionsKeyValue(key: k, value: v) }
            return nil
        }
    }

    private static func record(_ pairs: [ConnectionsKeyValue]) -> JSONValue? {
        var out: [String: JSONValue] = [:]
        for p in pairs {
            let k = p.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = .string(p.value) }
        }
        return out.isEmpty ? nil : .object(out)
    }

    public var config: [String: JSONValue] {
        var c = extras
        switch transport {
        case .stdio:
            c["command"] = .string(command.trimmingCharacters(in: .whitespaces))
            if !args.isEmpty { c["args"] = JSONValue(args) }
            if let env = Self.record(env) { c["env"] = env }
        case .http:
            c["type"] = "http"
            c["url"] = .string(url.trimmingCharacters(in: .whitespaces))
            if let headers = Self.record(headers) { c["headers"] = headers }
        }
        return c
    }

    public enum Problem: Sendable { case command, url }

    public var problem: Problem? {
        switch transport {
        case .stdio: return command.trimmingCharacters(in: .whitespaces).isEmpty ? .command : nil
        case .http: return url.trimmingCharacters(in: .whitespaces).isEmpty ? .url : nil
        }
    }
}

// MARK: - Plugins

public struct ConnectionsScheduledHook: Sendable, Hashable, Identifiable {
    public var key: String
    public var name: String
    public var cron: String
    public var timezone: String
    public var nextRunAt: String?
    public var id: String { key }
}

public enum ConnectionsPlugins {
    public enum Frequency: Sendable, Equatable {
        case minutes(Int)
        case hourly(minute: String)
        case daily(hour: String, minute: String)
        case custom
    }

    public static func frequency(_ cron: String) -> Frequency {
        let f = cron.split(whereSeparator: \.isWhitespace).map(String.init)
        guard f.count == 5 else { return .custom }
        let rest = Array(f.dropFirst())
        func digits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
        if f[0].hasPrefix("*/"), digits(String(f[0].dropFirst(2))), rest.allSatisfy({ $0 == "*" }) {
            return .minutes(Int(f[0].dropFirst(2)) ?? 0)
        }
        if digits(f[0]), rest.allSatisfy({ $0 == "*" }) { return .hourly(minute: f[0]) }
        if digits(f[0]), digits(f[1]), f[2...].allSatisfy({ $0 == "*" }) {
            func pad(_ s: String) -> String { s.count < 2 ? String(repeating: "0", count: 2 - s.count) + s : s }
            return .daily(hour: pad(f[1]), minute: pad(f[0]))
        }
        return .custom
    }

    /// Catalog key (under `plugins.scopes`) and arguments describing a scope.
    public static func scopeKey(_ scope: String) -> (key: String, args: [String: String]) {
        if scope.hasPrefix("net:") { return ("net", ["domain": String(scope.dropFirst(4))]) }
        switch scope {
        case "issues:read": return ("issues_read", [:])
        case "issues:write": return ("issues_write", [:])
        case "comments:read": return ("comments_read", [:])
        case "comments:write": return ("comments_write", [:])
        case "tasks:read": return ("tasks_read", [:])
        case "tasks:write": return ("tasks_write", [:])
        case "agents:read": return ("agents_read", [:])
        case "members:read": return ("members_read", [:])
        case "storage:user": return ("storage_user", [:])
        case "storage:workspace": return ("storage_workspace", [:])
        default: return ("unknown", [:])
        }
    }

    /// A hook's breaker trips after this many consecutive failures.
    public static let breakerThreshold = 5

    public struct InvocationSummary: Sendable, Equatable {
        public var total: Int
        public var failures: Int
        public var consecutiveFailures: Int
        public var lastError: String?
        public var tripped: Bool { consecutiveFailures >= ConnectionsPlugins.breakerThreshold }
    }

    public static func summarize(_ invocations: [PluginInvocation]) -> InvocationSummary {
        let recent = Array(invocations.prefix(20))
        let failures = recent.filter { $0.status != "ok" }
        let leading = recent.prefix { $0.status != "ok" }.count
        return InvocationSummary(total: recent.count, failures: failures.count, consecutiveFailures: leading,
                                 lastError: failures.first?.error)
    }

    public static func mcpHooks(_ hooks: [PluginHook]) -> [PluginHook] {
        hooks.filter { $0.transport == "mcp" && $0.triggers.contains("agent") }
    }

    /// The approved set the save button sends: approved tools minus drifted ones.
    public static func initialSelection(_ tools: [PluginMCPTool]) -> [String] {
        tools.filter { $0.approved && !$0.drifted }.map(\.name)
    }

    public static func scheduledHooks(_ hooks: [PluginHook]) -> [ConnectionsScheduledHook] {
        hooks.compactMap { h in
            guard let s = h.schedule else { return nil }
            return ConnectionsScheduledHook(key: h.key, name: h.name, cron: s.cron, timezone: s.timezone, nextRunAt: s.nextRunAt)
        }
    }

    /// Scheduled hooks declared in a manifest's `contributes.hooks`.
    public static func scheduledHooks(manifest contributes: JSONValue?) -> [ConnectionsScheduledHook] {
        guard case .array(let hooks)? = contributes?["hooks"] else { return [] }
        return hooks.compactMap { h in
            guard let s = h["schedule"], case .object = s else { return nil }
            return ConnectionsScheduledHook(key: h["key"]?.stringValue ?? "", name: h["name"]?.stringValue ?? "",
                                            cron: s["cron"]?.stringValue ?? "", timezone: s["timezone"]?.stringValue ?? "",
                                            nextRunAt: s["next_run_at"]?.stringValue)
        }
    }

    public static func authorName(_ author: JSONValue) -> String {
        author["name"]?.stringValue ?? author.stringValue ?? ""
    }

    // MARK: Surface bridge

    public static let bridgeProtocolVersion = 2
    public static let bridgeConnectMessage = "multica:plugin-bridge-connect"
    public static let bridgeMethods: Set<String> = ["GET", "POST", "PATCH", "PUT", "DELETE"]
    /// Upstream caps a surface's requested height.
    public static let maxSurfaceHeight = 4000.0

    /// The Action API paths a surface may call through the bridge.
    public static func isAllowedBridgePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "", parts.count >= 2, parts.dropFirst().allSatisfy({ !$0.isEmpty }) else { return false }
        let p = Array(parts.dropFirst())
        switch (p.count, p[0]) {
        case (1, "context"): return true
        case (2, "issues"): return true
        case (3, "issues"): return p[2] == "comments"
        case (2, "storage"): return p[1] == "workspace" || p[1] == "user"
        case (3, "storage"): return p[1] == "workspace" || p[1] == "user"
        case (2, "hooks"): return true
        default: return false
        }
    }

    public static func surfaceOrigin(_ url: String) -> String? {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host)\(c.port.map { ":\($0)" } ?? "")"
    }

    /// The trusted outer document hosting a plugin surface: it frames the
    /// hosted URL in a scripts-only sandbox, accepts the guest's bridge port
    /// once the single-use token matches, and relays requests to the native
    /// `multicaPluginBridge` message handler. nil for an unusable launch.
    public static func surfaceDocument(url: String, bridgeToken: String, theme: [String: String]) -> String? {
        guard let origin = surfaceOrigin(url), !bridgeToken.isEmpty else { return nil }
        let config: JSONValue = ["url": .string(url), "bridgeToken": .string(bridgeToken),
                                 "theme": .object(theme.mapValues { .string($0) })]
        guard let data = try? JSONCoders.encoder.encode(config) else { return nil }
        let encoded = data.base64EncodedString()
        let csp = ["default-src 'none'", "script-src 'unsafe-inline'", "style-src 'unsafe-inline'", "frame-src \(origin)",
                   "connect-src 'none'", "img-src 'none'", "font-src 'none'", "object-src 'none'", "base-uri 'none'",
                   "form-action 'none'"].joined(separator: "; ")
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html>
        <html>
        <head>
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html, body, #multica-plugin-root, iframe { width: 100%; height: 100%; margin: 0; padding: 0; border: 0; }
        body { overflow: hidden; background: transparent; }
        </style>
        </head>
        <body>
        <div id="multica-plugin-root"></div>
        <script>
        (function () {
          var binary = atob("\(encoded)");
          var bytes = new Uint8Array(binary.length);
          for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          var config = JSON.parse(new TextDecoder().decode(bytes));
          var native = window.webkit.messageHandlers.multicaPluginBridge;
          var child = document.createElement("iframe");
          child.title = "Plugin content";
          child.setAttribute("sandbox", "allow-scripts");
          var state = "launching";
          var loadCount = 0;
          var port = null;
          function stopSurface(type) {
            if (state === "terminal") return;
            state = "terminal";
            if (port) { port.close(); port = null; }
            native.postMessage({ type: type });
          }
          window.__multicaBridgeReply = function (message) { if (port) port.postMessage(message); };
          document.addEventListener("securitypolicyviolation", function (event) {
            if (event.effectiveDirective === "frame-src" || event.effectiveDirective === "child-src") {
              stopSurface("multica:plugin-surface-navigation-blocked");
            }
          });
          child.addEventListener("load", function () {
            loadCount += 1;
            if (loadCount > 1) stopSurface("multica:plugin-surface-navigated");
          });
          window.addEventListener("message", function (event) {
            if (!child.contentWindow || event.source !== child.contentWindow) return;
            var data = event.data || {};
            if (data.type === "multica:plugin-surface-error" || data.type === "multica:plugin-surface-navigated") {
              stopSurface(data.type);
              return;
            }
            if (data.type !== "\(bridgeConnectMessage)" || data.version !== \(bridgeProtocolVersion) ||
                data.challenge !== config.bridgeToken || state !== "launching" || !event.ports[0]) return;
            state = "connected";
            config.bridgeToken = "";
            port = event.ports[0];
            port.onmessage = function (e) { native.postMessage({ type: "request", request: e.data }); };
            port.start();
            port.postMessage({ kind: "theme", theme: config.theme });
          });
          child.src = config.url;
          config.url = "";
          document.getElementById("multica-plugin-root").appendChild(child);
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Config values to send: every edited value plus only the secrets the
    /// admin typed (an empty secret would clear the stored one).
    public static func configPayload(values: [String: JSONValue], secrets: [String: String]) -> [String: JSONValue] {
        var out = values
        for (k, v) in secrets where !v.isEmpty { out[k] = .string(v) }
        return out
    }
}
