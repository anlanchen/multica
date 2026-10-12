import AppKit
import MulticaCore
import SwiftUI

/// Top bar of a page: icon + title (+ breadcrumb) on the left, actions on the
/// right. Mirrors upstream PageHeader (h-12, bottom border).
struct PageHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: @escaping () -> Leading) {
        self.leading = leading
        self.trailing = { EmptyView() }
    }
}

/// Title block for the sidebar's list pages: route icon + localized nav title.
struct PageTitle: View {
    let page: WorkspacePage
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: page.icon.systemImage).foregroundStyle(.secondary)
            Text(page.title).font(Theme.Font.bodyMedium)
            if let count {
                Text("\(count)").font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Breadcrumb: parent link › current title.
struct Breadcrumb: View {
    @Environment(Navigator.self) private var nav
    let parent: String
    let parentRoute: AppRoute
    let title: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Button(parent) { nav.push(parentRoute) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            Text(title).font(Theme.Font.bodyMedium).lineLimit(1)
        }
        .font(Theme.Font.body)
    }
}

/// Centered empty state (icon, title, description, optional action).
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(Theme.Font.title)
            if let message {
                Text(message)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions().padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = { EmptyView() }
    }
}

struct LoadingView: View {
    var body: some View {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline error with retry.
struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(Theme.warning)
            Text(message).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry {
                Button(tr("issues", "status_catalog_error.retry"), action: retry)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keyboard shortcut caps (upstream ShortcutKeycaps).
struct KeyCaps: View {
    let keys: [String]

    init(_ keys: String...) { self.keys = keys }
    init(keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Small rounded "pill" button used for property chips and filters.
struct PillButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.caption)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(active ? Theme.brand.opacity(0.12) : (configuration.isPressed ? Theme.selected : Color.primary.opacity(0.04)))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

/// Borderless row-like button with hover highlight.
struct HoverRowButtonStyle: ButtonStyle {
    var selected = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(selected ? Theme.selected : (hovering || configuration.isPressed ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Two-to-four option segmented control (upstream SegmentedToggle).
struct SegmentedToggle<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String, icon: String?)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.value) { o in
                if let icon = o.icon {
                    Label(o.label, systemImage: icon).tag(o.value)
                } else {
                    Text(o.label).tag(o.value)
                }
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Property row in a detail sidebar: fixed-width label, value on the right.
struct PropRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 28)
    }
}

/// Search box with magnifier and clear button.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        .onAppear { if autofocus { focused = true } }
    }
}

/// Grouped card used on settings and detail pages.
struct SectionCard<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.title)
                    if let subtitle {
                        Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.025)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        }
    }
}

/// A colored dot with optional label (presence, connection, availability).
struct StatusDot: View {
    let color: Color
    var label: String? = nil
    var size: CGFloat = 7

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: size, height: size)
            if let label { Text(label).font(Theme.Font.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Capsule badge (counts, tags, roles).
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
            .lineLimit(1)
    }
}

/// Issue label chip with its color dot.
struct LabelChip: View {
    let name: String
    let color: String

    init(label: IssueLabel) {
        name = label.name
        color = label.color
    }

    init(name: String, color: String) {
        self.name = name
        self.color = color
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Capsule().strokeBorder(Theme.border))
    }
}

/// Copies text and briefly shows a check.
struct CopyButton: View {
    let text: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            if let label {
                Label(label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help("Copy")
    }
}

/// Monospaced command line with a copy button (CLI install commands, tokens).
struct CodeLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: text).buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05)))
    }
}

/// Relative timestamp that refreshes itself once a minute.
struct RelativeTime: View {
    let timestamp: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(Formatters.relative(timestamp))
        }
        .help(Formatters.date(timestamp, style: .complete, time: .shortened))
    }
}

/// Horizontal progress bar.
struct ProgressBar: View {
    let value: Double
    var color: Color = Theme.brand

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// Circular progress (project completion, upstream ProgressRing).
struct ProgressRing: View {
    let value: Double
    var size: CGFloat = 14
    var color: Color = Theme.brand

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

extension View {
    /// Rounded hover background for custom rows.
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.medium) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    /// Standard page body padding with a readable maximum width.
    func pageContent(maxWidth: CGFloat = 960) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(hovering ? Theme.hover : .clear))
            .onHover { hovering = $0 }
    }
}
