import Foundation
import Observation

/// Device-local preferences edited in Settings › Preferences and read by the
/// screens they affect, under the upstream persisted-store names
/// (`multica_comment_composer`, `multica_issue_opening`,
/// `multica:chat:floatingChatEnabled`, `multica_issue_create_settings`).
@MainActor
@Observable
final class SettingsDevicePreferences {
    static let shared = SettingsDevicePreferences()

    enum Keys {
        static let commentComposer = "multica_comment_composer"
        static let issueOpening = "multica_issue_opening"
        static let floatingChat = "multica:chat:floatingChatEnabled"
        static let issueCreate = "multica_issue_create_settings"
    }

    enum RunningAgentReply: String, CaseIterable { case steer, afterRun = "after_run" }
    enum IssueOpenMode: String, CaseIterable { case page, peek }

    /// Fields of the create-issue dialogs, in canonical order.
    static let manualCreateFields = ["status", "priority", "assignee", "labels", "project", "due_date", "start_date"]
    static let quickCreateFields = ["project", "priority", "due_date"]
    static let defaultManualCreateFields = ["status", "priority", "assignee", "labels", "project"]
    static let defaultQuickCreateFields = ["project"]

    /// Pins the issue comment bar to the bottom of the timeline.
    var stickyCommentBar: Bool { didSet { saveComposer() } }
    var runningAgentReply: RunningAgentReply { didSet { saveComposer() } }
    var issueOpenMode: IssueOpenMode {
        didSet { UserDefaults.standard.set(issueOpenMode.rawValue, forKey: Keys.issueOpening) }
    }
    /// When off the floating chat button and panel never show.
    var floatingChatEnabled: Bool {
        didSet { UserDefaults.standard.set(floatingChatEnabled, forKey: Keys.floatingChat) }
    }
    @ObservationIgnored private var createFields: [String: (quick: [String], manual: [String])] = [:]
    private var createFieldsRevision = 0

    private init() {
        let d = UserDefaults.standard
        let composer = d.dictionary(forKey: Keys.commentComposer) ?? [:]
        stickyCommentBar = composer["sticky"] as? Bool ?? true
        runningAgentReply = (composer["runningAgentReply"] as? String).flatMap(RunningAgentReply.init(rawValue:)) ?? .steer
        issueOpenMode = d.string(forKey: Keys.issueOpening) == IssueOpenMode.peek.rawValue ? .peek : .page
        floatingChatEnabled = d.object(forKey: Keys.floatingChat) as? Bool ?? true
    }

    private func saveComposer() {
        UserDefaults.standard.set(["sticky": stickyCommentBar, "runningAgentReply": runningAgentReply.rawValue], forKey: Keys.commentComposer)
    }

    // MARK: Create-issue fields (per workspace)

    private func fields(_ workspaceID: String) -> (quick: [String], manual: [String]) {
        _ = createFieldsRevision
        if let cached = createFields[workspaceID] { return cached }
        let stored = UserDefaults.standard.dictionary(forKey: "\(Keys.issueCreate):\(workspaceID)") ?? [:]
        let value = (quick: stored["quickCreateFields"] as? [String] ?? Self.defaultQuickCreateFields,
                     manual: stored["manualCreateFields"] as? [String] ?? Self.defaultManualCreateFields)
        createFields[workspaceID] = value
        return value
    }

    func quickCreateFields(workspaceID: String) -> [String] { fields(workspaceID).quick }
    func manualCreateFields(workspaceID: String) -> [String] { fields(workspaceID).manual }

    func setQuickCreateField(_ field: String, visible: Bool, workspaceID: String) {
        var f = fields(workspaceID)
        f.quick = Self.quickCreateFields.filter { $0 == field ? visible : f.quick.contains($0) }
        store(f, workspaceID)
    }

    func setManualCreateField(_ field: String, visible: Bool, workspaceID: String) {
        var f = fields(workspaceID)
        f.manual = Self.manualCreateFields.filter { $0 == field ? visible : f.manual.contains($0) }
        store(f, workspaceID)
    }

    private func store(_ f: (quick: [String], manual: [String]), _ workspaceID: String) {
        createFields[workspaceID] = f
        createFieldsRevision += 1
        UserDefaults.standard.set(["quickCreateFields": f.quick, "manualCreateFields": f.manual], forKey: "\(Keys.issueCreate):\(workspaceID)")
    }
}
