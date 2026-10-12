import MulticaCore
import Observation
import SwiftUI

/// The captured source context of a "create sub-issue from this comment"
/// session (upstream sourceContextPreviewOptions + SourceContextPreviewCard).
@MainActor
@Observable
final class IssueModalSourceContext {
    let anchorCommentID: String
    private(set) var preview: SourceContextPreview?
    private(set) var loading = true
    private(set) var error: APIError?
    private(set) var failed = false
    var expanded = false

    init(anchorCommentID: String) {
        self.anchorCommentID = anchorCommentID
    }

    /// The preview usable for submit: none while loading or after a failure.
    var usablePreview: SourceContextPreview? { loading || failed ? nil : preview }

    func load(_ api: APIClient) async {
        loading = true
        do {
            preview = try await api.getCommentSubIssuePreview(anchorCommentId: anchorCommentID)
            error = nil
            failed = false
        } catch {
            self.error = error as? APIError ?? APIError(status: 0, message: error.localizedDescription)
            failed = true
        }
        loading = false
    }

    /// Upstream useSourceContextFailureMessage.
    static func failureMessage(_ error: Error?) -> String? {
        guard let body = error.flatMap(IssueModalErrors.body) else { return nil }
        switch body["code"]?.stringValue {
        case "anchor_comment_deleted": return tr("issues", "source_context.preview_anchor_deleted")
        case "source_issue_deleted": return tr("issues", "source_context.preview_issue_deleted")
        case "source_context_too_large":
            guard let limits = body["limits"] else { return nil }
            var messages: [String] = []
            if let n = limits["comment_count"]?.doubleValue, n > 256 {
                messages.append(tr("issues", "source_context.error_comment_limit", ["count": Int(n)]))
            }
            if let n = limits["text_bytes"]?.doubleValue, n > 1024 * 1024 {
                messages.append(tr("issues", "source_context.error_text_limit", ["size": Int(n)]))
            }
            if let n = limits["attachment_count"]?.doubleValue, n > 100 {
                messages.append(tr("issues", "source_context.error_attachment_count_limit", ["count": Int(n)]))
            }
            if let n = limits["attachment_bytes"]?.doubleValue, n > 500 * 1024 * 1024 {
                messages.append(tr("issues", "source_context.error_attachment_size_limit", ["size": Int(n)]))
            }
            return messages.isEmpty ? tr("issues", "source_context.error_too_large") : messages.joined(separator: " ")
        default:
            return nil
        }
    }

    static func isDeletedSource(_ error: Error?) -> Bool {
        let code = error.flatMap(IssueModalErrors.code)
        return code == "anchor_comment_deleted" || code == "source_issue_deleted"
    }
}

struct IssueModalSourceContextCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Bindable var source: IssueModalSourceContext

    var body: some View {
        Group {
            if source.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(tr("issues", "source_context.preview_loading"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            } else if let preview = source.preview, !source.failed {
                loaded(preview)
            } else {
                HStack(spacing: 12) {
                    Text(IssueModalSourceContext.failureMessage(source.error) ?? tr("issues", "source_context.preview_failed"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !IssueModalSourceContext.isDeletedSource(source.error) {
                        Button {
                            Task { await source.load(session.api) }
                        } label: {
                            Label(tr("issues", "source_context.refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.destructive.opacity(0.4)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func loaded(_ preview: SourceContextPreview) -> some View {
        let anchor = preview.commentThread.first { $0.id == preview.anchorCommentId }
        VStack(alignment: .leading, spacing: 0) {
            Button { source.expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(source.expanded ? 90 : 0))
                    Text(tr("issues", "source_context.preview_summary", [
                        "identifier": preview.sourceIssue?.identifier ?? "", "count": preview.commentThread.count,
                    ]))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    if let name = anchor?.author?.name, !name.isEmpty {
                        Text("· \(name)").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if source.expanded {
                Divider()
                ScrollView {
                    IssueModalSourceContextContent(preview: preview).padding(12)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }
}

/// Source issue snapshot plus its captured comment thread (upstream
/// SourceContextContent + SourceContextCommentList).
struct IssueModalSourceContextContent: View {
    let preview: SourceContextPreview

    var body: some View {
        let comments = preview.commentThread.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
        VStack(alignment: .leading, spacing: 24) {
            if let issue = preview.sourceIssue {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(issue.identifier) · \(issue.title)").font(Theme.Font.bodyMedium).fixedSize(horizontal: false, vertical: true)
                    if let d = issue.description, !d.isEmpty { MarkdownView(source: d) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(comments) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle().fill(Theme.border).frame(width: 2)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(c.author?.name ?? "").lineLimit(1)
                                if c.id == preview.anchorCommentId {
                                    Text(tr("issues", "source_context.source_comment"))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 2).fill(Theme.info.opacity(0.1)))
                                        .foregroundStyle(Theme.info)
                                }
                            }
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            if c.deleted == true {
                                Text(tr("issues", "comment.deleted_placeholder")).italic().foregroundStyle(.secondary)
                            } else {
                                MarkdownView(source: c.content)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel(tr("issues", "source_context.thread_history"))
        }
    }
}
