import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Browser-style tab strip (apps/desktop/.../tab-bar.tsx): back/forward,
/// pinned tabs as icons, closable tabs, drag to reorder, "+" for a new tab.
struct TabBar: View {
    @Environment(Navigator.self) private var nav
    @Environment(WorkspaceSession.self) private var session
    @State private var dragging: String?

    var body: some View {
        let store = nav.tabs
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                Button { nav.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!nav.canGoBack)
                    .help("Back (⌘[)")
                Button { nav.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!nav.canGoForward)
                    .help("Forward (⌘])")
            }
            .buttonStyle(.borderless)
            .padding(.trailing, 4)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabItem(tab: tab, active: tab.id == store.activeTab?.id)
                                .id(tab.id)
                                .onDrag {
                                    dragging = tab.id
                                    return NSItemProvider(object: tab.id as NSString)
                                }
                                .onDrop(of: [.text], delegate: TabDropDelegate(target: index, store: store, dragging: $dragging))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: store.activeTab?.id) {
                    if let id = store.activeTab?.id { withAnimation { proxy.scrollTo(id) } }
                }
            }

            Button { store.addTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New tab (⌘T)")
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(Theme.sidebar.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: Int
    let store: TabStore
    @Binding var dragging: String?

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, let from = store.tabs.firstIndex(where: { $0.id == dragging }), from != target else { return }
        withAnimation(.snappy) { store.moveTab(from: from, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

private struct TabItem: View {
    @Environment(Navigator.self) private var nav
    @Environment(WorkspaceSession.self) private var session
    let tab: TabSession
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let store = nav.tabs
        HStack(spacing: 6) {
            icon.frame(width: 14, height: 14)
            if !tab.pinned {
                Text(tab.title)
                    .font(Theme.Font.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering || active ? 1 : 0)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, tab.pinned ? 8 : 10)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .fill(active ? Color(nsColor: .controlBackgroundColor) : (hovering ? Theme.hover : .clear))
                .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.setActiveTab(tab.id) }
        .onHover { hovering = $0 }
        .help(tab.title)
        .contextMenu {
            Button(tab.pinned ? "Unpin tab" : "Pin tab") { store.togglePin(tab.id) }
            Button("Duplicate tab") { store.addTab(tab.location, title: tab.title) }
            Divider()
            Button("Close tab") { store.closeTab(tab.id) }.disabled(tab.pinned)
            Button("Close other tabs") { store.closeOtherTabs(tab.id) }
        }
    }

    @ViewBuilder private var icon: some View {
        switch tab.route {
        case .issue(let id):
            if let model = session.issues.model(id) {
                session.issues.catalog.icon(for: model.issue.status)
            } else {
                Image(systemName: tab.route.iconName.systemImage).font(.system(size: 11))
            }
        case .project(let id):
            ProjectIconView(icon: session.projects.item(id)?.icon, size: 13)
        case .agent(let id):
            ActorAvatar(type: "agent", id: id, size: 14)
        case .member(let id):
            ActorAvatar(type: "member", id: id, size: 14)
        case .squad(let id):
            ActorAvatar(type: "squad", id: id, size: 14)
        default:
            Image(systemName: tab.route.iconName.systemImage).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
