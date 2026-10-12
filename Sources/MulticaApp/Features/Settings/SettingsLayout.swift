import MulticaCore
import Observation
import SwiftUI

/// Where a setting takes effect (upstream SettingsScope): the account, this
/// device, or the workspace.
enum SettingsScope {
    case account, device, deviceWorkspace, workspace, workspaceOnly
}

enum SettingsSaveStatus { case idle, saving, saved, error }

/// Control column width tiers (upstream SETTINGS_CONTROL_WIDTHS).
enum SettingsControlSize {
    case text, selectWide, select, code, none

    var width: CGFloat? {
        switch self {
        case .text: return 384
        case .selectWide: return 288
        case .select: return 192
        case .code: return 160
        case .none: return nil
        }
    }
}

extension Theme {
    static let settingsCard = Color(nsColor: .controlBackgroundColor)
}

private struct SettingsFlashAnchorKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The in-page anchor a search result or `?section=` link just landed on.
    var settingsFlashAnchor: String? {
        get { self[SettingsFlashAnchorKey.self] }
        set { self[SettingsFlashAnchorKey.self] = newValue }
    }
}

enum SettingsAnchor {
    static func id(_ anchor: String) -> String { "settings-anchor-\(anchor)" }
}

private struct SettingsAnchorModifier: ViewModifier {
    @Environment(\.settingsFlashAnchor) private var flash
    let anchor: String?
    let flashes: Bool

    func body(content: Content) -> some View {
        if let anchor {
            content
                .background(flashes && flash == anchor ? Theme.selected : .clear)
                .animation(.easeOut(duration: 0.7), value: flash == anchor)
                .id(SettingsAnchor.id(anchor))
        } else {
            content
        }
    }
}

extension View {
    func settingsAnchor(_ anchor: String?, flashes: Bool = true) -> some View {
        modifier(SettingsAnchorModifier(anchor: anchor, flashes: flashes))
    }
}

// MARK: - Page chrome

struct SettingsScopeBadge: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(WorkspaceSession.self) private var session
    let scope: SettingsScope

    var body: some View {
        let ws = env.settingsWorkspace(session)
        HStack(spacing: 4) {
            switch scope {
            case .account: Image(systemName: "person")
            case .device, .deviceWorkspace: Image(systemName: "laptopcomputer")
            case .workspace, .workspaceOnly:
                if ws.avatarURL?.isEmpty == false {
                    WorkspaceAvatar(name: ws.name, url: ws.avatarURL, size: 12)
                } else {
                    Image(systemName: "building.2")
                }
            }
            Text(label(ws.name)).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private func label(_ name: String) -> String {
        switch scope {
        case .account: return tr("settings", "layout.scope.account")
        case .device: return tr("settings", "layout.scope.device")
        case .deviceWorkspace: return tr("settings", "layout.scope.device_workspace", ["name": name])
        case .workspace: return tr("settings", "layout.scope.workspace", ["name": name])
        case .workspaceOnly: return tr("settings", "layout.scope.workspace_only", ["name": name])
        }
    }
}

/// One settings page: title, scope, description, page action, sections.
struct SettingsTabView<Actions: View, Content: View>: View {
    let title: String
    var description: String? = nil
    var scope: SettingsScope? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(title).font(.system(size: 20, weight: .semibold))
                        if let scope { SettingsScopeBadge(scope: scope) }
                    }
                    if let description {
                        Text(description)
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .frame(maxWidth: 672, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                actions()
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsTabView where Actions == EmptyView {
    init(title: String, description: String? = nil, scope: SettingsScope? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, description: description, scope: scope, actions: { EmptyView() }, content: content)
    }
}

struct SettingsSectionView<Action: View, Content: View>: View {
    var title: String? = nil
    var description: String? = nil
    var scope: SettingsScope? = nil
    var anchor: String? = nil
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || description != nil || Action.self != EmptyView.self {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let title {
                            HStack(spacing: 8) {
                                Text(title).font(.system(size: 13, weight: .semibold))
                                if let scope { SettingsScopeBadge(scope: scope) }
                            }
                        }
                        if let description {
                            Text(description).font(Theme.Font.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    action()
                }
                .padding(.horizontal, 2)
            }
            content()
        }
        .settingsAnchor(anchor, flashes: false)
    }
}

extension SettingsSectionView where Action == EmptyView {
    init(title: String? = nil, description: String? = nil, scope: SettingsScope? = nil, anchor: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, description: description, scope: scope, anchor: anchor, action: { EmptyView() }, content: content)
    }
}

/// Bordered card whose rows are separated by hairlines (upstream SettingsCard).
struct SettingsCardView<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(SettingsDividedRows()) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.settingsCard))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}

private struct SettingsDividedRows: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last { Divider() }
            }
        }
    }
}

/// Label + description on the left, control on the right (upstream SettingsRow).
struct SettingsRowView<Description: View, Control: View>: View {
    let label: String
    var labelColor: Color = .primary
    var size: SettingsControlSize? = nil
    var align: VerticalAlignment = .center
    var anchor: String? = nil
    @ViewBuilder var description: () -> Description
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: align, spacing: 32) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Font.bodyMedium).foregroundStyle(labelColor)
                description()
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let width = size?.width {
                control().frame(minWidth: min(160, width), maxWidth: width, alignment: .trailing)
            } else {
                control().fixedSize(horizontal: size == nil, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 64)
        .settingsAnchor(anchor)
    }
}

