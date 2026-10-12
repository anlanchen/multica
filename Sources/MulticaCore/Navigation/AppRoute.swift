import Foundation

/// Every workspace-scoped page of the upstream desktop app
/// (apps/desktop/src/renderer/src/routes.tsx), with the same URL shapes so
/// links, deep links and persisted tabs round-trip with the official client:
/// `/{slug}/issues/{id}`, `/{slug}/agents/new/ai/{session}`, ...
public enum AppRoute: Hashable, Sendable, Codable {
    case issues
    case issue(String)
    case projects
    case project(String)
    case autopilots
    case autopilot(String)
    case myIssues
    case runtimes
    case runtime(String)
    case runtimeSettings(machineID: String, runtimeID: String)
    case skills
    case skill(String)
    case agents
    case newAgent
    case newAgentManual
    case newAgentAI
    case newAgentAISession(String)
    case agent(String)
    case member(String)
    case squads
    case squad(String)
    case inbox
    case chat
    case attachmentPreview(String)
    case usage
    case settings

    /// The sidebar entry a route belongs to (drives the active highlight).
    public var page: WorkspacePage? {
        switch self {
        case .issues, .issue: return .issues
        case .projects, .project: return .projects
        case .autopilots, .autopilot: return .autopilots
        case .myIssues: return .myIssues
        case .runtimes, .runtime, .runtimeSettings: return .runtimes
        case .skills, .skill: return .skills
        case .agents, .newAgent, .newAgentManual, .newAgentAI, .newAgentAISession, .agent: return .agents
        case .member: return nil
        case .squads, .squad: return .squads
        case .inbox: return .inbox
        case .chat: return .chat
        case .attachmentPreview: return nil
        case .usage: return .usage
        case .settings: return .settings
        }
    }

    /// True for list pages (the sidebar's own targets).
    public var isRoot: Bool {
        WorkspacePage.allCases.contains { $0.route == self }
    }

    // MARK: Path mapping

    /// `issues/abc` style path relative to the workspace.
    public var relativePath: String {
        func e(_ s: String) -> String { s.pathEscaped }
        switch self {
        case .issues: return "issues"
        case .issue(let id): return "issues/\(e(id))"
        case .projects: return "projects"
        case .project(let id): return "projects/\(e(id))"
        case .autopilots: return "autopilots"
        case .autopilot(let id): return "autopilots/\(e(id))"
        case .myIssues: return "my-issues"
        case .runtimes: return "runtimes"
        case .runtime(let id): return "runtimes/\(e(id))"
        case .runtimeSettings(let m, let r): return "runtimes/\(e(m))/runtime/\(e(r))"
        case .skills: return "skills"
        case .skill(let id): return "skills/\(e(id))"
        case .agents: return "agents"
        case .newAgent: return "agents/new"
        case .newAgentManual: return "agents/new/manual"
        case .newAgentAI: return "agents/new/ai"
        case .newAgentAISession(let id): return "agents/new/ai/\(e(id))"
        case .agent(let id): return "agents/\(e(id))"
        case .member(let id): return "members/\(e(id))"
        case .squads: return "squads"
        case .squad(let id): return "squads/\(e(id))"
        case .inbox: return "inbox"
        case .chat: return "chat"
        case .attachmentPreview(let id): return "attachments/\(e(id))/preview"
        case .usage: return "usage"
        case .settings: return "settings"
        }
    }

    public func path(workspaceSlug slug: String) -> String {
        return "/\(slug.pathEscaped)/\(relativePath)"
    }

