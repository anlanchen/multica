import Foundation

/// Where a skill came from (`Skill.config.origin`, upstream lib/origin.ts).
public enum SkillsOriginType: String, Codable, CaseIterable, Sendable, Hashable {
    case manual
    case runtimeLocal = "runtime_local"
    case clawhub
    case skillsSh = "skills_sh"
    case github

    /// Filter-menu order (upstream ORIGIN_TYPES).
    public static let menuOrder: [SkillsOriginType] = [.manual, .runtimeLocal, .clawhub, .skillsSh, .github]
}

/// Typed view over the origin JSONB. Manual creates have no origin, so they
/// read as `.manual`.
public struct SkillsOrigin: Sendable, Hashable {
    public var type: SkillsOriginType
    public var provider: String?
    public var runtimeID: String?
    public var sourcePath: String?
    public var sourceURL: String?

    public init(type: SkillsOriginType, provider: String? = nil, runtimeID: String? = nil, sourcePath: String? = nil, sourceURL: String? = nil) {
        self.type = type
        self.provider = provider
        self.runtimeID = runtimeID
        self.sourcePath = sourcePath
        self.sourceURL = sourceURL
    }

    public init(config: [String: JSONValue]) {
        guard let raw = config["origin"], let typeName = raw["type"]?.stringValue,
              let type = SkillsOriginType(rawValue: typeName), type != .manual else {
            self.init(type: .manual)
            return
        }
        self.init(
            type: type,
            provider: raw["provider"]?.stringValue,
            runtimeID: raw["runtime_id"]?.stringValue,
            sourcePath: raw["source_path"]?.stringValue,
            sourceURL: raw["source_url"]?.stringValue
        )
    }

    /// Hosted sources can be re-downloaded; the server enforces the same
    /// rule on `POST /api/skills/:id/refresh`.
    public var isRefreshable: Bool {
        guard type == .github || type == .skillsSh || type == .clawhub else { return false }
        return !(sourceURL ?? "").isEmpty
    }

    private static let allowedHosts: [SkillsOriginType: Set<String>] = [
        .github: ["github.com", "www.github.com"],
        .skillsSh: ["skills.sh", "www.skills.sh"],
        .clawhub: ["clawhub.ai", "www.clawhub.ai"],
    ]

    /// `source_url` validated for use as a link: http(s) only, and the host
    /// must match the declared origin type. The origin is writable verbatim
    /// through the update API, so anything else stays plain text.
    public var linkURL: String? {
        guard let hosts = Self.allowedHosts[type], let raw = sourceURL, !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        return raw
    }
}

public enum SkillsPermissions {
    /// Workspace owners/admins edit any skill; everyone else only their own.
    public static func canEdit(createdBy: String?, userID: String?, role: String?) -> Bool {
        if role == "owner" || role == "admin" { return true }
        guard let userID, let createdBy else { return false }
        return createdBy == userID
    }

    public static func isAdmin(role: String?) -> Bool {
        role == "owner" || role == "admin"
    }
}

public enum SkillsErrors {
    /// Upstream `isNameConflictError`.
    public static func isNameConflict(_ message: String) -> Bool {
        message.range(of: #"\b(409|conflict|already exists|unique constraint)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Upstream `midTruncate`: keeps both ends of a long string.
    public static func midTruncate(_ s: String, maxLength: Int = 40) -> String {
        guard s.count > maxLength else { return s }
        let tail = (maxLength - 1) / 2
        let head = maxLength - 1 - tail
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}

/// A thrown message (polling timeouts, import reasons).
public struct SkillsError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

extension SkillSummary {
    public var skillsOrigin: SkillsOrigin { SkillsOrigin(config: config) }
}

extension Skill {
    public var skillsOrigin: SkillsOrigin { SkillsOrigin(config: config) }

    /// SKILL.md plus attached files.
    public var skillsTotalFileCount: Int { files.count + 1 }

    public var skillsSummary: SkillSummary {
        SkillSummary(id: id, workspaceId: workspaceId, name: name, description: description, config: config,
                     createdBy: createdBy, createdAt: createdAt, updatedAt: updatedAt, enabled: enabled, labels: labels)
    }
}
