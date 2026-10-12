import AppKit
import MulticaCore
import SwiftUI

/// Settings › Environment (upstream tabs/env-tab). Values are never fetched
/// until "Reveal & edit" (each reveal is audited); bulk mode round-trips
/// through the same dotenv parser the paste path uses.
struct AgentsUIEnvTab: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let agent: AgentRecord
    let onDirtyChange: (Bool) -> Void

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var key = ""
        var value = ""
        var visible = false
    }

    @State private var revealed: [Entry]?
    @State private var original: [String: String] = [:]
    @State private var revealing = false
    @State private var saving = false
    @State private var bulk = false
    @State private var bulkText = ""
    @State private var bulkError: AgentsUI.EnvParseError?

    private var currentMap: [String: String] {
        var m: [String: String] = [:]
        for e in revealed ?? [] {
            let k = e.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { m[k] = e.value }
        }
        return m
    }

    private var dirty: Bool { revealed != nil && currentMap != original }
    private var hasUnsavedWork: Bool { dirty || (bulk && bulkError != nil) }

    var body: some View {
        Group {
            if let revealed { editor(revealed) } else { locked }
        }
        .onChange(of: hasUnsavedWork, initial: true) { onDirtyChange(hasUnsavedWork) }
    }

    private var locked: some View {
        let count = agent.customEnvKeyCount ?? 0
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(count > 0 ? tr("agents", "tab_body.env.not_revealed_title", ["count": count]) : tr("agents", "tab_body.env.not_revealed_empty"),
                      systemImage: "lock")
                    .font(Theme.Font.bodyMedium)
                Text(tr("agents", "tab_body.env.not_revealed_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { reveal() } label: {
                HStack(spacing: 5) {
                    if revealing { ProgressView().controlSize(.mini) } else { Image(systemName: "eye") }
                    Text(revealing ? tr("agents", "tab_body.env.revealing") : tr("agents", "tab_body.env.reveal_action"))
                }
            }
            .disabled(revealing)
        }
    }

    private func editor(_ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                (Text(tr("agents", "tab_body.env.intro_prefix")) + Text("ANTHROPIC_API_KEY").font(Theme.Font.mono)
                 + Text(tr("agents", "tab_body.env.intro_separator")) + Text("ANTHROPIC_BASE_URL").font(Theme.Font.mono)
                 + Text(tr("agents", "tab_body.env.intro_suffix")))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Button(bulk ? tr("agents", "tab_body.env.row_edit_action") : tr("agents", "tab_body.env.bulk_edit_action"),
                       systemImage: bulk ? "list.bullet" : "text.alignleft") {
                    if bulk { bulk = false; bulkError = nil } else { enterBulk() }
                }
                .disabled(bulk && bulkError != nil)
                if !bulk {
                    Button(tr("agents", "tab_body.common.add"), systemImage: "plus") {
                        revealed = (revealed ?? []) + [Entry(visible: true)]
                    }
                }
            }
            .controlSize(.small)
            if bulk {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $bulkText)
                        .font(Theme.Font.mono)
                        .frame(minHeight: 192)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(bulkError != nil ? Theme.destructive : Color.primary.opacity(0.14)))
                        .overlay(alignment: .topLeading) {
                            if bulkText.isEmpty {
                                Text(tr("agents", "tab_body.env.bulk_placeholder")).font(Theme.Font.mono).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                            }
                        }
                        .onChange(of: bulkText) { bulkChanged() }
                    if let bulkError {
                        Text(describe(bulkError)).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    } else {
                        Text(tr("agents", "tab_body.env.bulk_plaintext_notice")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            } else if entries.isEmpty {
                Text(tr("agents", "tab_body.env.empty_editable")).font(Theme.Font.caption).italic().foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { e in row(e) }
                }
            }
            AgentsUISaveBar(dirty: dirty, canSave: bulkError == nil, saving: saving, showUnsaved: hasUnsavedWork, onSave: save)
        }
    }

    private func row(_ e: Entry) -> some View {
        HStack(spacing: 8) {
            AgentsUIPasteAwareField(text: binding(e.id, \.key), placeholder: tr("agents", "tab_body.env.key_placeholder"), secure: false) { pasted in
                handlePaste(pasted, at: e.id)
            }
            .frame(width: 240)
            AgentsUIPasteAwareField(text: binding(e.id, \.value), placeholder: tr("agents", "tab_body.env.value_placeholder"), secure: !e.visible, onPaste: nil)
                .id(e.visible)
            Button {
                if let i = revealed?.firstIndex(where: { $0.id == e.id }) { revealed?[i].visible.toggle() }
            } label: { Image(systemName: e.visible ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(e.visible ? tr("agents", "tab_body.env.hide_value_aria") : tr("agents", "tab_body.env.show_value_aria"))
            Button {
                var list = (revealed ?? []).filter { $0.id != e.id }
                if list.isEmpty { list = [Entry(visible: true)] }
                revealed = list
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(tr("agents", "tab_body.env.remove_aria"))
        }
    }

    private func binding(_ id: UUID, _ key: WritableKeyPath<Entry, String>) -> Binding<String> {
        Binding(get: { revealed?.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { new in if let i = revealed?.firstIndex(where: { $0.id == id }) { revealed?[i][keyPath: key] = new } })
    }

    private func describe(_ e: AgentsUI.EnvParseError) -> String {
        switch e {
        case .malformed(let line): return tr("agents", "tab_body.env.parse_error_malformed", ["line": line])
        case .duplicate(let line, let key): return tr("agents", "tab_body.env.parse_error_duplicate", ["line": line, "key": key])
        }
    }

    private static func entries(_ env: [String: String]) -> [Entry] {
        let list = env.keys.sorted().map { Entry(key: $0, value: env[$0] ?? "") }
        return list.isEmpty ? [Entry(visible: true)] : list
    }

    private func reveal() {
        revealing = true
        Task {
            defer { revealing = false }
            do {
                let resp = try await session.api.getAgentEnv(agent.id)
                original = resp.customEnv
                revealed = Self.entries(resp.customEnv)
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.env.reveal_failed_toast"), kind: .error)
            }
        }
    }

    /// Returns true when the paste was consumed as an env file.
    private func handlePaste(_ text: String, at id: UUID) -> Bool {
        guard let assignments = AgentsUI.parseEnvFile(text) else {
            if AgentsUI.isEnvFilePaste(text) {
                if case .failure(let e) = AgentsUI.parseEnvFileResult(text) { toaster.error(describe(e)) }
                else { toaster.error(tr("agents", "tab_body.env.paste_invalid_toast")) }
                return true
            }
            return false
        }
        guard var list = revealed, let i = list.firstIndex(where: { $0.id == id }) else { return true }
        list.replaceSubrange(i...i, with: assignments.map { Entry(key: $0.key, value: $0.value) })
        revealed = list
        return true
    }

    private func enterBulk() {
        let assignments = (revealed ?? []).filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { AgentsUI.EnvAssignment(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value) }
        switch AgentsUI.formatEnvFile(assignments) {
        case .success(let text):
            bulkText = text
            bulkError = nil
            bulk = true
        case .failure(.duplicate):
            toaster.error(tr("agents", "tab_body.env.duplicate_keys_toast"))
        case .failure(.unrepresentable(let key)):
            toaster.error(tr("agents", "tab_body.env.bulk_unsupported_toast", ["key": key]))
        }
    }

    private func bulkChanged() {
        guard bulk else { return }
        switch AgentsUI.parseEnvFileResult(bulkText) {
        case .failure(let e):
            bulkError = e
        case .success(let list):
            bulkError = nil
            let next = list.map { Entry(key: $0.key, value: $0.value) }
            revealed = next.isEmpty ? [Entry(visible: true)] : next
        }
    }

    private func save() {
        let keys = (revealed ?? []).map { $0.key.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if Set(keys).count < keys.count {
            toaster.error(tr("agents", "tab_body.env.duplicate_keys_toast"))
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                let resp = try await session.api.updateAgentEnv(agent.id, UpdateAgentEnvRequest(customEnv: currentMap))
                original = resp.customEnv
                let saved = Self.entries(resp.customEnv)
                revealed = saved
                if bulk {
                    let assignments = saved.filter { !$0.key.isEmpty }.map { AgentsUI.EnvAssignment(key: $0.key, value: $0.value) }
                    if case .success(let text) = AgentsUI.formatEnvFile(assignments) { bulkText = text } else { bulk = false; bulkError = nil }
                }
                toaster.success(tr("agents", "tab_body.env.saved_toast"))
                await session.agentsUIReload(agent.id)
            } catch {
                toaster.show((error as? APIError)?.message ?? tr("agents", "tab_body.env.save_failed_toast"), kind: .error)
            }
        }
    }
}

/// Single-line field that offers pastes to a handler before inserting them
/// (env-file paste explodes into rows); optionally secure.
struct AgentsUIPasteAwareField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var secure = false
    var onPaste: ((String) -> Bool)?

    func makeNSView(context: Context) -> NSTextField {
        let f: NSTextField = secure ? AgentsUIPasteSecureField() : AgentsUIPasteTextField()
        f.placeholderString = placeholder
        f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        f.bezelStyle = .roundedBezel
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        (f as? AgentsUIPasteTextField)?.onPaste = { context.coordinator.parent.onPaste?($0) ?? false }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AgentsUIPasteAwareField
        init(_ p: AgentsUIPasteAwareField) { parent = p }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSText.paste(_:)), let s = NSPasteboard.general.string(forType: .string), parent.onPaste?(s) == true {
                return true
            }
            return false
        }
    }
}

/// Field editor hook: ⌘V reaches the field before the text view inserts.
final class AgentsUIPasteTextField: NSTextField {
    var onPaste: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v",
           currentEditor() != nil, let s = NSPasteboard.general.string(forType: .string), onPaste?(s) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class AgentsUIPasteSecureField: NSSecureTextField {}