    /// Parses a workspace-relative path (`issues/abc`, with or without a
    /// leading slash; query and fragment are ignored).
    public init?(relativePath raw: String) {
        var path = raw
        if let q = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<q]) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).removingPercentEncoding ?? String($0) }
        guard let head = parts.first else { return nil }
        let rest = Array(parts.dropFirst())
        switch (head, rest.count) {
        case ("issues", 0): self = .issues
        case ("issues", 1): self = .issue(rest[0])
        case ("projects", 0): self = .projects
        case ("projects", 1): self = .project(rest[0])
        case ("autopilots", 0): self = .autopilots
        case ("autopilots", 1): self = .autopilot(rest[0])
        case ("my-issues", 0): self = .myIssues
        case ("runtimes", 0): self = .runtimes
        case ("runtimes", 1): self = .runtime(rest[0])
        case ("runtimes", 3) where rest[1] == "runtime": self = .runtimeSettings(machineID: rest[0], runtimeID: rest[2])
        case ("skills", 0): self = .skills
        case ("skills", 1): self = .skill(rest[0])
        case ("agents", 0): self = .agents
        case ("agents", 1) where rest[0] == "new": self = .newAgent
        case ("agents", 1): self = .agent(rest[0])
        case ("agents", 2) where rest[0] == "new" && rest[1] == "manual": self = .newAgentManual
        case ("agents", 2) where rest[0] == "new" && rest[1] == "ai": self = .newAgentAI
        case ("agents", 3) where rest[0] == "new" && rest[1] == "ai": self = .newAgentAISession(rest[2])
        case ("members", 1): self = .member(rest[0])
        case ("squads", 0): self = .squads
        case ("squads", 1): self = .squad(rest[0])
        case ("inbox", 0): self = .inbox
        case ("chat", 0): self = .chat
        case ("attachments", 2) where rest[1] == "preview": self = .attachmentPreview(rest[0])
        case ("usage", 0): self = .usage
        case ("settings", 0): self = .settings
        default: return nil
        }
    }

    /// Parses a full tab path `/{slug}/{route}`; returns the slug too.
    public static func parse(path: String) -> (slug: String, route: AppRoute)? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let slash = trimmed.firstIndex(of: "/") else {
            guard !trimmed.isEmpty else { return nil }
            return (trimmed.removingPercentEncoding ?? trimmed, .issues)
        }
        let slug = String(trimmed[..<slash])
        let rest = String(trimmed[trimmed.index(after: slash)...])
        guard !slug.isEmpty else { return nil }
        let route = AppRoute(relativePath: rest) ?? .issues
        return (slug.removingPercentEncoding ?? slug, route)
    }

    // MARK: Codable as path

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let r = AppRoute(relativePath: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown route \(s)"))
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(relativePath)
    }

    /// Identity used for tab de-duplication (upstream `resourceKey`).
    public var resourceKey: String { relativePath }

    /// Upstream route-icons.ts icon name (lucide), for the tab bar.
    public var iconName: RouteIconName {
        switch self {
        case .attachmentPreview: return .file
        case .member: return .users
        default: return page?.icon ?? .listTodo
        }
    }

    /// Generic title key in the `layout` namespace (`tab.*` or `nav.*`),
    /// used until the page reports a specific title.
    public var fallbackTitle: String {
        switch self {
        case .issue: return tr("layout", "tab.issue")
        case .project: return tr("layout", "tab.project")
        case .autopilot: return tr("layout", "tab.autopilot")
        case .agent: return tr("layout", "tab.agent")
        case .member: return tr("layout", "tab.member")
        case .squad: return tr("layout", "tab.squad")
        case .skill: return tr("layout", "tab.skill")
        case .runtime: return tr("layout", "tab.machine")
        case .runtimeSettings: return tr("layout", "tab.runtime")
        case .attachmentPreview: return tr("layout", "tab.attachment")
        case .newAgent, .newAgentManual, .newAgentAI, .newAgentAISession: return tr("layout", "tab.create_agent")
        default: return page.map { tr("layout", "nav.\($0.navKey)") } ?? tr("layout", "tab.unknown")
        }
    }
}

