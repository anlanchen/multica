import AppKit
import MulticaCore
import Observation
import SwiftUI

/// A key plus modifiers, in the upstream shortcut model
/// (packages/core/shortcuts/definitions.ts): `primary` is ⌘ on macOS.
struct ShortcutChord: Codable, Hashable {
    var key: String
    var primary = false
    var control = false
    var alt = false
    var shift = false

    static func plain(_ key: String) -> ShortcutChord { ShortcutChord(key: key) }
    static func cmd(_ key: String) -> ShortcutChord { ShortcutChord(key: key, primary: true) }

    /// Display form, e.g. "⌘K", "C", "⌘↩".
    var display: [String] {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if alt { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if primary { parts.append("⌘") }
        let labels = ["Enter": "↩", "Escape": "Esc", "Up": "↑", "Down": "↓", "Left": "←", "Right": "→", "Space": "Space", "Backspace": "⌫"]
        parts.append(labels[key] ?? key)
        return parts
    }

    init(key: String, primary: Bool = false, control: Bool = false, alt: Bool = false, shift: Bool = false) {
        self.key = key
        self.primary = primary
        self.control = control
        self.alt = alt
        self.shift = shift
    }

    /// Chord for a key-down event, or nil for modifier-only presses.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let special: [UInt16: String] = [36: "Enter", 76: "Enter", 53: "Escape", 126: "Up", 125: "Down", 123: "Left", 124: "Right", 49: "Space", 51: "Backspace", 48: "Tab"]
        var key: String
        if let s = special[event.keyCode] {
            key = s
        } else {
            guard let chars = event.charactersIgnoringModifiers, let c = chars.first else { return nil }
            key = String(c).uppercased()
        }
        if key == "{" { key = "[" }
        if key == "}" { key = "]" }
        self.init(key: key, primary: flags.contains(.command), control: flags.contains(.control), alt: flags.contains(.option), shift: flags.contains(.shift))
    }
}

/// Upstream ShortcutActionId, with the same defaults.
enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case openSearch, createIssue, toggleSidebar, toggleRightSidebar, toggleChat, findInIssue
    case archiveInboxItem, send, goBack, goForward
    case goInbox, goChat, goMyIssues, goIssues, goProjects, goAutopilots, goAgents, goSquads
    case goUsage, goRuntimes, goSkills, goSettings

    var id: String { rawValue }

    var isNavigation: Bool { rawValue.hasPrefix("go") }

    var defaultChord: ShortcutChord? {
        switch self {
        case .openSearch: return .cmd("K")
        case .createIssue: return .plain("C")
        case .toggleSidebar: return .cmd("B")
        case .toggleRightSidebar: return .cmd("/")
        case .toggleChat: return .cmd("J")
        case .findInIssue: return .cmd("F")
        case .archiveInboxItem: return .plain("E")
        case .send: return .cmd("Enter")
        case .goBack: return .cmd("[")
        case .goForward: return .cmd("]")
        default: return nil
        }
    }

    var allowInEditable: Bool {
        switch self {
        case .openSearch, .toggleChat, .findInIssue, .send: return true
        default: return false
        }
    }

    var page: WorkspacePage? {
        switch self {
        case .goInbox: return .inbox
        case .goChat: return .chat
        case .goMyIssues: return .myIssues
        case .goIssues: return .issues
        case .goProjects: return .projects
        case .goAutopilots: return .autopilots
        case .goAgents: return .agents
        case .goSquads: return .squads
        case .goUsage: return .usage
        case .goRuntimes: return .runtimes
        case .goSkills: return .skills
        case .goSettings: return .settings
        default: return nil
        }
    }
}

/// User shortcut overrides (Settings › Shortcuts), persisted locally.
@MainActor
@Observable
final class ShortcutStore {
    static let defaultsKey = "multica.shortcuts.v1"
    /// nil value = explicitly disabled.
    private(set) var overrides: [ShortcutAction: ShortcutChord?] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ShortcutChord?].self, from: data) {
            for (k, v) in decoded { if let a = ShortcutAction(rawValue: k) { overrides[a] = v } }
        }
    }

    func chord(for action: ShortcutAction) -> ShortcutChord? {
        if let o = overrides[action] { return o }
        return action.defaultChord
    }

    func set(_ chord: ShortcutChord?, for action: ShortcutAction) {
        overrides[action] = .some(chord)
        save()
    }

    func reset(_ action: ShortcutAction) {
        overrides[action] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    /// The action already bound to `chord`, for conflict warnings.
    func action(for chord: ShortcutChord) -> ShortcutAction? {
        ShortcutAction.allCases.first { self.chord(for: $0) == chord }
    }

    private func save() {
        var raw: [String: ShortcutChord?] = [:]
        for (k, v) in overrides { raw[k.rawValue] = v }
        if let data = try? JSONEncoder().encode(raw) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}

extension Notification.Name {
    /// Inbox page archives its selected item (shortcut E).
    static let multicaArchiveInboxItem = Notification.Name("multica.archiveInboxItem")
}

/// Watches key presses in the main window and runs shortcut actions.
@MainActor
final class KeyMonitor {
    private var monitor: Any?
    var perform: ((ShortcutAction) -> Bool)?
    var store: ShortcutStore?
    /// Set while a shortcut recorder owns the keyboard.
    static var suspended = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !KeyMonitor.suspended, let chord = ShortcutChord(event: event), let store = self.store else { return event }
            guard let action = ShortcutAction.allCases.first(where: { store.chord(for: $0) == chord }) else { return event }
            if action == .send { return event }
            if !action.allowInEditable && KeyMonitor.isEditing(event.window) { return event }
            return (self.perform?(action) ?? false) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func isEditing(_ window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let tv = responder as? NSTextView { return tv.isEditable }
        return responder is NSTextField
    }
}
