import AppKit
import MulticaCore
import SwiftUI

/// Delete confirmation: the single-issue dialog (upstream
/// DeleteIssueConfirmModal) or the batch-toolbar dialog for several ids.
struct IssueModalDeleteConfirm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let issueIDs: [String]
    @State private var deleting = false

    private var isBatch: Bool { issueIDs.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isBatch ? tr("issues", "batch.delete_dialog_title", ["count": issueIDs.count]) : tr("modals", "delete_issue.title"))
                    .font(Theme.Font.title)
                Text(isBatch ? tr("issues", "batch.delete_dialog_desc", ["count": issueIDs.count]) : tr("modals", "delete_issue.description"))
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isBatch {
                    Text(tr("issues", "batch.delete_dialog_warning"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button(isBatch ? tr("common", "cancel") : tr("modals", "delete_issue.cancel")) { dismiss() }
                    .buttonStyle(IssueModalOutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(deleting)
                Button {
                    Task { await delete() }
                } label: {
                    Text(isBatch ? tr("issues", "batch.delete") : (deleting ? tr("modals", "delete_issue.deleting") : tr("modals", "delete_issue.confirm")))
                }
                .buttonStyle(IssueModalPrimaryButtonStyle(tint: Theme.destructive))
                .disabled(deleting)
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(deleting)
    }

    private func delete() async {
        guard !issueIDs.isEmpty, !deleting else { return }
        deleting = true
        let snapshots = issueIDs.compactMap { session.issues.model($0)?.issue }
        for id in issueIDs { session.issues.remove(id) }
        for id in issueIDs { SearchPaletteRecentCache.rows[id] = nil }
        do {
            if isBatch {
                _ = try await session.api.batchDeleteIssues(issueIDs)
                toaster.success(tr("issues", "batch.delete_success", ["count": issueIDs.count]))
            } else {
                try await session.api.deleteIssue(issueIDs[0])
                toaster.success(tr("modals", "delete_issue.toast_deleted"))
            }
            dismiss()
            if case .issue(let id) = nav.route, issueIDs.contains(id) {
                if nav.canGoBack { nav.back() } else { nav.replace(.issues) }
            }
        } catch {
            for issue in snapshots { session.issues.upsert(issue, isNew: true) }
            if isBatch {
                toaster.error(IssueModalErrors.message(error, fallback: tr("issues", "batch.delete_failed")))
                dismiss()
            } else {
                toaster.error(IssueModalErrors.message(error, fallback: tr("modals", "delete_issue.toast_delete_failed")))
                deleting = false
            }
        }
    }
}

/// Handoff confirmation for the writes that start agent runs (upstream
/// RunConfirmModal): assigning to an agent/squad, or promoting an owned
/// issue out of Backlog. No pre-flight request; completion is silent.
struct IssueModalRunConfirm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let issueID: String
    @State private var intent: IssueModalRunIntent?
    @State private var pendingAction: Bool?

    private var submitting: Bool { pendingAction != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let intent {
                VStack(alignment: .leading, spacing: 8) {
                    Text(intent.mode == .promote ? tr("modals", "run_confirm.title_promote") : tr("modals", "run_confirm.title_assign"))
                        .font(Theme.Font.title)
                    headline(intent)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    dontStartButton(intent)
                    confirmButton(intent)
                }
            }
        }
        .padding(24)
        .frame(width: 512)
        .interactiveDismissDisabled(submitting)
        .onExitCommand { if !submitting { dismiss() } }
        .task { await resolveIntent() }
    }

    private func dontStartButton(_ intent: IssueModalRunIntent) -> some View {
        Button { submit(intent, suppressRun: true) } label: {
            if pendingAction == true { ProgressView().controlSize(.small) } else { Text(tr("modals", "run_confirm.dont_start")) }
        }
        .buttonStyle(IssueModalOutlineButtonStyle())
        .disabled(submitting)
    }

    private func confirmButton(_ intent: IssueModalRunIntent) -> some View {
        Button { submit(intent, suppressRun: false) } label: {
            if pendingAction == false {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Text(intent.mode == .promote ? tr("modals", "run_confirm.confirm_promote") : tr("modals", "run_confirm.confirm_assign"))
                    IssueModalSendKeyCaps()
                }
            }
        }
        .buttonStyle(IssueModalPrimaryButtonStyle())
        .modifier(IssueModalSendShortcut())
        .disabled(submitting)
    }

    /// The registered payload, or the issue's current agent owner.
    private func resolveIntent() async {
        if let pending = IssueModalPending.runIntents.removeValue(forKey: issueID) {
            intent = pending
            return
        }
        var issue = session.issues.model(issueID)?.issue
        if issue == nil { issue = try? await session.api.issue(issueID) }
        if let a = issue?.assignee, a.type == "agent" || a.type == "squad" {
            intent = IssueModalRunIntent(issueIDs: [issueID], mode: .assign, assigneeType: a.type, assigneeID: a.id)
        } else {
            dismiss()
        }
    }

    /// Interpolated names and the status render bold (upstream boldFenced).
    private func headline(_ intent: IssueModalRunIntent) -> Text {
        let name = intent.assigneeName ?? session.actorInfo(type: intent.assigneeType == "squad" ? "squad" : "agent", id: intent.assigneeID).name
        let sentence: String
        if intent.mode == .promote, let status = intent.status {
            sentence = tr("modals", "run_confirm.promote_single", [
                "name": IssueModalFence.fenced(name),
                "status": IssueModalFence.fenced(session.issues.catalog.localizedName(for: IssueStatusKey(rawValue: status))),
            ])
        } else if intent.issueIDs.count > 1 {
            sentence = tr("modals", "run_confirm.assign_batch", ["name": IssueModalFence.fenced(name), "count": intent.issueIDs.count])
        } else {
            sentence = tr("modals", "run_confirm.assign_single", ["name": IssueModalFence.fenced(name)])
        }
        return IssueModalFence.runs(sentence).reduce(Text("")) { acc, run in
            acc + (run.bold ? Text(run.text).fontWeight(.semibold).foregroundColor(.primary) : Text(run.text))
        }
    }

    private func submit(_ intent: IssueModalRunIntent, suppressRun: Bool) {
        guard !intent.issueIDs.isEmpty, !submitting else { return }
        pendingAction = suppressRun
        var record = UpdateIssueRequestRecord()
        if intent.mode == .promote, let status = intent.status {
            record.status = status
        } else {
            record.assigneeType = intent.assigneeType
            record.assigneeId = intent.assigneeID
        }
        if suppressRun { record.suppressRun = true }
        let patch: (inout Issue) -> Void = { issue in
            if intent.mode == .promote, let status = intent.status {
                issue.status = IssueStatusKey(rawValue: status)
                issue.statusCategory = issue.status.builtInCategory
            } else {
                issue.assignee = ActorRef(type: intent.assigneeType, id: intent.assigneeID)
            }
        }
        Task {
            do {
                if intent.issueIDs.count == 1 {
                    try await session.issueModalUpdate(intent.issueIDs[0], record, optimistic: patch)
                } else {
                    var previous: [Issue] = []
                    for id in intent.issueIDs {
                        if let p = session.issues.patch(id, { var i = $0; patch(&i); return i }) { previous.append(p) }
                    }
                    session.issues.resectionIfNeeded()
                    do {
                        _ = try await session.api.batchUpdateIssues(intent.issueIDs, updates: record)
                    } catch {
                        for p in previous { session.issues.restore(p) }
                        throw error
                    }
                }
                dismiss()
            } catch {
                toaster.error(IssueModalErrors.code(error) == "revision_conflict"
                              ? tr("issues", "revision.conflict")
                              : IssueModalErrors.message(error, fallback: tr("modals", "run_confirm.toast_failed")))
                pendingAction = nil
            }
        }
    }
}

