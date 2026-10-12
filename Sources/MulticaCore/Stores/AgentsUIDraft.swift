import Foundation

// The in-progress agent configuration shared by every creation surface
// (manual, duplicate, AI builder) — upstream core/agents/draft.ts,
// stored-draft.ts, manual-draft-store.ts and builder-protocol.ts.
extension AgentsUI {
    public enum PermissionScope: String, Sendable, CaseIterable, Codable {
        case `private`, workspace, members
    }

    public struct Draft: Sendable, Hashable {
        public var name = ""
        public var description = ""
        public var instructions = ""
        public var conversationStarters: [AgentConversationStarter] = []
        public var avatarUrl: String?
        public var runtimeId = ""
        public var model = ""
        public var thinkingLevel = ""
        public var serviceTier = ""
        public var skillIds: Set<String> = []
        public var permissionScope: PermissionScope = .private
        public var memberIds: Set<String> = []
        /// Not editable here, but duplicates preserve them.
        public var teamIds: Set<String> = []

        public init() {}

        /// Runtime change drops every runtime/model-native override.
        public func withRuntime(_ id: String) -> Draft {
            var d = self
            d.runtimeId = id
            d.model = ""
            d.thinkingLevel = ""
            d.serviceTier = ""
            return d
        }

        /// Model change drops the per-model overrides.
        public func withModel(_ model: String) -> Draft {
            guard model != self.model else { return self }
            var d = self
            d.model = model
            d.thinkingLevel = ""
            d.serviceTier = ""
            return d
        }

        public var descriptionWithinLimit: Bool { description.count <= AgentsUI.descriptionMaxLength }

        public var accessInvalid: Bool { permissionScope == .members && memberIds.isEmpty && teamIds.isEmpty }

        public var conversationStartersInvalid: Bool {
            conversationStarters.contains {
                $0.label.trimmingCharacters(in: .whitespaces).isEmpty || $0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
                    || $0.label.count > AgentsUI.conversationStarterLabelMaxLength || $0.prompt.count > AgentsUI.conversationStarterMaxLength
            }
        }

        public var invocationTargets: [AgentInvocationTargetInput] {
            switch permissionScope {
            case .private: return []
            case .workspace: return [AgentInvocationTargetInput(targetType: "workspace")]
            case .members:
                return memberIds.sorted().map { AgentInvocationTargetInput(targetType: "member", targetId: $0) }
                    + teamIds.sorted().map { AgentInvocationTargetInput(targetType: "team", targetId: $0) }
            }
        }
    }

    public static func duplicateAccess(permissionMode: String, targets: [AgentInvocationTarget]) -> (PermissionScope, Set<String>, Set<String>) {
        guard permissionMode == "public_to" else { return (.private, [], []) }
        if targets.contains(where: { $0.targetType == "workspace" }) { return (.workspace, [], []) }
        let members = Set(targets.filter { $0.targetType == "member" }.compactMap(\.targetId))
        let teams = Set(targets.filter { $0.targetType == "team" }.compactMap(\.targetId))
        if members.isEmpty && teams.isEmpty { return (.private, [], []) }
        return (.members, members, teams)
    }

    /// Seeds a copy; model and per-model overrides survive only when the copy
    /// stays on the same (usable) runtime.
    public static func duplicateDraft(_ source: AgentRecord, runtimes: [RuntimeDeviceRecord], userID: String?,
                                      fallbackRuntimeID: String, nameSuffix: String) -> Draft {
        let keepsRuntime = !source.runtimeId.isEmpty
            && runtimes.contains { $0.id == source.runtimeId && isRuntimeUsable($0, userID: userID) }
        var d = Draft()
        d.name = source.name + nameSuffix
        d.description = source.description
        d.instructions = source.instructions
        d.conversationStarters = source.conversationStarters ?? []
        d.avatarUrl = source.avatarUrl
        d.runtimeId = keepsRuntime ? source.runtimeId : fallbackRuntimeID
        d.model = keepsRuntime ? source.model : ""
        d.thinkingLevel = keepsRuntime ? source.thinkingLevel ?? "" : ""
        d.serviceTier = keepsRuntime ? source.serviceTier ?? "" : ""
        d.skillIds = Set(source.skills.map(\.id))
        (d.permissionScope, d.memberIds, d.teamIds) = duplicateAccess(permissionMode: source.permissionMode, targets: source.invocationTargets)
        return d
    }

