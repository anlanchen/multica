import Foundation
import Observation

/// One file in the create dialog's shared upload pool (upstream DraftUpload).
/// Both modes reference the same pool so an image survives a mode switch.
public struct IssueModalDraftUpload: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case uploading, uploaded, failed
    }

    public var id: String
    public var status: Status
    public var filename: String
    public var attachmentID: String?
    public var url: String?
    public var downloadURL: String?
    public var markdownURL: String?
    public var contentType: String?
    public var error: String?

    public init(id: String, status: Status, filename: String, attachmentID: String? = nil, url: String? = nil,
                downloadURL: String? = nil, markdownURL: String? = nil, contentType: String? = nil, error: String? = nil) {
        self.id = id
        self.status = status
        self.filename = filename
        self.attachmentID = attachmentID
        self.url = url
        self.downloadURL = downloadURL
        self.markdownURL = markdownURL
        self.contentType = contentType
        self.error = error
    }

    /// Whether `content` links this upload (upstream contentReferencesAttachment).
    public func isReferenced(in content: String) -> Bool {
        guard status == .uploaded, let attachmentID else { return false }
        return IssueModalAttachments.contentReferences(content, id: attachmentID, url: url, downloadURL: downloadURL, markdownURL: markdownURL)
    }
}

/// The unified issue-create draft (upstream draft-store, MUL-5181): a shared
/// slot that belongs to the issue however it is filed, plus one slot per form
/// so switching modes never destroys the other side's content.
public struct IssueModalDraft: Codable, Sendable, Equatable {
    public struct Shared: Codable, Sendable, Equatable {
        public var projectID: String?
        public var priority: String = "none"
        public var dueDate: String?
        public var attachments: [IssueModalDraftUpload] = []
        public init() {}
    }

    public struct Manual: Codable, Sendable, Equatable {
        public var title = ""
        public var description = ""
        public var status = "todo"
        public var startDate: String?
        public var assigneeType: String?
        public var assigneeID: String?
        public var labelIDs: [String] = []
        public var propertyValues: [String: JSONValue] = [:]
        public init() {}
    }

    public struct Agent: Codable, Sendable, Equatable {
        public var prompt = ""
        public var actorType: String?
        public var actorID: String?
        public init() {}
    }

    public var shared = Shared()
    public var manual = Manual()
    public var agent = Agent()
    public var activeMode = "manual"

    public init() {}

    /// Upstream `hasDraft`: typed content or a recoverable upload.
    public var hasContent: Bool {
        !manual.title.isEmpty || !manual.description.isEmpty || !agent.prompt.isEmpty
            || !manual.propertyValues.isEmpty
            || shared.attachments.contains { $0.status == .uploaded || $0.status == .uploading }
    }

    /// Drops completed uploads neither body references any more; in-flight
    /// and failed placeholders stay (their chips are their only UI).
    public mutating func pruneUploads() {
        let manualBody = manual.description
        let agentBody = agent.prompt
        shared.attachments.removeAll { u in
            u.status == .uploaded && !u.isReferenced(in: manualBody) && !u.isReferenced(in: agentBody)
        }
    }
}

extension IssueModalDraft.Shared {
    enum CodingKeys: String, CodingKey { case projectID, priority, dueDate, attachments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try? c.decodeIfPresent(String.self, forKey: .projectID)
        priority = (try? c.decodeIfPresent(String.self, forKey: .priority)) ?? "none"
        dueDate = try? c.decodeIfPresent(String.self, forKey: .dueDate)
        attachments = (try? c.decodeIfPresent([IssueModalDraftUpload].self, forKey: .attachments)) ?? []
    }
}

extension IssueModalDraft.Manual {
    enum CodingKeys: String, CodingKey { case title, description, status, startDate, assigneeType, assigneeID, labelIDs, propertyValues }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "todo"
        startDate = try? c.decodeIfPresent(String.self, forKey: .startDate)
        assigneeType = try? c.decodeIfPresent(String.self, forKey: .assigneeType)
        assigneeID = try? c.decodeIfPresent(String.self, forKey: .assigneeID)
        labelIDs = (try? c.decodeIfPresent([String].self, forKey: .labelIDs)) ?? []
        propertyValues = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .propertyValues)) ?? [:]
    }
}

extension IssueModalDraft.Agent {
    enum CodingKeys: String, CodingKey { case prompt, actorType, actorID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = (try? c.decodeIfPresent(String.self, forKey: .prompt)) ?? ""
        actorType = try? c.decodeIfPresent(String.self, forKey: .actorType)
        actorID = try? c.decodeIfPresent(String.self, forKey: .actorID)
    }
}

extension IssueModalDraft {
    enum CodingKeys: String, CodingKey { case shared, manual, agent, activeMode }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shared = (try? c.decodeIfPresent(Shared.self, forKey: .shared)) ?? Shared()
        manual = (try? c.decodeIfPresent(Manual.self, forKey: .manual)) ?? Manual()
        agent = (try? c.decodeIfPresent(Agent.self, forKey: .agent)) ?? Agent()
        activeMode = (try? c.decodeIfPresent(String.self, forKey: .activeMode)) == "agent" ? "agent" : "manual"
    }
}

/// Which optional toolbar fields each create mode shows (upstream
/// issue-create-settings-store, owned by Settings → Preferences → Issue
/// creation). Hidden fields stay reachable from the dialog's overflow menu.
public struct IssueModalCreateSettings: Codable, Sendable, Equatable {
    public static let manualFieldOrder = ["status", "priority", "assignee", "labels", "project", "due_date", "start_date"]
    public static let quickFieldOrder = ["project", "priority", "due_date"]
    public static let defaultManualFields = ["status", "priority", "assignee", "labels", "project"]
    public static let defaultQuickFields = ["project"]

