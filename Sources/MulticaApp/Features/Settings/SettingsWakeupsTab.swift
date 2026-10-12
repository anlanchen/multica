import MulticaCore
import SwiftUI

/// Settings › Wakeups (upstream wakeups-tab.tsx): workspace defaults of the
/// platform wakeup rules; issues that change their own rule stop following.
struct SettingsWakeupsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var rules: [WorkspaceSystemWakeup] = []
    @State private var loadFailed = false

    var body: some View {
        let canManage = session.settingsCanManage
        let childDone = rules.first { $0.rule == "child_done" }
        SettingsTabView(title: tr("settings", "page.tabs.wakeups"), description: tr("settings", "wakeups.description")) {
            if loadFailed {
                Text(tr("settings", "wakeups.load_error")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
            if let childDone {
                SettingsChildDoneDefault(rule: childDone, canManage: canManage) { await load() }
                if !canManage {
                    Text(tr("settings", "wakeups.admin_only")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: session.revision("system_wakeup")) { await load() }
    }

    private func load() async {
        do {
            rules = try await session.api.listWorkspaceSystemWakeups()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

private struct SettingsChildDoneDefault: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let rule: WorkspaceSystemWakeup
    let canManage: Bool
    let reload: () async -> Void
    @State private var instruction = ""
    @State private var error = ""
    @State private var pending = false

    var body: some View {
        let dirty = instruction.trimmingCharacters(in: .whitespacesAndNewlines) != rule.instruction
        SettingsSectionView(title: tr("settings", "wakeups.child_done_title"), description: tr("settings", "wakeups.child_done_description"), anchor: "child-done") {
            SettingsCardView {
                SettingsRowView(tr("settings", "wakeups.enabled"),
                                description: rule.customized > 0 ? tr("settings", "wakeups.customized", ["count": Int(rule.customized)]) : nil) {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in Task { await save(enabled: enabled) } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(!canManage || pending)
                        .accessibilityLabel(tr("settings", "wakeups.enabled"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("settings", "wakeups.instruction")).font(Theme.Font.bodyMedium)
                    Text(tr("settings", "wakeups.instruction_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    SettingsTextArea(text: $instruction, placeholder: tr("settings", "wakeups.instruction_placeholder"),
                                     disabled: !canManage || pending, invalid: !error.isEmpty)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            submit()
                            return .handled
                        }
                    if !error.isEmpty {
                        Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    }
                    if !rule.builtinInstruction.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("settings", "wakeups.builtin")).fontWeight(.medium)
                            Text(rule.builtinInstruction).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.04)))
                    }
                    if canManage {
                        HStack {
                            Spacer()
                            Button(pending ? tr("settings", "wakeups.saving") : tr("settings", "wakeups.save"), action: submit)
                                .controlSize(.small)
                                .disabled(!dirty || pending)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .onAppear { instruction = rule.instruction }
        .onChange(of: rule.instruction) { instruction = rule.instruction }
        .onChange(of: instruction) { error = "" }
    }

    private func submit() {
        let next = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next.utf8.count <= SettingsRules.maxWakeupInstructionBytes else {
            error = tr("settings", "wakeups.instruction_invalid")
            return
        }
        Task { await save(instruction: next) }
    }

    private func save(enabled: Bool? = nil, instruction: String? = nil) async {
        pending = true
        defer { pending = false }
        do {
            try await session.api.updateWorkspaceSystemWakeup(rule: rule.rule, enabled: enabled, instruction: instruction)
            await reload()
        } catch {
            toaster.error(tr("settings", "wakeups.save_error"))
        }
    }
}