enum IssueModalLimitReason {
    case issueLimit, autopilotQuota

    var prefix: String { self == .issueLimit ? "create_issue.issue_limit" : "create_issue.autopilot_quota_limit" }
    func copy(_ key: String) -> String { tr("modals", "\(prefix).\(key)") }
}

/// Centered recovery surface for the workspace issue (or autopilot run)
/// limit (upstream IssueLimitUpgradeDialog). Cloud's available actions are
/// the only input that decides which billing action appears.
struct IssueModalLimitUpgrade: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    var reason: IssueModalLimitReason = .issueLimit
    var onBillingAction: (() -> Void)? = nil

    @State private var actions: JSONValue?
    @State private var loading = false
    @State private var openingPortal = false
    @State private var portalFailed = false
    @State private var portalKey: String?

    private var billingEnabled: Bool {
        env.appConfig?.featureFlags?["billing_workspace_subscriptions"] ?? false
    }

    var body: some View {
        let recovery = IssueModalBillingRecovery.resolve(actions: actions, billingEnabled: billingEnabled,
                                                         loading: billingEnabled && actions == nil && loading, portalFailed: portalFailed)
        let action = actionFor(recovery)
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.brand.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.brand.opacity(0.15)))
                VStack(spacing: 12) {
                    Text(reason.copy("title"))
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(description(recovery))
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            Divider()
            HStack(spacing: 8) {
                Button(tr("modals", "common.close")) { dismiss() }
                    .buttonStyle(IssueModalOutlineButtonStyle())
                    .frame(minWidth: 112)
                    .keyboardShortcut(.cancelAction)
                if let action {
                    Button(action: action.run) {
                        HStack(spacing: 6) {
                            if openingPortal { ProgressView().controlSize(.small) }
                            Text(action.label)
                        }
                        .frame(minWidth: 136)
                    }
                    .buttonStyle(IssueModalPrimaryButtonStyle())
                    .disabled(openingPortal)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .frame(width: 512)
        .task { await loadSummary() }
    }

    private func description(_ r: IssueModalBillingRecovery) -> String {
        switch r {
        case .billingDisabled: return reason.copy("billing_disabled_description")
        case .checkout: return reason.copy("upgrade_description")
        case .portal: return reason.copy("portal_description")
        case .billing: return reason.copy("billing_description")
        case .contactAdmin: return reason.copy("contact_description")
        case .checking: return reason.copy("checking_description")
        case .billingUnavailable: return reason.copy("billing_unavailable_description")
        }
    }

    private func actionFor(_ r: IssueModalBillingRecovery) -> (label: String, run: () -> Void)? {
        switch r {
        case .checkout: return (reason.copy("upgrade_action"), openBilling)
        case .portal: return (reason.copy("portal_action"), { Task { await openPortal() } })
        case .billing, .billingUnavailable: return (reason.copy("billing_action"), openBilling)
        case .billingDisabled, .contactAdmin, .checking: return nil
        }
    }

    private func loadSummary() async {
        guard billingEnabled else { return }
        loading = true
        if let summary = try? await session.api.getWorkspaceSubscriptionSummary() { actions = summary.availableActions }
        loading = false
    }

    private func closeForBillingAction() {
        dismiss()
        onBillingAction?()
    }

    private func openBilling() {
        closeForBillingAction()
        nav.push(.settings, query: ["tab": "billing"])
    }

    private func openPortal() async {
        let key = portalKey ?? String("issue-limit-portal-\(session.workspace.id)-\(UUID().uuidString.lowercased())".prefix(255))
        portalKey = key
        openingPortal = true
        defer { openingPortal = false }
        do {
            guard let response = try await session.api.createWorkspaceSubscriptionPortal(idempotencyKey: key),
                  let url = URL(string: response.url), !response.url.isEmpty else {
                portalFailed = true
                return
            }
            portalKey = nil
            closeForBillingAction()
            NSWorkspace.shared.open(url)
        } catch {
            portalFailed = true
        }
    }
}