    public var manualFields: [String]
    public var quickFields: [String]

    public init(manualFields: [String] = IssueModalCreateSettings.defaultManualFields,
                quickFields: [String] = IssueModalCreateSettings.defaultQuickFields) {
        self.manualFields = manualFields
        self.quickFields = quickFields
    }

    public static func key(workspaceID: String) -> String { "multica.issueCreateSettings.\(workspaceID)" }

    public static func load(workspaceID: String, defaults: UserDefaults = .standard) -> IssueModalCreateSettings {
        guard let data = defaults.data(forKey: key(workspaceID: workspaceID)),
              let s = try? JSONDecoder().decode(IssueModalCreateSettings.self, from: data) else { return IssueModalCreateSettings() }
        return s
    }

    public func save(workspaceID: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(workspaceID: workspaceID)) }
    }

    /// Canonical-order toggle, so one selection never has two encodings.
    public mutating func setManualField(_ field: String, visible: Bool) {
        manualFields = Self.manualFieldOrder.filter { $0 == field ? visible : manualFields.contains($0) }
    }

    public mutating func setQuickField(_ field: String, visible: Bool) {
        quickFields = Self.quickFieldOrder.filter { $0 == field ? visible : quickFields.contains($0) }
    }
}

/// Per-workspace persistence of the create draft and the create dialog's
/// remembered choices (last assignee, last agent/squad, keep-open toggle).
@MainActor
@Observable
public final class IssueModalDraftStore {
    public let workspaceID: String
    public private(set) var draft: IssueModalDraft
    /// Bumped on every write. Success clears only the draft it submitted
    /// (upstream stale-submit guard, MUL-5181 P0).
    public private(set) var generation = 0
    public private(set) var lastAssigneeType: String?
    public private(set) var lastAssigneeID: String?
    public private(set) var lastActorType: String?
    public private(set) var lastActorID: String?
    public var keepOpen: Bool {
        didSet {
            guard keepOpen != oldValue else { return }
            base?.keepOpen = keepOpen
            schedulePersist()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private weak var base: IssueModalDraftStore?
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    private static var instances: [String: IssueModalDraftStore] = [:]

    public static func shared(workspaceID: String) -> IssueModalDraftStore {
        if let s = instances[workspaceID] { return s }
        let s = IssueModalDraftStore(workspaceID: workspaceID)
        instances[workspaceID] = s
        return s
    }

    private struct Persisted: Codable {
        var draft: IssueModalDraft?
        var lastAssigneeType: String?
        var lastAssigneeID: String?
        var lastActorType: String?
        var lastActorID: String?
        var keepOpen: Bool?
    }

    public static func key(workspaceID: String) -> String { "multica.issueDraft.\(workspaceID)" }

    public init(workspaceID: String, defaults: UserDefaults = .standard) {
        self.workspaceID = workspaceID
        self.defaults = defaults
        self.persistent = true
        let saved = defaults.data(forKey: Self.key(workspaceID: workspaceID)).flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        var d = saved?.draft ?? IssueModalDraft()
        d.shared.attachments.removeAll { $0.status == .uploading }
        draft = d
        lastAssigneeType = saved?.lastAssigneeType
        lastAssigneeID = saved?.lastAssigneeID
        lastActorType = saved?.lastActorType
        lastActorID = saved?.lastActorID
        keepOpen = saved?.keepOpen ?? false
    }

    /// An in-memory draft for a source-context create session: it starts
    /// empty in agent mode and never touches the persisted draft (upstream
    /// beginIsolatedDraft).
    public init(isolatedFrom base: IssueModalDraftStore) {
        workspaceID = base.workspaceID
        defaults = .standard
        persistent = false
        var d = IssueModalDraft()
        d.manual.assigneeType = base.lastAssigneeType
        d.manual.assigneeID = base.lastAssigneeID
        d.activeMode = "agent"
        draft = d
        lastAssigneeType = base.lastAssigneeType
        lastAssigneeID = base.lastAssigneeID
        lastActorType = base.lastActorType
        lastActorID = base.lastActorID
        keepOpen = base.keepOpen
        self.base = base
    }

    public func update(_ body: (inout IssueModalDraft) -> Void) {
        var next = draft
        body(&next)
        guard next != draft else { return }
        draft = next
        generation &+= 1
        schedulePersist()
    }

    /// Fresh draft after a successful create; the last assignee seeds the
    /// next manual draft and the active mode is kept.
    public func clearDraft() {
        var fresh = IssueModalDraft()
        fresh.manual.assigneeType = lastAssigneeType
        fresh.manual.assigneeID = lastAssigneeID
        fresh.activeMode = draft.activeMode
        draft = fresh
        generation &+= 1
        schedulePersist()
    }

    public func setLastAssignee(type: String?, id: String?) {
        lastAssigneeType = type
        lastAssigneeID = id
        base?.setLastAssignee(type: type, id: id)
        schedulePersist()
    }

    public func setLastActor(type: String?, id: String?) {
        lastActorType = type
        lastActorID = id
        base?.setLastActor(type: type, id: id)
        schedulePersist()
    }

    private func schedulePersist() {
        guard persistent else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.persistNow()
        }
    }

    public func persistNow() {
        guard persistent else { return }
        let p = Persisted(draft: draft, lastAssigneeType: lastAssigneeType, lastAssigneeID: lastAssigneeID,
                          lastActorType: lastActorType, lastActorID: lastActorID, keepOpen: keepOpen)
        if let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: Self.key(workspaceID: workspaceID)) }
    }
}
