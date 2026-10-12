import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

/// Agent-or-squad assignee of an autopilot.
struct AutopilotsAssignee: Hashable {
    var type: String
    var id: String
}

/// Agent / squad picker (upstream pickers/agent-picker): active agents, then
/// active squads; an agent without a runtime (or a squad whose leader has
/// none) is shown but cannot be picked.
struct AutopilotsAgentPicker<Label: View>: View {
    @Environment(WorkspaceSession.self) private var session
    let assignee: AutopilotsAssignee?
    let onChange: (AutopilotsAssignee) -> Void
    @ViewBuilder var label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                OptionList(
                    options: options,
                    selected: assignee.map { ["\($0.type):\($0.id)"] } ?? [],
                    searchPlaceholder: t("agent_picker.filter_placeholder")
                ) { key in
                    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    open = false
                    onChange(AutopilotsAssignee(type: parts[0], id: parts[1]))
                }
                .task {
                    await session.agentRecords.loadIfNeeded()
                    await session.squads.loadIfNeeded()
                }
            }
    }

    private var options: [PickerOption<String>] {
        let agents = session.agentRecords.items.filter { $0.archivedAt == nil }
        let byID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func bound(_ a: AgentRecord) -> Bool {
            a.runtimeBound != false && !a.runtimeId.trimmingCharacters(in: .whitespaces).isEmpty
        }
        var out: [PickerOption<String>] = []
        let agentsGroup = t("agent_picker.agents_group")
        for a in agents {
            let ok = bound(a)
            out.append(PickerOption(id: "agent:\(a.id)", title: a.name, group: agentsGroup, disabled: !ok,
                                    help: ok ? nil : t("agent_picker.agent_runtime_required"),
                                    icon: AnyView(AvatarView(name: a.name, url: a.avatarUrl, kind: .agent, size: 16))))
        }
        let squadsGroup = t("agent_picker.squads_group")
        for s in session.squads.items where s.archivedAt == nil {
            let ok = byID[s.leaderId].map(bound) ?? false
            out.append(PickerOption(id: "squad:\(s.id)", title: s.name, group: squadsGroup, disabled: !ok,
                                    help: ok ? nil : t("agent_picker.squad_runtime_required"),
                                    icon: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16))))
        }
        return out
    }
}

/// Timezone picker (upstream pickers/timezone-picker): city + current
/// offset, searchable by zone id, city and offset. Rows are only built while
/// the popover is open.
struct AutopilotsTimezonePicker: View {
    let value: String
    var disabled = false
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(AutopilotsSchedule.cityLabel(value)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(AutopilotsSchedule.offsetLabel(value)).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(Theme.Font.body)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel("\(t("schedule_editor.a11y.timezone")): \(AutopilotsSchedule.cityLabel(value)) \(AutopilotsSchedule.offsetLabel(value))")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AutopilotsTimezoneList(value: value) { tz in
                open = false
                onChange(tz)
            }
        }
    }
}

private struct AutopilotsTimezoneList: View {
    let value: String
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var rows: [(id: String, city: String, offset: String)] = []
    @FocusState private var focused: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? rows : rows.filter { "\($0.id) \($0.city) \($0.offset)".lowercased().contains(q) }
        VStack(spacing: 0) {
            TextField(t("timezone_picker.search_placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .focused($focused)
                .onSubmit { if let first = filtered.first { onPick(first.id) } }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered, id: \.id) { row in
                        Button { onPick(row.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                                    .opacity(row.id == value ? 1 : 0)
                                Text(row.city).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.offset).font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(Theme.Font.body)
                        }
                        .buttonStyle(HoverRowButtonStyle())
                        .help(row.id)
                        .padding(.horizontal, 4)
                    }
                    if filtered.isEmpty {
                        Text(tr("issues", "pickers.no_results")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 300)
        }
        .frame(width: 260)
        .onAppear {
            focused = true
            let now = Date()
            rows = AutopilotsSchedule.timezoneOptions(current: value).map {
                ($0, AutopilotsSchedule.cityLabel($0), AutopilotsSchedule.offsetLabel($0, at: now))
            }
        }
    }
}

/// Member subscribers of an autopilot (upstream subscriber-multi-select):
/// removable chips and a dashed "Add subscriber" pill.
struct AutopilotsSubscriberSelect: View {
    @Environment(WorkspaceSession.self) private var session
    let selectedIDs: [String]
    let onChange: ([String]) -> Void
    @State private var open = false

