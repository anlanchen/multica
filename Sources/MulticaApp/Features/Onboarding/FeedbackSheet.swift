import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Send feedback with optional attachments (upstream modals/feedback.tsx).
/// The draft survives closing the dialog until it is sent.
struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(AppEnvironment.self) private var env
    @Environment(Toaster.self) private var toaster
    @State private var message = UserDefaults.standard.string(forKey: FeedbackSheet.draftKey) ?? ""
    @State private var uploads = ComposerUploads()
    @State private var sending = false
    @State private var importing = false

    static let draftKey = "multica.feedback.draft"
    static let maxLength = 10_000

    private var canSubmit: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.count <= Self.maxLength && !sending && !uploads.isUploading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("modals", "feedback.title")).font(Theme.Font.title)
                (Text(tr("modals", "feedback.github_hint_prefix"))
                    + Text("[\(tr("modals", "feedback.github_hint_link"))](https://github.com/multica-ai/multica/issues)"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .tint(Theme.brand)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                MarkdownEditor(
                    text: $message,
                    placeholder: tr("modals", "feedback.placeholder"),
                    minHeight: 280,
                    maxHeight: .infinity,
                    autofocus: true,
                    onSubmit: submit,
                    onEscape: { dismiss() },
                    onFiles: upload
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            HStack {
                Button { importing = true } label: {
                    Label(tr("ui", "attach_file"), systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(tr("ui", "attach_file"))
                Spacer()
                Button(action: submit) {
                    HStack(spacing: 6) {
                        Text(sending ? tr("modals", "feedback.sending")
                             : uploads.isUploading ? tr("editor", "upload.in_progress") : tr("modals", "feedback.send"))
                        KeyCaps("⌘", "↩")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 640, height: 448)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { upload(urls) }
        }
        .onChange(of: message) {
            UserDefaults.standard.set(message, forKey: Self.draftKey)
        }
    }

    private func upload(_ urls: [URL]) {
        uploads.upload(urls, session: session, insert: { markdown in
            message += (message.isEmpty || message.hasSuffix("\n") ? "" : "\n") + markdown
        }, onError: { toaster.error($0) })
    }

    private func submit() {
        guard !sending else { return }
        if uploads.isUploading {
            toaster.show(tr("modals", "feedback.toast_uploading"))
            return
        }
        let latest = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latest.isEmpty else { return }
        guard latest.count <= Self.maxLength else {
            toaster.error(tr("modals", "feedback.toast_too_long"))
            return
        }
        sending = true
        let url = nav.webURL(nav.route, appURL: env.app.config.appURL).absoluteString
        Task {
            defer { sending = false }
            do {
                _ = try await session.api.createFeedback(message: latest, url: url, workspaceId: session.workspace.id)
                UserDefaults.standard.removeObject(forKey: Self.draftKey)
                toaster.success(tr("modals", "feedback.toast_sent"))
                dismiss()
            } catch {
                let text = (error as? APIError)?.message ?? ""
                toaster.error(text.isEmpty ? tr("modals", "feedback.toast_failed") : text)
            }
        }
    }
}
