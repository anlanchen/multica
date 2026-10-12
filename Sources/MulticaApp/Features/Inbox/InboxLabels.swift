import MulticaCore
import SwiftUI

/// Upstream `useTypeLabels` / `useTimeAgo` for inbox rows.
enum InboxText {
    static func typeLabel(_ type: String) -> String {
        InboxDisplay.knownTypes.contains(type) ? tr("inbox", "types.\(type)") : type
    }

    static func timeAgo(_ timestamp: String) -> String {
        switch InboxDisplay.age(of: timestamp) {
        case .justNow: return tr("inbox", "list.time.just_now")
        case .minutes(let n): return tr("inbox", "list.time.minutes", ["count": n])
        case .hours(let n): return tr("inbox", "list.time.hours", ["count": n])
        case .days(let n): return tr("inbox", "list.time.days", ["count": n])
        }
    }

    /// Row title: the type label for the quota notice, the cleaned title
    /// otherwise.
    static func title(_ item: InboxItem) -> String {
        InboxDisplay.isAutopilotQuotaNotice(item.type) ? typeLabel(item.type) : InboxDisplay.title(item)
    }

    /// Calendar-day dates (start/due) formatted without a timezone shift.
    static func shortDate(_ raw: String) -> String {
        guard let d = Formatters.dateOnly(raw) else { return raw }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The second line of a row: what happened (upstream InboxDetailLabel).
struct InboxDetailLabel: View {
    @Environment(WorkspaceSession.self) private var session
    let item: InboxItem

    var body: some View {
        let d = item.details
        switch item.type {
        case "status_changed" where d["to"] != nil:
            let key = IssueStatusKey(rawValue: d["to"] ?? "")
            HStack(spacing: 4) {
                Text(tr("inbox", "labels.set_status_to"))
                session.issues.catalog.icon(for: key, size: 11)
                Text(session.issues.catalog.localizedName(for: key))
            }
        case "priority_changed" where d["to"] != nil:
            let p = IssuePriority(rawValue: d["to"] ?? "") ?? .none
            HStack(spacing: 4) {
                Text(tr("inbox", "labels.set_priority_to"))
                PriorityIcon(priority: p, size: 11)
                Text(p.localizedName)
            }
        default:
            Text(text)
        }
    }

    private var text: String {
        let d = item.details
        switch item.type {
        case "issue_assigned", "assignee_changed":
            if let id = d["new_assignee_id"], !id.isEmpty {
                let name = session.actorInfo(type: d["new_assignee_type"] ?? "member", id: id).name
                return tr("inbox", "labels.assigned_to", ["name": name])
            }
        case "unassigned":
            return tr("inbox", "labels.removed_assignee")
        case "start_date_changed":
            if let to = d["to"], !to.isEmpty { return tr("inbox", "labels.set_start_date_to", ["date": InboxText.shortDate(to)]) }
            return tr("inbox", "labels.removed_start_date")
        case "due_date_changed":
            if let to = d["to"], !to.isEmpty { return tr("inbox", "labels.set_due_date_to", ["date": InboxText.shortDate(to)]) }
            return tr("inbox", "labels.removed_due_date")
        case "new_comment":
            if let body = item.body, !body.isEmpty { return body }
        case "reaction_added":
            if let emoji = d["emoji"], !emoji.isEmpty { return tr("inbox", "labels.reacted_to_comment", ["emoji": emoji]) }
        case "quick_create_done":
            if let identifier = d["identifier"], !identifier.isEmpty { return tr("inbox", "labels.created_with_agent", ["identifier": identifier]) }
        case "quick_create_failed":
            let detail = InboxDisplay.quickCreateOutcomeDetail(item)
            if !detail.isEmpty { return tr("inbox", "labels.failed_with_detail", ["detail": detail]) }
        case "quick_create_unconfirmed":
            let detail = InboxDisplay.quickCreateOutcomeDetail(item)
            if !detail.isEmpty { return detail }
        case "autopilot_quota_exceeded":
            return tr("inbox", "labels.autopilot_quota_blocked")
        case "children_done":
            if let stage = d["stage"], !stage.isEmpty { return tr("inbox", "labels.children_done_stage", ["stage": stage]) }
        default:
            break
        }
        return InboxText.typeLabel(item.type)
    }
}
