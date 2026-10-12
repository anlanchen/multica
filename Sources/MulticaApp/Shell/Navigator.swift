import AppKit
import MulticaCore
import Observation
import SwiftUI

/// In-window navigation for the active workspace, backed by `TabStore`.
/// Every page reaches it through `@Environment(Navigator.self)`.
@MainActor
@Observable
final class Navigator {
    let tabs: TabStore
    private(set) var slug: String

    init(tabs: TabStore, slug: String) {
        self.tabs = tabs
        self.slug = slug
    }

    func setWorkspace(_ slug: String) {
        self.slug = slug
        tabs.switchWorkspace(slug)
    }

    var location: TabLocation { tabs.activeLocation ?? TabStore.defaultLocation }
    var route: AppRoute { location.route }

    func query(_ key: String) -> String? { location.query[key] }

    /// Navigates the current tab; ⌘-click (or a pinned tab) opens a new tab
    /// instead, like the upstream AppLink.
    func push(_ route: AppRoute, query: [String: String] = [:], title: String? = nil) {
        let loc = TabLocation(route, query: query)
        if NSEvent.modifierFlags.contains(.command) {
            tabs.openTab(loc, title: title, activate: false)
            return
        }
        tabs.navigate(loc, title: title)
    }

    func replace(_ route: AppRoute, query: [String: String] = [:], title: String? = nil) {
        tabs.navigate(TabLocation(route, query: query), replace: true, title: title)
    }

    func openInNewTab(_ route: AppRoute, query: [String: String] = [:], title: String? = nil, activate: Bool = true) {
        tabs.openTab(TabLocation(route, query: query), title: title, activate: activate)
    }

    func setQuery(_ key: String, _ value: String?) {
        tabs.setQuery(key, value)
    }

    func back() { tabs.goBack() }
    func forward() { tabs.goForward() }
    var canGoBack: Bool { tabs.activeTab?.canGoBack ?? false }
    var canGoForward: Bool { tabs.activeTab?.canGoForward ?? false }

    /// Sets the active tab's title (pages call this with the entity name).
    func setTitle(_ title: String) {
        guard let id = tabs.activeTab?.id else { return }
        tabs.setTitle(title, for: id)
    }

    func viewState(_ key: String) -> String? { tabs.viewState(key) }
    func setViewState(_ key: String, _ value: String?) { tabs.setViewState(key, value) }

    /// Absolute web URL for sharing ("Copy link").
    func webURL(_ route: AppRoute, appURL: URL) -> URL {
        URL(string: appURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + route.path(workspaceSlug: slug)) ?? appURL
    }
}

extension View {
    /// Reports the page's display title to its tab.
    func tabTitle(_ title: String?) -> some View {
        modifier(TabTitleModifier(title: title))
    }
}

private struct TabTitleModifier: ViewModifier {
    @Environment(Navigator.self) private var nav
    let title: String?

    func body(content: Content) -> some View {
        content
            .onAppear { if let title { nav.setTitle(title) } }
            .onChange(of: title) { if let title { nav.setTitle(title) } }
    }
}

/// Window-level UI state that is not navigation.
@MainActor
@Observable
final class ShellState {
    var searchOpen = false
    var chatOpen = false
    var rightPanelOpen = true
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Bumped to ask the current page to focus its find bar (⌘F).
    var findRequest = 0

    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }
}

/// Transient bottom-right notifications (upstream sonner toasts).
@MainActor
@Observable
final class Toaster {
    enum Kind { case info, success, error }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        var message: String
        var actionTitle: String?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    private(set) var toasts: [Toast] = []
    @ObservationIgnored private var actions: [UUID: () -> Void] = [:]

    func show(_ message: String, kind: Kind = .info, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        let t = Toast(kind: kind, message: message, actionTitle: actionTitle)
        toasts.append(t)
        if let action { actions[t.id] = action }
        if toasts.count > 4 { dismiss(toasts[0].id) }
        let id = t.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 4))
            self.dismiss(id)
        }
    }

    func success(_ message: String) { show(message, kind: .success) }

    func error(_ error: Error) {
        show((error as? APIError)?.message ?? error.localizedDescription, kind: .error)
    }

    func error(_ message: String) { show(message, kind: .error) }

    func runAction(_ id: UUID) {
        actions[id]?()
        dismiss(id)
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        actions[id] = nil
    }
}

struct ToastOverlay: View {
    @Environment(Toaster.self) private var toaster

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(toaster.toasts) { t in
                HStack(spacing: 8) {
                    Image(systemName: icon(t.kind)).foregroundStyle(color(t.kind))
                    Text(t.message).font(Theme.Font.body).lineLimit(3)
                    if let title = t.actionTitle {
                        Button(title) { toaster.runAction(t.id) }.buttonStyle(.link)
                    }
                    Button { toaster.dismiss(t.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 380, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.snappy, value: toaster.toasts)
    }

    private func icon(_ k: Toaster.Kind) -> String {
        switch k {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    private func color(_ k: Toaster.Kind) -> Color {
        switch k {
        case .info: return Theme.info
        case .success: return Theme.success
        case .error: return Theme.destructive
        }
    }
}
