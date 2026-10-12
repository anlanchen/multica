import MulticaCore
import SwiftUI

/// Attach skills to agents (upstream AddToAgentDialog). Attaching is gated by
/// the target agent: members see their own agents, admins everyone's.
struct SkillsAddToAgentSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let skills: [SkillSummary]
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var saving = false
    @State private var othersExpanded = false

    var body: some View {
        let skillIDs = skills.map(\.id)
        let userID = session.currentUser.id
        let isAdmin = SkillsPermissions.isAdmin(role: session.skillsMyRole)
        let active = session.agentRecords.items.filter { $0.archivedAt == nil }
        let mine = active.filter { $0.ownerId != nil && $0.ownerId == userID }
        let others = isAdmin ? active.filter { $0.ownerId == nil || $0.ownerId != userID } : []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let searching = !q.isEmpty
        let filteredMine = mine.filter { !searching || $0.name.lowercased().contains(q) }
        let filteredOthers = others.filter { !searching || $0.name.lowercased().contains(q) }

        VStack(alignment: .leading, spacing: 12) {
            Text(tr("skills", "actions.add_to_agent")).font(Theme.Font.bodyMedium)
            SkillsChips(skills: skills)
            if !(mine.isEmpty && others.isEmpty) {
                SearchField(text: $query, prompt: tr("skills", "actions.search_placeholder"), autofocus: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if mine.isEmpty && others.isEmpty {
                        emptyText(tr("skills", "actions.no_agents"))
                    } else if filteredMine.isEmpty && filteredOthers.isEmpty {
                        emptyText(tr("skills", "actions.no_agents_match"))
                    } else {
                        group(tr("skills", "actions.my_agents"), agents: filteredMine, expanded: .constant(true), collapsible: false, skillIDs: skillIDs)
                        group(tr("skills", "actions.other_agents"), agents: filteredOthers,
                              expanded: Binding(get: { searching || othersExpanded }, set: { othersExpanded = $0 }),
                              collapsible: true, skillIDs: skillIDs)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            HStack {
                Spacer()
                Button(tr("skills", "actions.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button {
                    Task { await confirm(targets: (mine + others).filter { selected.contains($0.id) }, skillIDs: skillIDs) }
                } label: {
                    SkillsBusyLabel(title: saving ? tr("skills", "actions.adding") : tr("skills", "actions.add_confirm", ["num": selected.count]), busy: saving)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 512)
        .interactiveDismissDisabled(saving)
        .task { await session.agentRecords.loadIfNeeded() }
    }

    private func emptyText(_ s: String) -> some View {
        Text(s).font(Theme.Font.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    @ViewBuilder
    private func group(_ title: String, agents: [AgentRecord], expanded: Binding<Bool>, collapsible: Bool, skillIDs: [String]) -> some View {
        if !agents.isEmpty {
            Button { if collapsible { expanded.wrappedValue.toggle() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Text(title)
                    Text("\(agents.count)")
                    Spacer()
                }
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowButtonStyle())
            if expanded.wrappedValue {
                ForEach(agents, id: \.id) { agent in
                    agentRow(agent, skillIDs: skillIDs)
                }
            }
        }
    }

    private func agentRow(_ agent: AgentRecord, skillIDs: [String]) -> some View {
        let owned = skillIDs.filter { id in agent.skills.contains { $0.id == id } }.count
        let hasAll = owned == skillIDs.count
        let isSelected = selected.contains(agent.id)
        return Button {
            if isSelected { selected.remove(agent.id) } else { selected.insert(agent.id) }
        } label: {
            HStack(spacing: 10) {
                SkillsCheckbox(checked: hasAll || isSelected)
                SkillsAgentAvatar(agent: agent, size: 22)
                Text(agent.name).font(Theme.Font.body).lineLimit(1)
                Spacer(minLength: 4)
                if hasAll {
                    Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if owned > 0 {
                    Text(tr("skills", "actions.has_partial", ["owned": owned, "total": skillIDs.count]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(HoverRowButtonStyle(selected: isSelected && !hasAll))
        .disabled(hasAll)
        .opacity(hasAll ? 0.5 : 1)
    }

    private func confirm(targets: [AgentRecord], skillIDs: [String]) async {
        guard !targets.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            for agent in targets {
                let missing = skillIDs.filter { id in !agent.skills.contains { $0.id == id } }
                if !missing.isEmpty {
                    try await session.api.addAgentSkills(agentId: agent.id, SetAgentSkillsRequest(skillIds: missing))
                }
            }
            await session.agentRecords.load()
            if targets.count == 1, let only = targets.first {
                toaster.success(tr("skills", "actions.added_toast", ["name": only.name]))
            } else {
                toaster.success(tr("skills", "actions.added_multi_toast", ["count": targets.count]))
            }
            dismiss()
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? tr("skills", "actions.add_failed_toast") : message)
        }
    }
}

/// First few skill names as chips; the rest collapse into "+N".
private struct SkillsChips: View {
    let skills: [SkillSummary]

    var body: some View {
        let overflow = skills.dropFirst(3)
        HStack(spacing: 4) {
            ForEach(skills.prefix(3), id: \.id) { s in chip(s.name) }
            if !overflow.isEmpty {
                chip("+\(overflow.count)")
                    .fontWeight(.medium)
                    .help(overflow.prefix(10).map(\.name).joined(separator: ", ") + (overflow.count > 10 ? "…" : ""))
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: 160)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
    }
}

/// Delete one or more skills (single and batch share the dialog).
struct SkillsDeleteSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let skills: [SkillSummary]
    let agentCounts: [Int]
    /// The detail page uses its own toasts (`detail.toast_deleted`).
    var successMessage: String? = nil
    var failureMessage: String? = nil
    let onDeleted: ([String]) -> Void
    @State private var deleting = false

    var body: some View {
        let count = skills.count
        let single = count == 1 ? skills.first : nil
        let description: String = {
            guard let single else { return tr("skills", "actions.delete_dialog_desc", ["count": count]) }
            let agents = agentCounts.first ?? 0
            return agents > 0
                ? tr("skills", "detail.delete_dialog.description_with_agents", ["name": single.name, "count": agents])
                : tr("skills", "detail.delete_dialog.description_no_agents", ["name": single.name])
        }()
        SkillsDialog(title: single != nil ? tr("skills", "detail.delete_dialog.title") : tr("skills", "actions.delete_dialog_title", ["count": count]),
                     description: description) {
            SkillsNotice(text: tr("skills", "detail.delete_dialog.warning"), tone: .destructive)
        } footer: {
            Button(tr("skills", "detail.delete_dialog.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(deleting)
            Button(role: .destructive) {
                Task { await confirm() }
            } label: {
                SkillsBusyLabel(title: deleting ? tr("skills", "detail.delete_dialog.deleting") : tr("skills", "detail.delete_dialog.confirm"),
                                icon: "trash", busy: deleting)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(deleting)
        }
        .interactiveDismissDisabled(deleting)
    }

    private func confirm() async {
        deleting = true
        defer { deleting = false }
        var deleted: [String] = []
        do {
            for skill in skills {
                try await session.api.deleteSkill(skill.id)
                deleted.append(skill.id)
            }
            dismiss()
            onDeleted(deleted)
            await session.agentRecords.refreshIfLoaded()
            toaster.success(successMessage ?? tr("skills", "actions.deleted_toast", ["count": skills.count]))
        } catch {
            if !deleted.isEmpty { onDeleted(deleted) }
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? failureMessage ?? tr("skills", "actions.delete_failed_toast") : message)
        }
    }
}

/// Bulk "update from source": sequential, tolerant of per-item failures; a
/// partial failure keeps the selection for a retry.
struct SkillsUpdateSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let rows: [SkillsListRow]
    let skipped: Int
    let onUpdated: () -> Void
    @State private var updating = false
    @State private var progress = 0

    var body: some View {
        SkillsDialog(title: tr("skills", "actions.update_dialog_title")) {
            VStack(alignment: .leading, spacing: 4) {
                Text("• " + tr("skills", "actions.update_summary_selected", ["count": rows.count]))
                if skipped > 0 { Text("• " + tr("skills", "actions.update_summary_skipped", ["count": skipped])) }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            SkillsNotice(text: tr("skills", "detail.refresh.dialog.warning"))
        } footer: {
            Button(tr("skills", "actions.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(updating)
            Button {
                Task { await confirm() }
            } label: {
                SkillsBusyLabel(title: updating ? tr("skills", "actions.update_updating", ["done": progress, "total": rows.count])
                                                : tr("skills", "actions.update_confirm", ["count": rows.count]),
                                icon: "arrow.clockwise", busy: updating)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(updating || rows.isEmpty)
        }
        .interactiveDismissDisabled(updating)
    }

    private func confirm() async {
        updating = true
        var updated = 0
        var failed = 0
        for row in rows {
            progress = updated + failed + 1
            do {
                let skill = try await session.api.refreshSkill(row.skill.id)
                if !skill.id.isEmpty { session.skills.upsert(skill.skillsSummary) }
                updated += 1
            } catch {
                failed += 1
            }
        }
        await session.skills.load()
        await session.agentRecords.refreshIfLoaded()
        updating = false
        progress = 0
        if failed == 0 {
            toaster.success(tr("skills", "actions.updated_toast", ["count": updated]))
            onUpdated()
        } else {
            toaster.error(tr("skills", "actions.update_partial_toast", ["count": updated, "failed": failed]))
        }
        dismiss()
    }
}

/// Confirm-and-run `POST /api/skills/:id/refresh`: name, description,
/// SKILL.md and files are replaced; id, assignments, labels and creator stay.
struct SkillsRefreshSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let skill: SkillSummary
    let origin: SkillsOrigin
    var onRefreshed: ((Skill) -> Void)? = nil
    @State private var refreshing = false

    var body: some View {
        let source = SkillsOriginStyle.refreshSourceLabel(origin)
        SkillsDialog(title: tr("skills", "detail.refresh.dialog.title"),
                     description: tr("skills", "detail.refresh.dialog.description", ["name": skill.name, "source": source])) {
            if let link = origin.linkURL, let url = URL(string: link) {
                Link(SkillsErrors.midTruncate(link, maxLength: 60), destination: url)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(link)
            }
            SkillsNotice(text: tr("skills", "detail.refresh.dialog.warning"))
        } footer: {
            Button(tr("skills", "detail.refresh.dialog.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(refreshing)
            Button {
                Task { await confirm(source: source) }
            } label: {
                SkillsBusyLabel(title: refreshing ? tr("skills", "detail.refresh.dialog.refreshing") : tr("skills", "detail.refresh.dialog.confirm"),
                                icon: "arrow.clockwise", busy: refreshing)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(refreshing)
        }
        .interactiveDismissDisabled(refreshing)
    }

    private func confirm(source: String) async {
        refreshing = true
        defer { refreshing = false }
        do {
            let updated = try await session.api.refreshSkill(skill.id)
            if updated.id == skill.id { session.skills.upsert(updated.skillsSummary) }
            await session.skills.load()
            await session.agentRecords.refreshIfLoaded()
            toaster.success(tr("skills", "detail.refresh.toast_success", ["source": source]))
            dismiss()
            if updated.id == skill.id { onRefreshed?(updated) }
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? tr("skills", "detail.refresh.toast_failed") : message)
        }
    }
}
