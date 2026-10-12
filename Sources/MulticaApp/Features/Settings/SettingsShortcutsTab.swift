import AppKit
import MulticaCore
import SwiftUI

/// Settings › Shortcuts (upstream keyboard-shortcuts-tab.tsx): record, reset
/// or disable each action's chord; saved on this device.
struct SettingsShortcutsTab: View {
    @Environment(ShortcutStore.self) private var shortcuts
    @State private var query = ""
    @State private var visible = ShortcutAction.allCases
    @State private var recorder = SettingsShortcutRecorder()
    @State private var resetConfirm = false

    var body: some View {
        SettingsTabView(title: tr("settings", "shortcuts.title"), description: tr("settings", "shortcuts.description"), scope: .device) {
            HStack(spacing: 12) {
                SearchField(text: $query, prompt: tr("settings", "shortcuts.search_placeholder"))
                    .frame(maxWidth: 384)
                Spacer(minLength: 0)
                Button { resetConfirm = true } label: {
                    Label(tr("settings", "shortcuts.reset_all"), systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(shortcuts.overrides.isEmpty)
            }

            ForEach(["general", "navigation"], id: \.self) { category in
                let actions = visible.filter { ($0.isNavigation ? "navigation" : "general") == category }
                if !actions.isEmpty {
                    SettingsSectionView(title: tr("settings", "shortcuts.categories.\(category)")) {
                        SettingsCardView {
                            ForEach(actions) { action in
                                SettingsShortcutRow(action: action, recorder: recorder)
                            }
                        }
                    }
                }
            }

            if visible.isEmpty {
                SettingsEmptyList(text: tr("settings", "shortcuts.no_results"))
            }

            SettingsSectionView(title: tr("settings", "shortcuts.fixed.title"), description: tr("settings", "shortcuts.fixed.description")) {
                SettingsCardView {
                    fixedRow("shortcuts.fixed.open_settings", ["⌘", ","])
                    fixedRow("shortcuts.fixed.close_tab", ["⌘", "W"])
                    fixedRow("shortcuts.fixed.select_tab_1_to_8", ["⌘", "1–8"])
                    fixedRow("shortcuts.fixed.close_dialog", ["Esc"])
                }
            }
        }
        .onChange(of: query) {
            let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
            visible = needle.isEmpty ? ShortcutAction.allCases : ShortcutAction.allCases.filter {
                "\(tr("settings", "shortcuts.actions.\($0.rawValue).label")) \(tr("settings", "shortcuts.actions.\($0.rawValue).description"))"
                    .lowercased().contains(needle)
            }
        }
        .onAppear { recorder.store = shortcuts }
        .onDisappear { recorder.stop() }
        .alert(tr("settings", "shortcuts.reset_confirm.title"), isPresented: $resetConfirm) {
            Button(tr("settings", "shortcuts.reset_confirm.cancel"), role: .cancel) {}
            Button(tr("settings", "shortcuts.reset_confirm.confirm"), role: .destructive) {
                shortcuts.resetAll()
                recorder.stop()
            }
        } message: {
            Text(tr("settings", "shortcuts.reset_confirm.description"))
        }
    }

    private func fixedRow(_ key: String, _ keys: [String]) -> some View {
        SettingsRowView(tr("settings", key)) {
            KeyCaps(keys: keys)
        }
    }
}

private struct SettingsShortcutRow: View {
    @Environment(ShortcutStore.self) private var shortcuts
    let action: ShortcutAction
    let recorder: SettingsShortcutRecorder

    var body: some View {
        let label = tr("settings", "shortcuts.actions.\(action.rawValue).label")
        let chord = shortcuts.chord(for: action)
        let customized = shortcuts.overrides.keys.contains(action)
        let recording = recorder.action == action
        let error = recording ? recorder.error : nil
        let showsDescription = [.openSearch, .toggleRightSidebar, .archiveInboxItem, .send].contains(action)
        SettingsRowView(label: label, size: .selectWide, align: .top, description: {
            VStack(alignment: .leading, spacing: 4) {
                if showsDescription { Text(tr("settings", "shortcuts.actions.\(action.rawValue).description")) }
                if action == .send && chord == .plain("Enter") {
                    Text(tr("settings", "shortcuts.send_enter_hint")).foregroundStyle(Theme.brand)
                }
            }
        }) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button { recording ? recorder.stop() : recorder.start(action) } label: {
                        Group {
                            if recording {
                                Label(tr("settings", "shortcuts.recording"), systemImage: "keyboard")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.brand)
                            } else if let chord {
                                KeyCaps(keys: chord.display)
                            } else {
                                Text(tr("settings", "shortcuts.unassigned")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minWidth: 112, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .fill(recording ? Theme.brand.opacity(0.06) : Theme.settingsCard))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .strokeBorder(error != nil ? Theme.destructive : recording ? Theme.brand : Color.primary.opacity(0.15),
                                          lineWidth: recording ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("settings", "shortcuts.record_aria", ["action": label]))
                    Button { shortcuts.reset(action); recorder.clearError() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .disabled(!customized)
                        .help(tr("settings", "shortcuts.reset"))
                        .accessibilityLabel(tr("settings", "shortcuts.reset_action", ["action": label]))
                    Button { shortcuts.set(nil, for: action); recorder.clearError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .disabled(chord == nil)
                        .help(tr("settings", "shortcuts.disable"))
                        .accessibilityLabel(tr("settings", "shortcuts.disable_action", ["action": label]))
                }
                if let error {
                    Text(message(error)).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 288, alignment: .trailing)
                } else if recording {
                    Text(tr("settings", "shortcuts.record_hint")).font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func message(_ error: SettingsShortcutRecorder.CaptureError) -> String {
        switch error {
        case .reserved: return tr("settings", "shortcuts.reserved_error")
        case .send: return tr("settings", "shortcuts.send_error")
        case .unsafe: return tr("settings", "shortcuts.unsafe_error")
        case .conflict(let other): return tr("settings", "shortcuts.conflict_error", ["action": tr("settings", "shortcuts.actions.\(other.rawValue).label")])
        }
    }
}

/// Owns the keyboard while a shortcut is being recorded: global shortcuts
/// are suspended and the next chord is validated and stored.
@MainActor
@Observable
final class SettingsShortcutRecorder {
    enum CaptureError: Equatable {
        case reserved, send, unsafe
        case conflict(ShortcutAction)
    }

    private(set) var action: ShortcutAction?
    private(set) var error: CaptureError?
    @ObservationIgnored weak var store: ShortcutStore?
    @ObservationIgnored private var monitor: Any?

    func start(_ action: ShortcutAction) {
        stop()
        self.action = action
        KeyMonitor.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.action != nil else { return event }
            if !event.isARepeat { self.capture(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if action != nil { KeyMonitor.suspended = false }
        action = nil
        error = nil
    }

    func clearError() { error = nil }

    private func capture(_ event: NSEvent) {
        guard let action, let store else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let bare = flags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 53 && bare {
            stop()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            store.set(nil, for: action)
            stop()
            return
        }
        guard let chord = ShortcutChord(event: event) else { return }
        let policy = SettingsShortcutPolicy.Chord(key: chord.key, primary: chord.primary, control: chord.control, alt: chord.alt, shift: chord.shift)
        if SettingsShortcutPolicy.isReserved(policy) {
            error = .reserved
            return
        }
        if !SettingsShortcutPolicy.isAllowed(policy, isSend: action == .send, allowInEditable: action.allowInEditable) {
            error = action == .send ? .send : .unsafe
            return
        }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && store.chord(for: $0) == chord }) {
            error = .conflict(other)
            return
        }
        store.set(chord, for: action)
        stop()
    }
}
