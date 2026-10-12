import AppKit
import MulticaCore
import SwiftUI

/// Context handed from one create panel to the other on a mode switch: the
/// parent intent is per-invocation, so it rides along instead of the draft.
struct IssueModalCarry: Equatable {
    var parentIssueID: String?
    var parentIdentifier: String?
}

/// Shell owning the create-issue sheet for both modes (upstream
/// CreateIssueDialog): switching swaps only the inner panel; the expand
/// state and the sheet survive.
struct IssueModalCreateDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let seed: CreateIssueDraft
    let initialMode: CreateIssueMode

    @State private var context = IssueModalPending.takeCreateContext()
    @State private var mode: CreateIssueMode?
    @State private var opener = CreateIssueDraft()
    @State private var carry = IssueModalCarry()
    @State private var stageSeed: Int?
    @State private var expanded = false
    @State private var store: IssueModalDraftStore?
    @State private var source: IssueModalSourceContext?
    @State private var limitShown = false

    var body: some View {
        let current = mode ?? initialMode
        Group {
            if let store {
                switch current {
                case .manual:
                    IssueModalManualPanel(store: store, opener: opener, carry: carry, stageSeed: stageSeed, source: source,
                                          expanded: $expanded, onClose: close, onSwitchMode: { switchTo(.agent, $0) },
                                          onLimitReached: { limitShown = true })
                case .agent:
                    IssueModalAgentPanel(store: store, opener: opener, context: context, carry: carry, source: source,
                                         expanded: $expanded, onClose: close, onSwitchMode: { switchTo(.manual, $0) },
                                         onLimitReached: { limitShown = true })
                }
            } else {
                Color.clear.frame(height: 384)
            }
        }
        .frame(width: width(current), height: height(current))
        .animation(.easeOut(duration: 0.25), value: expanded)
        .onAppear(perform: setUp)
        .onDisappear(perform: mirrorDraft)
        .sheet(isPresented: $limitShown) {
            IssueModalLimitUpgrade(onBillingAction: close)
        }
    }

    private var windowHeight: CGFloat { NSApp.mainWindow?.frame.height ?? 860 }

    private func width(_ m: CreateIssueMode) -> CGFloat {
        if expanded { return 896 }
        if m == .agent { return source?.expanded == true ? 672 : 576 }
        return 672
    }

    private func height(_ m: CreateIssueMode) -> CGFloat? {
        if expanded || source?.expanded == true { return (windowHeight * 5 / 6).rounded() }
        if m == .agent && source == nil { return nil }
        return 384
    }

    private func setUp() {
        guard store == nil else { return }
        let shared = IssueModalDraftStore.shared(workspaceID: session.workspace.id)
        if let anchor = context?.anchorCommentID {
            store = IssueModalDraftStore(isolatedFrom: shared)
            let s = IssueModalSourceContext(anchorCommentID: anchor)
            source = s
            Task { await s.load(session.api) }
        } else {
            let mirror = IssueModalPending.lastMirror
            let fromMirror = mirror.map { $0.title == seed.title && $0.description == seed.description } ?? false
            if !fromMirror {
                if !seed.title.isEmpty && shared.draft.manual.title.isEmpty { shared.update { $0.manual.title = seed.title } }
                if !seed.description.isEmpty && shared.draft.manual.description.isEmpty { shared.update { $0.manual.description = seed.description } }
            }
            store = shared
        }
        var o = seed
        o.title = ""
        o.description = ""
        opener = o
        carry = IssueModalCarry(parentIssueID: seed.parentIssueID ?? context?.parentIssueID, parentIdentifier: context?.parentIssueIdentifier)
        stageSeed = context?.stage
    }

    private func switchTo(_ next: CreateIssueMode, _ newCarry: IssueModalCarry) {
        IssueModalPending.setLastMode(next)
        opener = CreateIssueDraft()
        carry = newCarry
        stageSeed = nil
        if context?.anchorCommentID == nil { context = nil } else {
            context?.agentID = nil
            context?.squadID = nil
            context?.prompt = nil
        }
        mode = next
    }

    private func close() {
        dismiss()
    }

    /// The sidebar's draft dot reads `AppEnvironment.issueDraft`.
    private func mirrorDraft() {
        guard let store, source == nil else { return }
        store.persistNow()
        let d = store.draft
        if d.hasContent {
            let m = CreateIssueDraft(title: d.manual.title, description: d.manual.description.isEmpty ? d.agent.prompt : d.manual.description)
            IssueModalPending.lastMirror = m
            env.issueDraft = m
        } else {
            IssueModalPending.lastMirror = nil
            env.issueDraft = nil
        }
    }
}