/// Upstream lucide icon names used by routes (core/paths/route-icons.ts).
public enum RouteIconName: String, Sendable, CaseIterable {
    case inbox = "Inbox", messageSquare = "MessageSquare", circleUser = "CircleUser", listTodo = "ListTodo"
    case folderKanban = "FolderKanban", zap = "Zap", bot = "Bot", users = "Users", barChart3 = "BarChart3"
    case monitor = "Monitor", server = "Server", bookOpenText = "BookOpenText", settings = "Settings"
    case file = "File", fileText = "FileText", fileImage = "FileImage", fileCode = "FileCode"
    case fileArchive = "FileArchive", fileAudio = "FileAudio", fileVideo = "FileVideo", fileQuestion = "FileQuestion"

    /// The SF Symbol drawn for this lucide icon.
    public var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .messageSquare: return "message"
        case .circleUser: return "person.crop.circle"
        case .listTodo: return "checklist"
        case .folderKanban: return "folder"
        case .zap: return "bolt"
        case .bot: return "cpu"
        case .users: return "person.2"
        case .barChart3: return "chart.bar"
        case .monitor: return "desktopcomputer"
        case .server: return "server.rack"
        case .bookOpenText: return "book"
        case .settings: return "gearshape"
        case .file: return "doc"
        case .fileText: return "doc.text"
        case .fileImage: return "photo"
        case .fileCode: return "chevron.left.forwardslash.chevron.right"
        case .fileArchive: return "doc.zipper"
        case .fileAudio: return "waveform"
        case .fileVideo: return "film"
        case .fileQuestion: return "questionmark.square.dashed"
        }
    }

    /// Upstream `iconForAttachment`: extension → file-type icon.
    public static func forAttachment(_ filename: String?) -> RouteIconName {
        guard let filename, let dot = filename.lastIndex(of: "."), dot < filename.index(before: filename.endIndex) else { return .file }
        switch filename[filename.index(after: dot)...].lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "avif", "heic": return .fileImage
        case "mp4", "mov", "webm", "mkv", "avi", "m4v": return .fileVideo
        case "mp3", "wav", "ogg", "flac", "m4a", "aac": return .fileAudio
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2": return .fileArchive
        case "js", "jsx", "ts", "tsx", "json", "yaml", "yml", "py", "go", "rs", "java", "c", "h", "cpp", "cc", "rb", "php", "swift", "kt", "sh", "css", "scss": return .fileCode
        case "txt", "md", "markdown", "pdf", "doc", "docx", "csv", "log", "html", "htm", "xml", "rtf", "odt": return .fileText
        default: return .file
        }
    }
}

/// The sidebar's pages (upstream WORKSPACE_PAGES), in sidebar order.
public enum WorkspacePage: String, CaseIterable, Sendable, Hashable {
    case inbox, myIssues, chat
    case issues, projects, autopilots
    case agents, squads, skills, runtimes
    case usage, settings

    public static let personal: [WorkspacePage] = [.inbox, .myIssues, .chat]
    public static let work: [WorkspacePage] = [.issues, .projects, .autopilots]
    public static let aiTeam: [WorkspacePage] = [.agents, .squads, .skills, .runtimes]
    public static let utility: [WorkspacePage] = [.usage, .settings]

    public var route: AppRoute {
        switch self {
        case .inbox: return .inbox
        case .myIssues: return .myIssues
        case .chat: return .chat
        case .issues: return .issues
        case .projects: return .projects
        case .autopilots: return .autopilots
        case .agents: return .agents
        case .squads: return .squads
        case .skills: return .skills
        case .runtimes: return .runtimes
        case .usage: return .usage
        case .settings: return .settings
        }
    }

    /// Key under `nav.` in the `layout` namespace.
    public var navKey: String {
        switch self {
        case .myIssues: return "my_issues"
        default: return rawValue
        }
    }

    public var title: String { tr("layout", "nav.\(navKey)") }

    public var icon: RouteIconName {
        switch self {
        case .inbox: return .inbox
        case .chat: return .messageSquare
        case .myIssues: return .circleUser
        case .issues: return .listTodo
        case .projects: return .folderKanban
        case .autopilots: return .zap
        case .agents: return .bot
        case .squads: return .users
        case .usage: return .barChart3
        case .runtimes: return .monitor
        case .skills: return .bookOpenText
        case .settings: return .settings
        }
    }
}