extension SettingsRowView where Description == Text? {
    init(_ label: String, description: String? = nil, labelColor: Color = .primary, size: SettingsControlSize? = nil,
         align: VerticalAlignment = .center, anchor: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.init(label: label, labelColor: labelColor, size: size, align: align, anchor: anchor,
                  description: { description.map { Text($0) } }, control: control)
    }
}

/// Segmented switch between the lists one page manages (upstream SettingsViewTabs).
struct SettingsViewTabs<Value: Hashable>: View {
    let items: [(value: Value, label: String, count: Int?)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 6) {
                        Text(item.label).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                        if let count = item.count {
                            Text("\(count)").font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .fill(selected ? Theme.settingsCard : .clear)
                            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }
}

/// The read-only explanation on workspace pages a member can see but not
/// change, naming who can (upstream SettingsReadOnlyNotice).
struct SettingsReadOnlyNotice: View {
    @Environment(WorkspaceSession.self) private var session

    var body: some View {
        let managers = session.directory.members
            .filter { $0.role == "owner" || $0.role == "admin" }
            .map(\.name).filter { !$0.isEmpty }.prefix(3)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye").foregroundStyle(.secondary).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("settings", "layout.read_only.title")).font(Theme.Font.bodyMedium)
                Text(managers.isEmpty
                     ? tr("settings", "layout.read_only.description")
                     : tr("settings", "layout.read_only.contact", ["names": managers.joined(separator: tr("settings", "layout.read_only.separator"))]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

struct SettingsSaveStateView: View {
    let status: SettingsSaveStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("settings", "auto_save.saving"))
            }
            .font(Theme.Font.caption).foregroundStyle(.secondary)
        case .saved:
            Label(tr("settings", "auto_save.saved"), systemImage: "checkmark")
                .font(Theme.Font.caption).foregroundStyle(.secondary)
        case .error:
            Label(tr("settings", "auto_save.failed"), systemImage: "exclamationmark.circle")
                .font(Theme.Font.caption).foregroundStyle(Theme.destructive)
        }
    }
}

struct SettingsEmptyList: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// Bordered table used by the catalog pages (labels, properties, quick
/// actions): a muted column header over hairline-separated rows.
struct SettingsCatalogCard<Header: View, Content: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header()
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
            Divider()
            content()
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.settingsCard))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
    }
}

/// Centered placeholder inside a catalog card (loading / empty / no results).
struct SettingsCatalogPlaceholder: View {
    var icon: String? = nil
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(.tertiary).padding(.bottom, 4)
            }
            Text(title).font(icon == nil ? Theme.Font.body : Theme.Font.bodyMedium)
                .foregroundStyle(icon == nil ? .secondary : .primary)
            if let hint {
                Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 48)
    }
}

// MARK: - Dialogs

/// Sheet chrome for settings dialogs: title, description, body, footer.
struct SettingsDialog<Content: View, Footer: View>: View {
    let title: String
    var description: String? = nil
    var width: CGFloat = 448
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.Font.title)
                if let description {
                    Text(description).font(Theme.Font.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                footer()
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

struct SettingsFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium))
    }
}

/// Multi-line text input with the rounded field look.
struct SettingsTextArea: View {
    @Binding var text: String
    var placeholder: String = ""
    var minHeight: CGFloat = 64
    var disabled = false
    var invalid = false

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(Theme.Font.body)
            .lineLimit(3...)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.settingsCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(invalid ? Theme.destructive : Color.primary.opacity(0.15)))
            .disabled(disabled)
            .opacity(disabled ? 0.6 : 1)
    }
}

// MARK: - Auto-save

/// Debounced, serialized saving for text-heavy settings (upstream
/// use-auto-save.ts): an edit during an in-flight save queues only the
/// latest value, so a slow response never overwrites a newer one.
@MainActor
@Observable
final class SettingsAutoSave<Value: Equatable> {
    private(set) var status: SettingsSaveStatus = .idle
    @ObservationIgnored private var persisted: Value
    @ObservationIgnored private var observedSaved: Value
    @ObservationIgnored private var latest: Value
    @ObservationIgnored private var queued: Value?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let save: (Value) async throws -> Void
    @ObservationIgnored private let onError: (Error) -> Void

    init(initial: Value, save: @escaping (Value) async throws -> Void, onError: @escaping (Error) -> Void) {
        persisted = initial
        observedSaved = initial
        latest = initial
        self.save = save
        self.onError = onError
    }

    /// The server's current value (after a load, a save or a realtime refresh).
    func setSaved(_ saved: Value) {
        guard saved != observedSaved else { return }
        observedSaved = saved
        persisted = saved
    }

    /// Feed every draft edit (and permission change); saves after a pause.
    func update(value: Value, enabled: Bool) {
        self.enabled = enabled
        latest = value
        timer?.cancel()
        timer = nil
        guard enabled, value != persisted else {
            if !enabled || (status == .saving && !saving) { status = .idle }
            return
        }
        status = .saving
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            await self.run(self.latest)
        }
    }

    /// Saves now (field blur).
    func flush() {
        timer?.cancel()
        timer = nil
        let value = latest
        Task { await run(value) }
    }

    private func run(_ next: Value) async {
        guard enabled, next != persisted else { return }
        if saving {
            queued = next
            return
        }
        saving = true
        status = .saving
        var succeeded = false
        do {
            try await save(next)
            persisted = next
            succeeded = true
        } catch {
            status = .error
            onError(error)
        }
        saving = false
        if let q = queued {
            queued = nil
            if q != persisted {
                await run(q)
                return
            }
        }
        if succeeded { status = .saved }
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
