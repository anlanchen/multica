import Foundation

/// Runtime labels and machine grouping used by the local-skill import panel
/// (upstream core/runtimes/display.ts and runtime-machines.ts).
public enum SkillsRuntimeLabels {
    private static let providerNames: [String: String] = [
        "codearts": "CodeArts", "dsh": "DeepSeek Harness", "qoderclicn": "Qoder CN", "traecli": "Trae",
        "qwen": "Qwen Code", "qwenpaw": "QwenPaw", "mcode": "MiniMax Code", "omp": "Oh-My-Pi", "zeroclaw": "ZeroClaw",
    ]

    public static func providerDisplayName(_ provider: String) -> String {
        if let known = providerNames[provider] { return known }
        return provider.prefix(1).uppercased() + provider.dropFirst()
    }

    public static func displayName(_ r: RuntimeDeviceRecord) -> String {
        let custom = r.customName?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? r.name : custom
    }

    /// Re-attaches the provider when a custom alias hides it.
    public static func displayLabel(_ r: RuntimeDeviceRecord) -> String {
        let display = displayName(r)
        let hasCustom = !(r.customName?.trimmingCharacters(in: .whitespaces) ?? "").isEmpty
        let provider = r.provider.trimmingCharacters(in: .whitespaces)
        guard hasCustom, !provider.isEmpty else { return display }
        return "\(display) (\(providerDisplayName(provider)))"
    }

    static func splitName(_ name: String) -> (base: String, hostname: String?) {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return (name, nil) }
        let base = String(name[..<open.lowerBound])
        let host = String(name[open.upperBound..<name.index(before: name.endIndex)])
        if base.isEmpty || host.isEmpty || host.contains("(") || host.contains(")") { return (name, nil) }
        return (base, host)
    }

    static func deviceName(_ r: RuntimeDeviceRecord) -> String? {
        if let host = splitName(r.name).hostname { return host }
        let raw = r.deviceInfo.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let first = raw.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? nil : first
    }

    /// Runtime label under its machine: a machine-wide rename is not repeated.
    public static func rowLabel(_ r: RuntimeDeviceRecord, machineTitle: String) -> String {
        let custom = r.customName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !custom.isEmpty && custom != machineTitle { return custom }
        return splitName(r.name).base
    }

    public struct Machine: Identifiable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var runtimes: [RuntimeDeviceRecord]
    }

    public static func machines(_ runtimes: [RuntimeDeviceRecord]) -> [Machine] {
        var order: [String] = []
        var groups: [String: [RuntimeDeviceRecord]] = [:]
        for r in runtimes {
            let id: String
            if let daemon = r.daemonId, !daemon.isEmpty { id = "\(r.runtimeMode):\(daemon)" }
            else if let device = deviceName(r) { id = "\(r.runtimeMode):device:\(device)" }
            else { id = "\(r.runtimeMode):runtime:\(r.id)" }
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(r)
        }
        let machines = order.map { id -> Machine in
            let list = groups[id]!.sorted { $0.provider.localizedCompare($1.provider) == .orderedAscending }
            return Machine(id: id, title: machineTitle(list), runtimes: list)
        }
        return machines.sorted { a, b in
            let ao = a.runtimes.filter { $0.status == "online" }.count
            let bo = b.runtimes.filter { $0.status == "online" }.count
            if ao != bo { return ao > bo }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
    }

    static func machineTitle(_ runtimes: [RuntimeDeviceRecord]) -> String {
        let names = runtimes.map { $0.customName?.trimmingCharacters(in: .whitespaces) ?? "" }
        if let first = names.first, !first.isEmpty, names.allSatisfy({ $0 == first }) { return first }
        guard let first = runtimes.first else { return "Unknown machine" }
        if let device = deviceName(first) { return device }
        if first.runtimeMode == "cloud" { return "\(providerDisplayName(first.provider)) cloud" }
        if let daemon = first.daemonId, !daemon.isEmpty { return daemon.count > 12 ? "\(daemon.prefix(8))..." : daemon }
        return "Unknown machine"
    }
}

public struct SkillsLocalInventory: Sendable, Hashable {
    public var skills: [RuntimeLocalSkillSummary]
    public var supported: Bool

    public init(skills: [RuntimeLocalSkillSummary], supported: Bool) {
        self.skills = skills
        self.supported = supported
    }

    /// Search over the fields a row renders (name, description, provider,
    /// path), so every match can be highlighted.
    public func filtered(_ query: String) -> [RuntimeLocalSkillSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return skills }
        return skills.filter { s in
            [s.name, s.description ?? "", s.provider, s.sourcePath].contains { $0.lowercased().contains(q) }
        }
    }
}

/// Case-insensitive match segments for search highlighting (upstream
/// HighlightText: the whole query, plus each word when there are several).
public enum SkillsTextHighlight {
    public struct Segment: Sendable, Hashable {
        public var text: String
        public var highlighted: Bool
    }

