import MulticaCore
import SwiftUI

/// Right pane: the selected item's issue, or the notification itself when it
/// has no issue (failed quick-create, autopilot notices).
struct InboxDetailPane: View {
    let model: InboxPageModel

    var body: some View {
        if model.viewLoading {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 190, height: 22)
                RoundedRectangle(cornerRadius: 4).fill(Theme.hover).frame(width: 130, height: 14)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let item = model.selected {
            if let issueID = item.issueID {
                IssueDetailPage(issueID: issueID, highlightCommentID: item.details["comment_id"],
                                onDone: { model.archive(item.id) }, onDelete: { model.select("") })
                    .id(issueID)
            } else {
                ScrollView {
                    InboxNotificationDetail(item: item, model: model)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(item.id)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "tray").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                Text(model.visibleItems.isEmpty ? tr("inbox", "detail.empty") : tr("inbox", "detail.select_prompt"))
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct InboxNotificationDetail: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @Environment(Toaster.self) private var toaster
    let item: InboxItem
    let model: InboxPageModel
    @State private var retrying = false

    private var isQuota: Bool { InboxDisplay.isAutopilotQuotaNotice(item.type) }
    private var isOutcome: Bool { InboxDisplay.isQuickCreateOutcome(item.type) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(InboxText.title(item))
                .font(Theme.Font.title)
                .textSelection(.enabled)
            Text("\(InboxText.typeLabel(item.type)) · \(InboxText.timeAgo(item.createdAt))")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if isQuota {
                InboxAutopilotQuotaNotice(item: item) { modals.present(.issueLimitUpgrade) }
            } else if let body = item.body, !body.isEmpty {
                Text(body)
                    .font(Theme.Font.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.top, 16)
            }
            if isOutcome, let prompt = item.details["original_prompt"], !prompt.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("inbox", "detail.original_input"))
                        .font(Theme.Font.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(prompt).font(Theme.Font.body).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                .padding(.top, 16)
            }
            HStack(spacing: 8) {
                if item.type == "quick_create_failed", item.details["source_context_id"] != nil, let taskID = item.details["task_id"] {
                    Button(tr("inbox", "detail.retry_with_context")) { retry(taskID) }
                        .buttonStyle(.borderedProminent)
                        .disabled(retrying)
                }
                if isOutcome {
                    Button(tr("inbox", "detail.edit_advanced")) { editAdvanced() }
                        .buttonStyle(.borderedProminent)
                }
                if model.isArchived {
                    Button { model.unarchive(item.id) } label: {
                        Label(tr("inbox", "detail.unarchive"), systemImage: "tray.and.arrow.up")
                    }
                } else {
                    Button { model.archive(item.id) } label: {
                        Label(tr("inbox", "detail.archive"), systemImage: "archivebox")
                    }
                }
            }
            .controlSize(.small)
            .padding(.top, 16)
        }
        .padding(24)
    }

    private func editAdvanced() {
        var draft = CreateIssueDraft()
        draft.description = item.details["original_prompt"] ?? ""
        if let agentID = item.details["agent_id"], !agentID.isEmpty {
            draft.assignee = ActorRef(type: "agent", id: agentID)
        }
        modals.present(.createIssue(draft))
    }

    private func retry(_ taskID: String) {
        retrying = true
        Task {
            defer { retrying = false }
            do {
                try await session.inboxRetrySourceContext(taskID: taskID)
                toaster.success(tr("inbox", "toasts.source_context_retry_started"))
            } catch let e as APIError where e.status == 402 {
                modals.present(.issueLimitUpgrade)
            } catch let e as APIError where e.status == 409 {
                toaster.error(tr("inbox", "errors.source_context_retry_unavailable"))
            } catch {
                toaster.error(tr("inbox", "errors.source_context_retry_failed"))
            }
        }
    }
}

/// Autopilot quota notice body + upgrade entry (upstream
/// autopilot-quota-notice.tsx).
struct InboxAutopilotQuotaNotice: View {
    let item: InboxItem
    let onOpenRecovery: () -> Void

    private var body_: String? {
        if let limit = item.details["limit"], !limit.isEmpty,
           let raw = item.details["reset_at"], let date = Timestamp.parse(raw) {
            let resetAt = date.formatted(date: .abbreviated, time: .shortened)
            return tr("inbox", "detail.autopilot_quota_exceeded_body", ["limit": limit, "resetAt": resetAt])
        }
        return item.body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let text = body_, !text.isEmpty {
                Text(text).font(Theme.Font.body).lineSpacing(3).textSelection(.enabled)
            }
            Button(tr("inbox", "detail.autopilot_quota_upgrade"), action: onOpenRecovery)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.top, 16)
    }
}
