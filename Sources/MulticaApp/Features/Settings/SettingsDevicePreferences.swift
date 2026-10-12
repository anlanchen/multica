import Foundation
import MulticaCore
import Observation

/// Device-local preferences edited in Settings › Preferences and read by the
/// screens they affect, under the upstream persisted-store names
/// (`multica_comment_composer`, `multica_issue_opening`). Floating chat
/// lives in `ChatUIStore`, create-dialog fields in `IssueModalCreateSettings`.
@MainActor
@Observable
final class SettingsDevicePreferences {
    static let shared = SettingsDevicePreferences()

    enum Keys {
        static let commentComposer = "multica_comment_composer"
        static let issueOpening = "multica_issue_opening"
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
    @ObservationIgnored private var createFields: [String: (quick: [String], manual: [String])] = [:]
    private var createFieldsRevision = 0

    private init() {
        let d = UserDefaults.standard
        let composer = d.dictionary(forKey: Keys.commentComposer) ?? [:]
        stickyCommentBar = composer["sticky"] as? Bool ?? true
        runningAgentReply = (composer["runningAgentReply"] as? String).flatMap(RunningAgentReply.init(rawValue:)) ?? .steer
        issueOpenMode = d.string(forKey: Keys.issueOpening) == IssueOpenMode.peek.rawValue ? .peek : .page
    }

    private func saveComposer() {
        UserDefaults.standard.set(["sticky": stickyCommentBar, "runningAgentReply": runningAgentReply.rawValue], forKey: Keys.commentComposer)
    }

    // MARK: Create-issue fields (per workspace)

    /// Shared with the create dialog through `IssueModalCreateSettings`.
    private func fields(_ workspaceID: String) -> (quick: [String], manual: [String]) {
        _ = createFieldsRevision
        if let cached = createFields[workspaceID] { return cached }
        let stored = IssueModalCreateSettings.load(workspaceID: workspaceID)
        let value = (quick: stored.quickFields, manual: stored.manualFields)
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
        IssueModalCreateSettings(manualFields: f.manual, quickFields: f.quick).save(workspaceID: workspaceID)
    }
}