    var body: some View {
        let selected = Set(selectedIDs)
        AutopilotsFlowLayout(spacing: 6) {
            ForEach(session.directory.members.filter { selected.contains($0.userID) }) { m in
                HStack(spacing: 4) {
                    AvatarView(name: m.name, url: m.avatarURL, size: 14)
                    Text(m.name).lineLimit(1).frame(maxWidth: 160, alignment: .leading).fixedSize()
                    Button { onChange(selectedIDs.filter { $0 != m.userID }) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(t("dialog.subscribers_remove_tooltip"))
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder(Theme.border))
            }
            Button { open.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                    Text(t("dialog.subscribers_add"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                OptionList(
                    options: session.directory.members.map {
                        PickerOption(id: $0.userID, title: $0.name, icon: AnyView(AvatarView(name: $0.name, url: $0.avatarURL, size: 16)))
                    },
                    selected: selected,
                    searchPlaceholder: t("dialog.subscribers_search_placeholder"),
                    multiSelect: true
                ) { id in
                    onChange(selected.contains(id) ? selectedIDs.filter { $0 != id } : selectedIDs + [id])
                }
            }
        }
    }
}

/// Grant / revoke explicit write access (upstream autopilot-access-manager).
/// Changes commit immediately, independent of the dialog's Save.
struct AutopilotsAccessManager: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let model: AutopilotsDetailModel
    @State private var pickerOpen = false
    @State private var revoking = false

    var body: some View {
        let collaborators = model.collaborators
        let granted = Set(collaborators.map(\.userId))
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("access.title")).font(Theme.Font.bodyMedium)
                Text(t("access.description")).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(t("access.current_label").uppercased()).font(.system(size: 11, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                Button { pickerOpen.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                        Text(t("access.add"))
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                    OptionList(
                        options: session.directory.members.filter { !granted.contains($0.userID) }.map {
                            PickerOption(id: $0.userID, title: $0.name, icon: AnyView(AvatarView(name: $0.name, url: $0.avatarURL, size: 16)))
                        },
                        searchPlaceholder: t("access.search_placeholder")
                    ) { userID in
                        pickerOpen = false
                        Task { await grant(userID) }
                    }
                }
            }
            if collaborators.isEmpty {
                AutopilotsDashedBox(padding: 14) { Text(t("access.empty")) }
            } else {
                VStack(spacing: 2) {
                    ForEach(collaborators, id: \.userId) { c in
                        HStack(spacing: 8) {
                            ActorAvatar(type: "member", id: c.userId, size: 18, showName: true)
                            Spacer(minLength: 4)
                            Button { Task { await revoke(c.userId) } } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(revoking)
                            .help(t("access.remove_tooltip"))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .hoverHighlight()
                    }
                }
            }
            Text(t("access.owner_note")).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func grant(_ userID: String) async {
        do {
            let r = try await session.api.grantAutopilotAccess(model.id, userId: userID)
            model.setCollaborators(r.collaborators)
            toaster.success(t("access.toast_granted"))
        } catch {
            toaster.error((error as? APIError)?.message ?? t("access.toast_failed"))
        }
    }

    private func revoke(_ userID: String) async {
        revoking = true
        defer { revoking = false }
        do {
            let r = try await session.api.revokeAutopilotAccess(model.id, userId: userID)
            model.setCollaborators(r.collaborators)
            toaster.success(t("access.toast_revoked"))
        } catch {
            toaster.error((error as? APIError)?.message ?? t("access.toast_failed"))
        }
    }
}

/// Wrapping row layout for chips.
struct AutopilotsFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
