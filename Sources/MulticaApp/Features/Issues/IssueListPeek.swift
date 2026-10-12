import MulticaCore
import SwiftUI

/// Side peek over the surface (upstream issue-peek.tsx): the issue detail in
/// a floating panel, with previous/next stepping through the current view's
/// order. The header and toolbar stay usable while it is open.
struct IssueListPeekPanel: View {
    let model: IssueListSurfaceModel
    let issueID: String
    @Environment(Navigator.self) private var nav
    @State private var savedTitle: String?

    var body: some View {
        let position = model.peekPosition(issueID)
        let prev = model.step(.previous, from: issueID)
        let next = model.step(.next, from: issueID)
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { if let prev { open(prev) } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(prev == nil)
                    .help("\(tr("issues", "peek.previous")) (K)")
                Button { if let next { open(next) } } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(next == nil)
                    .help("\(tr("issues", "peek.next")) (J)")
                if let position {
                    Text("\(position.index) / \(position.total)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                        .padding(.leading, 4)
                }
                Spacer()
                Button {
                    let id = issueID
                    model.peekID = nil
                    nav.push(.issue(id))
                } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help(tr("issues", "peek.open_full_page"))
                Button { model.peekID = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("\(tr("issues", "peek.close")) (Esc)")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider()
            IssueDetailPage(issueID: issueID)
                .id(issueID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .accessibilityLabel(tr("issues", "peek.panel_label"))
        .onAppear { savedTitle = nav.tabs.activeTab?.title }
        .onDisappear { if let savedTitle { nav.setTitle(savedTitle) } }
    }

    private func open(_ id: String) {
        model.peekID = id
        model.focusedID = id
    }
}
