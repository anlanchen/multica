import AppKit
import MulticaCore
import SwiftUI

/// Issue-create binding of the upload flow (upstream use-issue-create-uploads):
/// both modes share one pool in the draft, so a file survives a mode switch
/// and dialog close. A file that lands after its editor is gone is appended
/// to the body it was pasted into.
@MainActor
enum IssueModalUploads {
    static func upload(_ urls: [URL], session: WorkspaceSession, store: IssueModalDraftStore, mode: CreateIssueMode,
                       target: IssueModalEditorTarget, toaster: Toaster) {
        for url in urls {
            let clientID = UUID().uuidString
            let name = url.lastPathComponent
            store.update { $0.shared.attachments.append(IssueModalDraftUpload(id: clientID, status: .uploading, filename: name)) }
            Task {
                do {
                    let a = try await session.upload(fileAt: url)
                    let settled = IssueModalDraftUpload(id: clientID, status: .uploaded, filename: a.filename.isEmpty ? name : a.filename,
                                                        attachmentID: a.id, url: a.url, downloadURL: a.downloadUrl,
                                                        markdownURL: a.markdownUrl, contentType: a.contentType)
                    guard store.draft.shared.attachments.contains(where: { $0.id == clientID }) else { return }
                    store.update { d in
                        if let i = d.shared.attachments.firstIndex(where: { $0.id == clientID }) { d.shared.attachments[i] = settled }
                    }
                    let markdown = AttachmentUpload.markdown(for: a)
                    if !target.insert(markdown) {
                        store.update { d in
                            if mode == .agent {
                                d.agent.prompt = IssueModalAttachments.appendMarkdown(d.agent.prompt, markdown)
                            } else {
                                d.manual.description = IssueModalAttachments.appendMarkdown(d.manual.description, markdown)
                            }
                        }
                    }
                } catch {
                    let reason = IssueModalErrors.message(error, fallback: "")
                    store.update { d in
                        if let i = d.shared.attachments.firstIndex(where: { $0.id == clientID }) {
                            d.shared.attachments[i].status = .failed
                            d.shared.attachments[i].error = reason
                        }
                    }
                    toaster.error(tr("editor", "upload.failed", ["filename": name, "reason": reason]))
                }
            }
        }
    }
}

/// The description/prompt text view a paste or drop came from, so a
/// finished upload lands at its caret (NSTextView keeps its selection while
/// unfocused). Gone views fall back to appending to the draft body.
@MainActor
final class IssueModalEditorTarget {
    weak var textView: NSTextView?
    /// Set while the body editor is on screen: appends to its text.
    var fallback: ((String) -> Void)?

    func capture() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable, !tv.isFieldEditor {
            textView = tv
        }
    }

    func insert(_ markdown: String) -> Bool {
        if let tv = textView, tv.window != nil {
            let range = tv.selectedRange()
            let s = tv.string as NSString
            let needsBreak = range.location > 0 && range.location <= s.length && s.character(at: range.location - 1) != 10
            tv.insertText((needsBreak ? "\n" : "") + markdown + "\n", replacementRange: range)
            return true
        }
        if let fallback {
            fallback(markdown)
            return true
        }
        return false
    }
}

/// In-flight and failed upload chips under the editor (upstream upload
/// placeholders): failures stay until removed.
struct IssueModalUploadChips: View {
    let store: IssueModalDraftStore

    var body: some View {
        let pending = store.draft.shared.attachments.filter { $0.status != .uploaded }
        if !pending.isEmpty {
            IssueModalFlowLayout(spacing: 6, lineSpacing: 4) {
                ForEach(pending) { u in
                    HStack(spacing: 5) {
                        if u.status == .uploading {
                            ProgressView().controlSize(.mini)
                            Text(tr("editor", "upload.uploading_label", ["filename": u.filename])).lineLimit(1)
                        } else {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.destructive)
                            Text(tr("editor", "upload.failed_label", ["filename": u.filename])).lineLimit(1)
                                .help(u.error ?? "")
                            Button {
                                store.update { $0.shared.attachments.removeAll { $0.id == u.id } }
                            } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(tr("editor", "upload.remove"))
                        }
                    }
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }
}