/// `workspace › Create manually` with expand and close.
struct IssueModalCreateHeader: View {
    @Environment(WorkspaceSession.self) private var session
    let breadcrumb: String
    @Binding var expanded: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(session.workspace.name).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            Text(breadcrumb).fontWeight(.medium).lineLimit(1)
            Spacer()
            IssueModalIconButton(systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 help: expanded ? tr("modals", "common.collapse_tooltip") : tr("modals", "common.expand_tooltip")) {
                expanded.toggle()
            }
            IssueModalIconButton(systemImage: "xmark", help: tr("modals", "common.close"), action: onClose)
        }
        .font(Theme.Font.caption)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

/// The manual title, kept as local state so typing re-renders only itself.
struct IssueModalTitleField: View {
    let store: IssueModalDraftStore
    var focused: FocusState<Bool>.Binding
    let onHasTitle: (Bool) -> Void
    @State private var text = ""

    var body: some View {
        TextField(tr("modals", "create_issue.title_placeholder"), text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1...4)
            .focused(focused)
            .onAppear {
                text = store.draft.manual.title
                onHasTitle(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                DispatchQueue.main.async { focused.wrappedValue = true }
            }
            .onChange(of: text) {
                let v = text.replacingOccurrences(of: "\n", with: " ")
                if v != text { text = v; return }
                store.update { $0.manual.title = v }
                onHasTitle(!v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
    }
}

/// The Markdown body of either panel (manual description / agent prompt),
/// local state synced into the draft.
struct IssueModalBodyEditor: View {
    @Environment(WorkspaceSession.self) private var session
    let store: IssueModalDraftStore
    let mode: CreateIssueMode
    let placeholder: String
    let target: IssueModalEditorTarget
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 320
    var autofocus = false
    var initialText: String? = nil
    var onContent: ((Bool) -> Void)? = nil
    let onSubmit: () -> Void
    let onFiles: ([URL]) -> Void
    @State private var text = ""

    var body: some View {
        MarkdownEditor(
            text: $text,
            placeholder: placeholder,
            minHeight: minHeight,
            maxHeight: maxHeight,
            autofocus: autofocus,
            onSubmit: onSubmit,
            onFiles: { urls in
                target.capture()
                onFiles(urls)
            },
            mentions: { session.mentionCandidates($0, includeIssues: true) }
        )
        .onAppear {
            let saved = mode == .agent ? store.draft.agent.prompt : store.draft.manual.description
            text = saved.isEmpty ? (initialText ?? "") : saved
            onContent?(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            target.fallback = { md in text = IssueModalAttachments.appendMarkdown(text, md) }
        }
        .onDisappear { target.fallback = nil }
        .onChange(of: text) {
            let v = text
            store.update { d in
                if mode == .agent { d.agent.prompt = v } else { d.manual.description = v }
            }
            onContent?(!v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// Paperclip that picks files from disk (upstream FileUploadButton).
struct IssueModalAttachButton: View {
    let onFiles: ([URL]) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: "paperclip").font(.system(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverHighlight()
        .help(tr("ui", "attach_file"))
        .accessibilityLabel(tr("ui", "attach_file"))
        .fileImporter(isPresented: $open, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { onFiles(urls) }
        }
    }
}

/// "Create another" switch (upstream keep-open toggle, per workspace).
struct IssueModalKeepOpenToggle: View {
    @Bindable var store: IssueModalDraftStore

    var body: some View {
        Toggle(isOn: $store.keepOpen) {
            Text(tr("modals", "create_issue.create_another")).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
    }
}

/// True while any file in the shared pool is still uploading.
@MainActor
enum IssueModalUploadGate {
    static func uploading(_ store: IssueModalDraftStore) -> Bool {
        store.draft.shared.attachments.contains { $0.status == .uploading }
    }
}

/// Closes the dialog for an in-place navigation; a ⌘-click opens the
/// destination in a new tab and leaves the dialog (and its draft) alone.
@MainActor
enum IssueModalNavigation {
    static func openFieldSettings(_ nav: Navigator, close: () -> Void) {
        let newTab = NSEvent.modifierFlags.contains(.command)
        nav.push(.settings, query: ["tab": "preferences", "section": "issue"])
        if !newTab { close() }
    }
}

/// Unified failure for writes the dialog refuses locally.
struct IssueModalLocalError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension WorkspaceSession {
    /// Source-context create against an older server answers 404/405.
    func issueModalSourceCode(_ error: Error) -> String? {
        if let s = IssueModalErrors.status(error), s == 404 || s == 405 { return "source_context_server_unsupported" }
        return IssueModalErrors.code(error)
    }
}
