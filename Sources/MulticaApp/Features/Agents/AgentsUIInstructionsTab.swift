import MulticaCore
import SwiftUI

/// Capabilities › Instructions (upstream tabs/instructions-tab): the system
/// prompt (or workspace notes over a Multica-maintained layer) and the
/// conversation starters, saved together.
struct AgentsUIInstructionsTab: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    let agent: AgentRecord
    let onDirtyChange: (Bool) -> Void
    let onSave: ([String: JSONValue]) async throws -> Void

    @State private var value = ""
    @State private var starters: [AgentConversationStarter] = []
    @State private var persisted: (id: String, instructions: String, starters: [AgentConversationStarter])?
    @State private var saving = false
    @State private var systemOpen = false
    @State private var startersFocused = false

    private var startersSupported: Bool { env.appConfig?.agentConversationStartersSupported == true }
    private var persistedStarters: [AgentConversationStarter] { agent.conversationStarters ?? [] }
    private var dirty: Bool { value != agent.instructions || (startersSupported && starters != persistedStarters) }
    private var startersValid: Bool {
        !startersSupported || starters.allSatisfy {
            !$0.label.trimmingCharacters(in: .whitespaces).isEmpty && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    private var systemLayer: String { agent.systemInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    var body: some View {
        let hasSystem = !systemLayer.isEmpty
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 20) {
                Text(hasSystem ? tr("agents", "tab_body.instructions.workspace_notes_intro") : tr("agents", "tab_body.instructions.intro"))
                    .font(Theme.Font.body).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
                if hasSystem {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Text(tr("agents", "tab_body.instructions.system_layer_label")).font(Theme.Font.bodyMedium)
                            Text(tr("agents", "tab_body.instructions.system_layer_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(systemOpen ? tr("agents", "tab_body.instructions.system_layer_hide") : tr("agents", "tab_body.instructions.system_layer_show")) {
                                systemOpen.toggle()
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(12)
                        if systemOpen {
                            Divider()
                            ScrollView {
                                Text(systemLayer).font(Theme.Font.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                            .frame(maxHeight: 320)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(hasSystem ? tr("agents", "tab_body.instructions.workspace_notes_label") : tr("agents", "tab_body.instructions.system_prompt_label"))
                        .font(Theme.Font.bodyMedium)
                    MarkdownEditor(text: $value,
                                   placeholder: hasSystem ? tr("agents", "tab_body.instructions.workspace_notes_placeholder") : tr("agents", "tab_body.instructions.placeholder"),
                                   minHeight: 384, maxHeight: 900)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.14)))
                }
                if startersSupported {
                    AgentsUIConversationStartersEditor(value: $starters)
                        .padding(startersFocused ? 8 : 0)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.brand.opacity(startersFocused ? 0.5 : 0), lineWidth: 2))
                        .animation(.easeOut(duration: 0.5), value: startersFocused)
                        .id("starters")
                }
                AgentsUISaveBar(dirty: dirty, canSave: startersValid, saving: saving, onSave: save)
            }
            .onAppear { focusIfRequested(proxy) }
            .onChange(of: nav.query("focus")) { focusIfRequested(proxy) }
        }
        .onAppear(perform: syncFromAgent)
        .onChange(of: agent.instructions) { syncFromAgent() }
        .onChange(of: agent.conversationStarters) { syncFromAgent() }
        .onChange(of: dirty, initial: true) { onDirtyChange(dirty) }
    }

    /// Adopts server changes only while the form is clean, and always when
    /// switching agents; an in-flight save keeps the submitted values.
    private func syncFromAgent() {
        guard let p = persisted, p.id == agent.id else {
            value = agent.instructions
            starters = persistedStarters
            persisted = (agent.id, agent.instructions, persistedStarters)
            return
        }
        if saving { return }
        let locallyDirty = value != p.instructions || starters != p.starters
        let changed = p.instructions != agent.instructions || p.starters != persistedStarters
        persisted = (agent.id, agent.instructions, persistedStarters)
        if !locallyDirty && changed {
            value = agent.instructions
            starters = persistedStarters
        }
    }

    private func focusIfRequested(_ proxy: ScrollViewProxy) {
        guard startersSupported, nav.query("focus") == "conversation_starters" else { return }
        nav.setQuery("focus", nil)
        withAnimation { proxy.scrollTo("starters", anchor: .center) }
        startersFocused = true
        Task {
            try? await Task.sleep(for: .milliseconds(1600))
            startersFocused = false
        }
    }

    private func save() {
        saving = true
        var patch: [String: JSONValue] = ["instructions": .string(value)]
        if startersSupported {
            patch["conversation_starters"] = .array(starters.map { .object(["label": .string($0.label), "prompt": .string($0.prompt)]) })
        }
        Task {
            try? await onSave(patch)
            saving = false
            persisted = (agent.id, agent.instructions, persistedStarters)
        }
    }
}

/// Up to three label + prompt suggestions with a live preview of a new chat
/// (upstream conversation-starters-editor).
struct AgentsUIConversationStartersEditor: View {
    @Binding var value: [AgentConversationStarter]
    var disabled = false

    static var fallback: [AgentConversationStarter] {
        ["capabilities", "first_task", "recommend"].map {
            AgentConversationStarter(label: tr("chat", "conversation_starters.\($0).label"), prompt: tr("chat", "conversation_starters.\($0).prompt"))
        }
    }

    var body: some View {
        let incomplete = value.contains {
            $0.label.trimmingCharacters(in: .whitespaces).isEmpty || $0.prompt.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let preview = AgentsUI.selectConversationStarters(value, fallback: Self.fallback)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("agents", "conversation_starters.label")).font(Theme.Font.bodyMedium)
                Text(tr("agents", "conversation_starters.hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            ForEach(value.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(tr("agents", "conversation_starters.label_placeholder"), text: binding(i, \.label, max: AgentsUI.conversationStarterLabelMaxLength))
                            .textFieldStyle(.roundedBorder)
                            .help(tr("agents", "conversation_starters.item_label", ["number": i + 1]))
                        Button { value.remove(at: i) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(tr("agents", "conversation_starters.remove", ["number": i + 1]))
                    }
                    TextEditor(text: binding(i, \.prompt, max: AgentsUI.conversationStarterMaxLength))
                        .font(Theme.Font.body)
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.14)))
                        .overlay(alignment: .topLeading) {
                            if value[i].prompt.isEmpty {
                                Text(tr("agents", "conversation_starters.prompt_placeholder")).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                            }
                        }
                        .help(tr("agents", "conversation_starters.prompt_label", ["number": i + 1]))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            }
            if value.count < AgentsUI.conversationStartersMax {
                Button { value.append(AgentConversationStarter(label: "", prompt: "")) } label: {
                    Label(tr("agents", "conversation_starters.add"), systemImage: "plus")
                }
                .disabled(disabled)
            }
            if incomplete {
                Text(tr("agents", "conversation_starters.incomplete")).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("agents", "conversation_starters.preview_label")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(preview.starters.indices, id: \.self) { i in
                        Text(preview.starters[i].label).font(Theme.Font.body).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    }
                }
                .frame(maxWidth: 380)
                if preview.isFallback {
                    Text(tr("agents", "conversation_starters.preview_defaults")).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .disabled(disabled)
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<AgentConversationStarter, String>, max: Int) -> Binding<String> {
        Binding(get: { value.indices.contains(i) ? value[i][keyPath: key] : "" },
                set: { new in
                    guard value.indices.contains(i) else { return }
                    value[i][keyPath: key] = String(new.prefix(max))
                })
    }
}