    public static func segments(_ text: String, query: String) -> [Segment] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !text.isEmpty else { return [Segment(text: text, highlighted: false)] }
        var terms = [q]
        for word in q.split(whereSeparator: \.isWhitespace).map(String.init) where !terms.contains(word) { terms.append(word) }
        var out: [Segment] = []
        var cursor = text.startIndex
        var plainStart = text.startIndex
        while cursor < text.endIndex {
            if let term = terms.first(where: { text[cursor...].range(of: $0, options: [.caseInsensitive, .anchored]) != nil }),
               let r = text[cursor...].range(of: term, options: [.caseInsensitive, .anchored]), !r.isEmpty {
                if plainStart < cursor { out.append(Segment(text: String(text[plainStart..<cursor]), highlighted: false)) }
                out.append(Segment(text: String(text[r]), highlighted: true))
                cursor = r.upperBound
                plainStart = cursor
            } else {
                cursor = text.index(after: cursor)
            }
        }
        if plainStart < text.endIndex { out.append(Segment(text: String(text[plainStart...]), highlighted: false)) }
        return out.isEmpty ? [Segment(text: text, highlighted: false)] : out
    }
}

public enum SkillsLocalImportOutcome: Sendable, Hashable {
    case created(Skill)
    case updated(Skill)
    case conflict(RuntimeLocalSkillImportConflict)
}

/// A conflict decision in the bulk import panel.
public struct SkillsConflictResolution: Sendable, Hashable {
    public enum Action: String, Sendable, Hashable { case overwrite, rename, skip }
    public var action: Action
    public var renameName: String

    public init(action: Action, renameName: String) {
        self.action = action
        self.renameName = renameName
    }

    public static func defaultRename(_ name: String) -> String { "\(name) copy" }

    public static func initial(name: String, canOverwrite: Bool) -> SkillsConflictResolution {
        SkillsConflictResolution(action: canOverwrite ? .overwrite : .rename, renameName: defaultRename(name))
    }

    public func isApplicable(canOverwrite: Bool) -> Bool {
        switch action {
        case .overwrite: return canOverwrite
        case .rename: return !renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .skip: return true
        }
    }
}

extension APIClient {
    static let skillsPollInterval: Duration = .milliseconds(500)

    /// Asks the daemon for its local skill inventory and polls until it
    /// answers (upstream `resolveRuntimeLocalSkills`, 30 s budget).
    public nonisolated func skillsDiscoverLocalSkills(runtimeID: String, timeout: Duration = .seconds(30)) async throws -> SkillsLocalInventory {
        let initial = try await initiateListLocalSkills(runtimeID)
        let clock = ContinuousClock()
        let start = clock.now
        var current = initial
        while current.status == "pending" || current.status == "running" {
            if clock.now - start > timeout { throw SkillsError("runtime local skill discovery timed out") }
            try await Task.sleep(for: Self.skillsPollInterval)
            current = try await getListLocalSkillsResult(runtimeID, requestId: initial.id)
        }
        if current.status == "failed" || current.status == "timeout" {
            throw SkillsError(current.error.flatMap { $0.isEmpty ? nil : $0 } ?? "runtime local skill discovery failed")
        }
        return SkillsLocalInventory(skills: current.skills ?? [], supported: current.supported)
    }

    /// Queues one import and polls it to completion (4 min budget: old
    /// daemons claim one import per heartbeat).
    public nonisolated func skillsImportLocalSkill(runtimeID: String, _ request: CreateRuntimeLocalSkillImportRequest,
                                                   timeout: Duration = .seconds(240)) async throws -> SkillsLocalImportOutcome {
        let initial = try await initiateImportLocalSkill(runtimeID, request)
        let clock = ContinuousClock()
        let start = clock.now
        var current = initial
        while current.status == "pending" || current.status == "running" {
            if clock.now - start > timeout { throw SkillsError("runtime local skill import timed out") }
            try await Task.sleep(for: Self.skillsPollInterval)
            current = try await getImportLocalSkillResult(runtimeID, requestId: initial.id)
        }
        if current.status == "conflict" {
            guard let conflict = current.conflict else { throw SkillsError("runtime local skill import conflict missing details") }
            return .conflict(conflict)
        }
        if current.status == "failed" || current.status == "timeout" {
            throw SkillsError(current.error.flatMap { $0.isEmpty ? nil : $0 } ?? "runtime local skill import failed")
        }
        guard let skill = current.skill, !skill.id.isEmpty else { throw SkillsError("runtime local skill import did not return a skill") }
        return current.action == "overwrite" ? .updated(skill) : .created(skill)
    }

    /// Archive import with a structured result (`{status, skill, reason}`);
    /// anything but created/updated throws the server's reason.
    public func skillsImportArchive(fileName: String, data: Data) async throws -> Skill {
        let raw: JSONValue
        do {
            raw = try await upload("/api/skills/import", fileName: fileName.isEmpty ? "skill.zip" : fileName,
                                   mimeType: "application/zip", fileData: data, fields: ["on_conflict": "fail"])
        } catch let error as APIError where error.status == 409 && error.message.hasPrefix("Request failed") {
            throw APIError(status: 409, message: "a skill with this name already exists")
        }
        let status = raw["status"]?.stringValue ?? ""
        if status == "created" || status == "updated", let value = raw["skill"],
           let skill = try? JSONCoders.decoder.decode(Skill.self, from: JSONCoders.encoder.encode(value)), !skill.id.isEmpty {
            return skill
        }
        throw SkillsError(raw["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Import failed")
    }

    /// The skill label catalog with usage counts (label manager).
    public nonisolated func skillsListLabels() async throws -> [LabelRecord] {
        struct Response: Decodable, Sendable { var labels: LossyList<LabelRecord> }
        let r: Response = try await call(.get, "/api/labels", query: [URLQueryItem(name: "resource_type", value: "skill")])
        return r.labels.items
    }
}