    /// `POST /api/agents` body. Empty overrides are omitted so the runtime
    /// resolves its own defaults.
    public static func createRequest(_ draft: Draft, runtimeID: String, template: String? = nil, duplicateSource: AgentRecord? = nil) -> CreateAgentRequest {
        func nonEmpty(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var req = CreateAgentRequest(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: nonEmpty(draft.instructions),
            conversationStarters: draft.conversationStarters.isEmpty ? nil : draft.conversationStarters.map {
                AgentConversationStarter(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                                         prompt: $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            },
            avatarUrl: draft.avatarUrl,
            runtimeId: runtimeID,
            permissionMode: draft.permissionScope == .private ? "private" : "public_to",
            invocationTargets: draft.invocationTargets,
            model: nonEmpty(draft.model),
            thinkingLevel: nonEmpty(draft.thinkingLevel),
            serviceTier: nonEmpty(draft.serviceTier),
            template: template,
            skillIds: draft.skillIds.sorted()
        )
        if let source = duplicateSource {
            if !source.customArgs.isEmpty { req.customArgs = source.customArgs }
            if concurrencyRange.contains(source.maxConcurrentTasks) { req.maxConcurrentTasks = source.maxConcurrentTasks }
        }
        return req
    }

    /// The persisted form of a draft (server builder draft + local manual
    /// draft). Sets serialize sorted so equal drafts compare equal.
    public struct StoredDraft: Sendable, Hashable, Codable {
        public var name: String
        public var description: String
        public var instructions: String
        public var conversationStarters: [AgentConversationStarter]
        public var avatarUrl: String?
        public var model: String
        public var thinkingLevel: String
        public var serviceTier: String
        public var skillIds: [String]
        public var permissionScope: String
        public var memberIds: [String]
        public var teamIds: [String]
        public var appliedMessageId: String?

        enum CodingKeys: String, CodingKey {
            case name, description, instructions, model
            case conversationStarters = "conversation_starters"
            case avatarUrl = "avatar_url"
            case thinkingLevel = "thinking_level"
            case serviceTier = "service_tier"
            case skillIds = "skill_ids"
            case permissionScope = "permission_scope"
            case memberIds = "member_ids"
            case teamIds = "team_ids"
            case appliedMessageId = "applied_message_id"
        }

        public init(_ d: Draft, appliedMessageID: String?) {
            name = d.name
            description = d.description
            instructions = d.instructions
            conversationStarters = d.conversationStarters
            avatarUrl = d.avatarUrl
            model = d.model
            thinkingLevel = d.thinkingLevel
            serviceTier = d.serviceTier
            skillIds = d.skillIds.sorted()
            permissionScope = d.permissionScope.rawValue
            memberIds = d.memberIds.sorted()
            teamIds = d.teamIds.sorted()
            appliedMessageId = appliedMessageID
        }

        public init(_ r: StoredAgentDraft) {
            name = r.name
            description = r.description
            instructions = r.instructions
            conversationStarters = r.conversationStarters
            avatarUrl = r.avatarUrl
            model = r.model
            thinkingLevel = r.thinkingLevel
            serviceTier = r.serviceTier
            skillIds = r.skillIds.sorted()
            permissionScope = r.permissionScope
            memberIds = r.memberIds.sorted()
            teamIds = r.teamIds.sorted()
            appliedMessageId = r.appliedMessageId
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(description, forKey: .description)
            try c.encode(instructions, forKey: .instructions)
            try c.encode(conversationStarters, forKey: .conversationStarters)
            try c.encode(avatarUrl, forKey: .avatarUrl)
            try c.encode(model, forKey: .model)
            try c.encode(thinkingLevel, forKey: .thinkingLevel)
            try c.encode(serviceTier, forKey: .serviceTier)
            try c.encode(skillIds, forKey: .skillIds)
            try c.encode(permissionScope, forKey: .permissionScope)
            try c.encode(memberIds, forKey: .memberIds)
            try c.encode(teamIds, forKey: .teamIds)
            try c.encode(appliedMessageId, forKey: .appliedMessageId)
        }

        public func draft(runtimeID: String) -> Draft {
            var d = Draft()
            d.name = name
            d.description = description
            d.instructions = instructions
            d.conversationStarters = conversationStarters
            d.avatarUrl = avatarUrl
            d.runtimeId = runtimeID
            d.model = model
            d.thinkingLevel = thinkingLevel
            d.serviceTier = serviceTier
            d.skillIds = Set(skillIds)
            d.permissionScope = PermissionScope(rawValue: permissionScope) ?? .private
            d.memberIds = Set(memberIds)
            d.teamIds = Set(teamIds)
            return d
        }

        public var json: JSONValue { JSONValue(encoding: self) }
    }

    /// Manual-route drafts kept across navigation, keyed by what is being
    /// created ("blank" or "duplicate:<id>").
    public struct ManualDrafts: Sendable, Hashable, Codable {
        public struct Entry: Sendable, Hashable, Codable {
            public var runtimeId: String
            public var draft: StoredDraft
            public init(runtimeId: String, draft: StoredDraft) {
                self.runtimeId = runtimeId
                self.draft = draft
            }
        }

        public var byOwner: [String: Entry] = [:]

        public init() {}

        public static func owner(duplicateID: String?) -> String {
            duplicateID.map { "duplicate:\($0)" } ?? "blank"
        }

        /// The runtime alone never counts: the form seeds it on every visit.
        public static func hasContent(_ entry: Entry) -> Bool {
            entry.draft != StoredDraft(Draft(), appliedMessageID: nil)
        }

        public mutating func set(_ owner: String, _ entry: Entry?) {
            if let entry, Self.hasContent(entry) { byOwner[owner] = entry } else { byOwner[owner] = nil }
        }
    }
}

// MARK: - Builder wire protocol

extension AgentsUI {
    static let builderInputPrefix = "MULTICA_AGENT_BUILDER_INPUT\n"

    /// The `<agent_draft>` JSON block of an assistant reply, tolerating raw
    /// control characters inside strings.
    public static func parseBuilderDraft(_ content: String) -> [String: JSONValue]? {
        guard let open = content.range(of: "<agent_draft>"),
              let close = content.range(of: "</agent_draft>", range: open.upperBound..<content.endIndex) else { return nil }
        let body = String(content[open.upperBound..<close.lowerBound])
        guard !body.isEmpty else { return nil }
        for candidate in [body, escapeJSONStringControlCharacters(body)] {
            if let data = candidate.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return v.objectValue
            }
        }
        return nil
    }

    static func escapeJSONStringControlCharacters(_ value: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for c in value.unicodeScalars {
            if !inString {
                out.unicodeScalars.append(c)
                if c == "\"" { inString = true }
                continue
            }
            if escaped {
                out.unicodeScalars.append(c)
                escaped = false
                continue
            }
            switch c {
            case "\\": out.unicodeScalars.append(c); escaped = true
            case "\"": out.unicodeScalars.append(c); inString = false
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// Removes closed and still-streaming `<agent_draft>` blocks.
    public static func stripBuilderDraft(_ content: String) -> String {
        var s = content
        while let open = s.range(of: "<agent_draft>") {
            var start = open.lowerBound
            while start > s.startIndex, s[s.index(before: start)].isWhitespace { start = s.index(before: start) }
            if let close = s.range(of: "</agent_draft>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(start..<close.upperBound)
            } else {
                s.removeSubrange(start..<s.endIndex)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeBuilderInput(_ content: String) -> String {
        guard content.hasPrefix(builderInputPrefix) else { return content }
        let json = String(content.dropFirst(builderInputPrefix.count))
        guard let data = json.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .string(let request)? = v["user_request"] else { return content }
        return request
    }

    public struct BuilderCatalog: Sendable {
        public var skills: [(id: String, name: String, description: String)]
        public var members: [(id: String, name: String)]
        public var runtime: (id: String, name: String, provider: String)?
        public var models: [RuntimeModel]?

        public init(skills: [(id: String, name: String, description: String)], members: [(id: String, name: String)],
                    runtime: (id: String, name: String, provider: String)?, models: [RuntimeModel]?) {
            self.skills = skills
            self.members = members
            self.runtime = runtime
            self.models = models
        }
    }

    /// Wraps composer text in the envelope that restates the current draft
    /// and the catalogs the builder may pick ids from.
    public static func encodeBuilderInput(_ request: String, draft: Draft, catalog: BuilderCatalog) -> String {
        let starters = OrderedJSON.array(draft.conversationStarters.map {
            .object([("label", .string($0.label)), ("prompt", .string($0.prompt))])
        })
        let current: OrderedJSON = .object([
            ("name", .string(draft.name)),
            ("description", .string(draft.description)),
            ("instructions", .string(draft.instructions)),
            ("conversation_starters", starters),
            ("model", .string(draft.model)),
            ("skill_ids", .array(draft.skillIds.sorted().map(OrderedJSON.string))),
            ("permission_scope", .string(draft.permissionScope.rawValue)),
            ("member_ids", .array(draft.memberIds.sorted().map(OrderedJSON.string))),
        ])
        let runtime: OrderedJSON = catalog.runtime.map {
            .object([("id", .string($0.id)), ("name", .string($0.name)), ("provider", .string($0.provider))])
        } ?? .null
        let models: OrderedJSON = catalog.models.map { list in
            .array(list.map { .object([("id", .string($0.id)), ("label", .string($0.label)), ("provider", $0.provider.map(OrderedJSON.string) ?? .null)]) })
        } ?? .null
        let root: OrderedJSON = .object([
            ("user_request", .string(request)),
            ("current_draft", current),
            ("selected_runtime", runtime),
            ("available_runtime_models", models),
            ("available_workspace_skills", .array(catalog.skills.map {
                .object([("id", .string($0.id)), ("name", .string($0.name)), ("description", .string($0.description))])
            })),
            ("available_workspace_members", .array(catalog.members.map { .object([("id", .string($0.id)), ("name", .string($0.name))]) })),
        ])
        return builderInputPrefix + root.pretty()
    }

    /// Applies a builder reply's draft, keeping only ids the workspace knows
    /// and models the runtime catalog offers.
    public static func mergeBuilderDraft(_ current: Draft, payload: [String: JSONValue], validSkillIDs: Set<String>,
                                         validMemberIDs: Set<String>, validModelIDs: Set<String>?) -> Draft {
        func string(_ key: String) -> String? {
            if case .string(let s)? = payload[key] { return s }
            return nil
        }
        func ids(_ key: String, valid: Set<String>, fallback: Set<String>) -> Set<String> {
            guard case .array(let a)? = payload[key] else { return fallback }
            return Set(a.compactMap { if case .string(let s) = $0, valid.contains(s) { return s } else { return nil } })
        }
        var next = current
        let scope = string("permission_scope").flatMap(PermissionScope.init(rawValue:)) ?? current.permissionScope
        let skills = ids("skill_ids", valid: validSkillIDs, fallback: current.skillIds)
        let members = ids("member_ids", valid: validMemberIDs, fallback: current.memberIds)
        var model = current.model
        if let m = string("model"), m == current.model || (validModelIDs.map { !$0.isEmpty && (m.isEmpty || $0.contains(m)) } ?? false) {
            model = m
        }
        if case .array(let list)? = payload["conversation_starters"] {
            next.conversationStarters = list.prefix(conversationStartersMax).compactMap { item in
                guard case .string(let label)? = item["label"], case .string(let prompt)? = item["prompt"] else { return nil }
                let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
                let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !l.isEmpty, !p.isEmpty else { return nil }
                return AgentConversationStarter(label: String(l.prefix(conversationStarterLabelMaxLength)),
                                                prompt: String(p.prefix(conversationStarterMaxLength)))
            }
        }
        next.name = string("name") ?? current.name
        next.description = string("description") ?? current.description
        next.instructions = string("instructions") ?? current.instructions
        next.model = model
        if model != current.model {
            next.thinkingLevel = ""
            next.serviceTier = ""
        }
        next.skillIds = skills
        next.permissionScope = scope
        next.memberIds = scope == .members ? members : []
        return next
    }
}

/// JSON with preserved key order (the builder envelope is read by a model;
/// field order follows upstream for readability).
enum OrderedJSON {
    case null
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: return "null"
        case .string(let s): return Self.quote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { inner + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n" + o.map { inner + Self.quote($0.0) + ": " + $0.1.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - OpenClaw routing config

extension AgentsUI {
    public static let openclawTokenMask = "***"

    public struct OpenclawConfig: Sendable, Hashable {
        public var mode: String?
        public var host: String?
        public var port: Int?
        public var token: String?
        public var tls: Bool?

        public init(mode: String? = nil, host: String? = nil, port: Int? = nil, token: String? = nil, tls: Bool? = nil) {
            self.mode = mode
            self.host = host
            self.port = port
            self.token = token
            self.tls = tls
        }

        public init(_ raw: [String: JSONValue]) {
            if case .string(let m)? = raw["mode"], m == "local" || m == "gateway" { mode = m }
            if let gw = raw["gateway"]?.objectValue {
                if case .string(let h)? = gw["host"], !h.isEmpty { host = h }
                if case .number(let p)? = gw["port"], p.isFinite, p > 0 { port = Int(p) }
                if case .string(let t)? = gw["token"], !t.isEmpty { token = t }
                if case .bool(let b)? = gw["tls"] { tls = b }
            }
        }

        public var json: [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            if let mode { out["mode"] = .string(mode) }
            var gw: [String: JSONValue] = [:]
            if let host, !host.isEmpty { gw["host"] = .string(host) }
            if let port, port > 0 { gw["port"] = .number(Double(port)) }
            if tls == true { gw["tls"] = .bool(true) }
            if let token, !token.isEmpty { gw["token"] = .string(token) }
            if !gw.isEmpty { out["gateway"] = .object(gw) }
            return out
        }

        public func semanticallyEquals(_ o: OpenclawConfig) -> Bool {
            (mode ?? "local") == (o.mode ?? "local") && (host ?? "") == (o.host ?? "") && (port ?? 0) == (o.port ?? 0)
                && (token ?? "") == (o.token ?? "") && (tls ?? false) == (o.tls ?? false)
        }
    }

    /// The routing form; a masked persisted token is replayed as the mask so
    /// the server keeps it.
    public struct OpenclawForm: Sendable, Hashable {
        public var mode = "local"
        public var host = ""
        public var port = ""
        public var token = ""
        public var tls = false
        public var tokenWasMasked = false

        public init() {}

        public init(_ cfg: OpenclawConfig) {
            let masked = cfg.token == AgentsUI.openclawTokenMask
            mode = cfg.mode ?? "local"
            host = cfg.host ?? ""
            port = cfg.port.map(String.init) ?? ""
            token = masked ? "" : cfg.token ?? ""
            tls = cfg.tls == true
            tokenWasMasked = masked
        }

        public var portValid: Bool { port.isEmpty || port.allSatisfy { $0.isASCII && $0.isNumber } }

        public var config: OpenclawConfig {
            var cfg = OpenclawConfig(mode: mode)
            guard mode == "gateway" else { return cfg }
            let h = host.trimmingCharacters(in: .whitespaces)
            if !h.isEmpty { cfg.host = h }
            if let p = Int(port.prefix { $0.isNumber }), p > 0 { cfg.port = p }
            if tls { cfg.tls = true }
            if tokenWasMasked && token.isEmpty { cfg.token = AgentsUI.openclawTokenMask } else if !token.isEmpty { cfg.token = token }
            return cfg
        }
    }
}
