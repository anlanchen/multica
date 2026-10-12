import MulticaCore
import SwiftUI

/// Floating bulk-action bar for the selected rows (upstream
/// batch-action-toolbar.tsx). Acts on selection ∩ visible rows.
struct IssueListBatchBar: View {
    @Bindable var model: IssueListSurfaceModel
    @Environment(WorkspaceSession.self) private var session
    @Environment(ModalCenter.self) private var modals
    @State private var busy = false

    var body: some View {
        let selected = model.selectedIssues
        if !selected.isEmpty {
            let ids = selected.map(\.id)
            HStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(tr("issues", "batch.selected", ["count": selected.count])).font(Theme.Font.bodyMedium)
                    Button { model.clearSelection() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 6)
                .padding(.trailing, 10)
                Divider().frame(height: 18)
                statusPicker(selected, ids)
                priorityPicker(selected, ids)
                assigneePicker(selected, ids)
                labelPicker(selected, ids)
                projectPicker(selected, ids)
                Button {
                    modals.present(.deleteIssues(issueIDs: ids))
                } label: {
                    Label(tr("issues", "batch.delete"), systemImage: "trash")
                }
                .buttonStyle(IssueListBatchButtonStyle(destructive: true))
            }
            .disabled(busy)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func run(_ ids: [String], _ patch: IssueListPatch) {
        busy = true
        Task {
            await model.batchUpdate(ids, patch)
            busy = false
        }
    }

    private func statusPicker(_ selected: [Issue], _ ids: [String]) -> some View {
        let common = Set(selected.map(\.status)).count == 1 ? selected[0].status : nil
        return PopoverButton(label: { IssueListBatchLabel(text: tr("issues", "batch.status")) }, content: { dismiss in
            OptionList(
                options: IssueListStatusColumns.options(entries: session.issueListStatusEntries).map { key in
                    PickerOption(id: key, title: session.issueListStatusLabel(key), icon: AnyView(session.issues.catalog.icon(for: key)))
                },
                selected: common.map { [$0] } ?? [],
                searchPlaceholder: tr("issues", "filters.search_status")
            ) { key in
                dismiss()
                var p = IssueListPatch()
                p.status = key
                run(ids, p)
            }
        }, style: nil)
    }

    private func priorityPicker(_ selected: [Issue], _ ids: [String]) -> some View {
        let common = Set(selected.map(\.priority)).count == 1 ? selected[0].priority : nil
        return PopoverButton(label: { IssueListBatchLabel(text: tr("issues", "batch.priority")) }, content: { dismiss in
            OptionList(
                options: IssuePriority.displayOrder.map { PickerOption(id: $0, title: $0.localizedName, icon: AnyView(PriorityIcon(priority: $0))) },
                selected: common.map { [$0] } ?? []
            ) { p in
                dismiss()
                var patch = IssueListPatch()
                patch.priority = p
                run(ids, patch)
            }
        }, style: nil)
    }

    private func assigneePicker(_ selected: [Issue], _ ids: [String]) -> some View {
        let refs = Set(selected.map { $0.assignee.map { "\($0.type):\($0.id)" } ?? "none" })
        return PopoverButton(label: { IssueListBatchLabel(text: tr("issues", "batch.assignee")) }, content: { dismiss in
            OptionList(
                options: assigneeOptions,
                selected: refs.count == 1 ? refs : [],
                searchPlaceholder: tr("issues", "pickers.assignee.search_placeholder")
            ) { key in
                dismiss()
                var patch = IssueListPatch()
                if key == "none" {
                    patch.assignee = .clear
                } else {
                    let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { return }
                    let ref = ActorRef(type: parts[0], id: parts[1])
                    patch.assignee = .set(ref)
                    // Backlog never starts a run on assign; anything else
                    // hands work to an agent and confirms first.
                    if (ref.type == "agent" || ref.type == "squad") && !selected.allSatisfy({ $0.status == .backlog }) {
                        model.runConfirm = IssueListRunConfirm(issueIDs: ids, mode: .assign, status: nil, assignee: ref)
                        return
                    }
                }
                run(ids, patch)
            }
            .task { await session.squads.loadIfNeeded() }
        }, style: nil)
    }

    private var assigneeOptions: [PickerOption<String>] {
        var out: [PickerOption<String>] = [
            PickerOption(id: "none", title: tr("issues", "pickers.assignee.trigger_unassigned"),
                         icon: AnyView(Image(systemName: "person.crop.circle.dashed").foregroundStyle(.secondary))),
        ]
        for m in session.directory.members {
            out.append(PickerOption(id: "member:\(m.userID)", title: m.name, group: tr("issues", "pickers.assignee.members_group"),
                                    icon: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16))))
        }
        for a in session.directory.agents where a.archivedAt == nil {
            out.append(PickerOption(id: "agent:\(a.id)", title: a.name, group: tr("issues", "pickers.assignee.agents_group"),
                                    disabled: a.runtimeID.isEmpty,
                                    help: a.runtimeID.isEmpty ? tr("issues", "pickers.assignee.agent_runtime_required") : nil,
                                    icon: AnyView(AvatarView(name: a.name, url: a.avatarURL, kind: .agent, size: 16))))
        }
        for s in session.squads.items where s.archivedAt == nil {
            out.append(PickerOption(id: "squad:\(s.id)", title: s.name, group: tr("issues", "pickers.assignee.squads_group"),
                                    icon: AnyView(AvatarView(name: s.name, url: s.avatarUrl, kind: .squad, size: 16))))
        }
        return out
    }

    private func labelPicker(_ selected: [Issue], _ ids: [String]) -> some View {
        let common = selected.dropFirst().reduce(Set(selected.first?.labels.map(\.id) ?? [])) { $0.intersection($1.labels.map(\.id)) }
        return PopoverButton(label: { IssueListBatchLabel(text: tr("issues", "pickers.label.trigger_label")) }, content: { _ in
            OptionList(
                options: session.labels.items.map { l in
                    PickerOption(id: l.id, title: l.name, icon: AnyView(Circle().fill(Color(hex: l.color)).frame(width: 8, height: 8)))
                },
                selected: common,
                searchPlaceholder: tr("issues", "pickers.label.search_placeholder"),
                multiSelect: true
            ) { id in
                guard let label = session.labels.item(id) else { return }
                Task { await model.batchLabel(ids, label: label, attach: !common.contains(id)) }
            }
            .task { await session.labels.loadIfNeeded() }
        }, style: nil)
    }

    private func projectPicker(_ selected: [Issue], _ ids: [String]) -> some View {
        let projects = Set(selected.map { $0.projectID ?? "" })
        return PopoverButton(label: { IssueListBatchLabel(text: tr("issues", "filters.section_project")) }, content: { dismiss in
            OptionList(
                options: [PickerOption(id: "", title: tr("projects", "picker.no_project"),
                                       icon: AnyView(Image(systemName: "folder.badge.minus").foregroundStyle(.secondary)))]
                    + session.projects.items.map { p in PickerOption(id: p.id, title: p.title, icon: AnyView(ProjectIconView(icon: p.icon, size: 14))) },
                selected: projects.count == 1 ? projects : [],
                searchPlaceholder: tr("projects", "picker.search_placeholder")
            ) { id in
                dismiss()
                var patch = IssueListPatch()
                patch.projectID = id.isEmpty ? .clear : .set(id)
                run(ids, patch)
            }
            .task { await session.projects.loadIfNeeded() }
        }, style: nil)
    }
}

private struct IssueListBatchButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.body)
            .foregroundStyle(destructive ? Theme.destructive : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.selected : .clear))
            .contentShape(Rectangle())
    }
}

private struct IssueListBatchLabel: View {
    let text: String
    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
