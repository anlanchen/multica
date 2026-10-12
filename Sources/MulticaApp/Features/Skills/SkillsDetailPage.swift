import MulticaCore
import SwiftUI

private enum SkillsDetailSheet: Identifiable {
    case delete, addToAgent, refresh
    var id: Self { self }
}

/// Skill detail (upstream SkillDetailPage): identity strip, Overview and
/// Files tabs, a dirty-only floating save bar and conflict handling.
struct SkillsDetailScreen: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    @Environment(Toaster.self) private var toaster
    let skillID: String
    @State private var model: SkillsDetailModel
    @State private var sheet: SkillsDetailSheet?

    init(skillID: String) {
        self.skillID = skillID
        _model = State(initialValue: SkillsDetailModel(skillID: skillID))
    }

    var body: some View {
        Group {
            if model.isLoading && model.skill == nil {
                loading
            } else if let skill = model.skill {
                content(skill)
            } else {
                notFound
            }
        }
        .tabTitle(model.skill?.name)
        .task(id: "\(skillID)|\(session.revision("skill"))") { await model.load(api: session.api) }
        .task { await session.skillsLoadSupportingData() }
    }

    private var canEdit: Bool {
        guard let skill = model.skill else { return false }
        return SkillsPermissions.canEdit(createdBy: skill.createdBy, userID: session.currentUser.id, role: session.skillsMyRole)
    }

    private var activeTab: SkillsDetailTab { nav.query("view") == "files" ? .files : .overview }

    // MARK: Loaded

    private func content(_ skill: Skill) -> some View {
        let canEdit = self.canEdit
        let origin = skill.skillsOrigin
        let agents = SkillsList.assignments(session.agentRecords.items)[skill.id] ?? []
        let creator = skill.createdBy.flatMap { id in session.memberRecords.items.first { $0.userId == id } }
        let runtime = origin.type == .runtimeLocal ? origin.runtimeID.flatMap { id in session.runtimeRecords.items.first { $0.id == id } } : nil
        return VStack(spacing: 0) {
            header(skill, canEdit: canEdit, origin: origin)
            if !canEdit {
                HStack(spacing: 8) {
                    Image(systemName: "lock")
                    Text(creator.map { "View only — only \($0.name) and workspace admins can edit this skill." }
                         ?? "View only — only the skill owner and workspace admins can edit this skill.")
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, 12)
            }
            if session.skillsSupportingDataFailed {
                SkillsBanner { Text(tr("skills", "detail.supporting_data_warning")) }
            }
            SkillsIdentityStrip(skill: skill, origin: origin, runtime: runtime, agentCount: agents.count, creator: creator)
            tabs(skill)
            if model.conflictPending && canEdit {
                SkillsBanner {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("skills", "detail.conflict_banner.title")).font(Theme.Font.caption.weight(.medium)).foregroundStyle(.primary)
                        Text(tr("skills", "detail.conflict_banner.body"))
                    }
                }
            }
            switch activeTab {
            case .overview:
                ScrollView {
                    SkillsOverviewTab(model: model, skill: skill, canEdit: canEdit, creatorName: creator?.name, agents: agents) {
                        sheet = .addToAgent
                    }
                }
            case .files:
                SkillsFilesTab(model: model, canEdit: canEdit)
            }
        }
        .overlay(alignment: .bottom) {
            if canEdit && model.dirty.isDirty {
                saveBar
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: canEdit && model.dirty.isDirty)
        .sheet(item: $sheet) { which in
            switch which {
            case .delete:
                SkillsDeleteSheet(skills: [skill.skillsSummary], agentCounts: [agents.count],
                                  successMessage: tr("skills", "detail.toast_deleted"),
                                  failureMessage: tr("skills", "detail.toast_delete_failed")) { ids in
                    nav.replace(.skills)
                    for id in ids { session.skills.remove(id) }
                }
            case .addToAgent:
                SkillsAddToAgentSheet(skills: [skill.skillsSummary])
            case .refresh:
                SkillsRefreshSheet(skill: skill.skillsSummary, origin: origin) { updated in
                    model.adopt(updated)
                }
            }
        }
    }

    private func header(_ skill: Skill, canEdit: Bool, origin: SkillsOrigin) -> some View {
        PageHeader {
            HStack(spacing: 6) {
                Button(tr("skills", "page.title")) { nav.push(.skills) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(skill.name).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
            }
            .font(Theme.Font.body)
        } trailing: {
            HStack(spacing: 8) {
                if !canEdit {
                    Label(tr("skills", "detail.read_only"), systemImage: "lock")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                if canEdit && origin.isRefreshable {
                    Button { sheet = .refresh } label: { Label(tr("skills", "detail.refresh.button"), systemImage: "arrow.clockwise") }
                        .help(tr("skills", "detail.refresh.tooltip"))
                }
                Button { sheet = .addToAgent } label: { Label(tr("skills", "actions.add_to_agent"), systemImage: "person.badge.plus") }
                if canEdit {
                    Button { sheet = .delete } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(tr("skills", "detail.delete_tooltip"))
                        .accessibilityLabel(tr("skills", "detail.delete_aria"))
                }
            }
            .controlSize(.small)
        }
    }

    private func tabs(_ skill: Skill) -> some View {
        HStack(spacing: 24) {
            tab(.overview, tr("skills", "detail.tabs.overview"))
            tab(.files, tr("skills", "detail.tabs.files", ["count": skill.skillsTotalFileCount]))
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.page)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityLabel(tr("skills", "detail.tabs.aria"))
    }

    private func tab(_ id: SkillsDetailTab, _ title: String) -> some View {
        let active = activeTab == id
        return Button {
            nav.setQuery("view", id == .overview ? nil : id.rawValue)
        } label: {
            Text(title)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(active ? .primary : .secondary)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if active { Rectangle().fill(Color.primary).frame(height: 2) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var saveBar: some View {
        let d = model.dirty
        let parts = [
            d.nameChanged ? tr("skills", "detail.overview.name") : nil,
            d.descriptionChanged ? tr("skills", "detail.overview.description") : nil,
            d.changedFileCount > 0 ? tr("skills", "detail.save_bar.changed_files", ["count": d.changedFileCount]) : nil,
        ].compactMap { $0 }
        return HStack(spacing: 4) {
            Text(tr("skills", "detail.save_bar.changed_summary", ["parts": parts.joined(separator: " · ")]))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .overlay(alignment: .trailing) { Divider().frame(height: 18) }
            Button(tr("skills", "detail.save_bar.discard")) { model.discard() }
                .buttonStyle(.borderless)
                .disabled(model.saving)
            Button { Task { await save() } } label: {
                SkillsBusyLabel(title: model.saving ? tr("skills", "detail.save_bar.saving") : tr("skills", "detail.save_bar.save"),
                                icon: "checkmark", busy: model.saving)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.saving || model.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private func save() async {
        guard canEdit else { return }
        do {
            let updated = try await model.save(api: session.api)
            session.skills.upsert(updated.skillsSummary)
            await session.agentRecords.refreshIfLoaded()
            toaster.success(tr("skills", "detail.toast_saved"))
        } catch {
            let message = (error as? APIError)?.message ?? error.localizedDescription
            toaster.error(message.isEmpty ? tr("skills", "detail.toast_save_failed") : message)
        }
    }

    // MARK: Loading / not found

    private var loading: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 64, height: 12)
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 160, height: 12)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                ForEach([1.0, 0.83, 0.75], id: \.self) { f in
                    GeometryReader { g in RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: g.size.width * f, height: 12) }
                        .frame(height: 12)
                }
            }
            .padding(Theme.Spacing.page)
            Spacer()
        }
    }

    private var notFound: some View {
        VStack(spacing: 0) {
            PageHeader {
                Button(tr("skills", "detail.all_skills")) { nav.push(.skills) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                Text(tr("skills", "detail.not_found.title")).font(Theme.Font.bodyMedium)
                Text(model.loadError ?? tr("skills", "detail.not_found.fallback"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
                Button(tr("skills", "detail.not_found.back")) { nav.push(.skills) }
                    .controlSize(.small)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Identity strip under the header: mark, name, and what the skill is made of.
private struct SkillsIdentityStrip: View {
    let skill: Skill
    let origin: SkillsOrigin
    let runtime: RuntimeDeviceRecord?
    let agentCount: Int
    let creator: MemberWithUserRecord?

    var body: some View {
        let originLabel = SkillsOriginStyle.detailLabel(origin, runtime: runtime)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                identity
                Spacer(minLength: 16)
                facts(originLabel)
            }
            VStack(alignment: .leading, spacing: 8) {
                identity
                facts(originLabel)
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Image(systemName: skillsIcon)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            Text(skill.name).font(.system(size: 17, weight: .semibold, design: .monospaced)).lineLimit(1).textSelection(.enabled)
        }
    }

    private func facts(_ originLabel: String) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Image(systemName: SkillsOriginStyle.icon(origin.type))
                if let link = origin.linkURL, let url = URL(string: link) {
                    Link(originLabel, destination: url).help(link)
                } else {
                    Text(originLabel)
                }
            }
            .lineLimit(1)
            Label(tr("skills", "detail.header.files", ["count": skill.skillsTotalFileCount]), systemImage: "doc.text")
            Label(tr("skills", "detail.header.used_by", ["count": agentCount]), systemImage: "person.2")
            Label(creator.map { tr("skills", "detail.header.updated_by", ["when": Formatters.relative(skill.updatedAt), "name": $0.name]) }
                  ?? tr("skills", "detail.header.updated", ["when": Formatters.relative(skill.updatedAt)]),
                  systemImage: "clock")
                .help(Formatters.date(skill.updatedAt, style: .complete, time: .shortened))
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

/// Overview tab: properties (name, description, labels), agents, permissions.
private struct SkillsOverviewTab: View {
    @Bindable var model: SkillsDetailModel
    let skill: Skill
    let canEdit: Bool
    let creatorName: String?
    let agents: [AgentRecord]
    let onAddToAgents: () -> Void
    @State private var helpOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("skills", "detail.overview.properties")).font(Theme.Font.title)
            DisclosureGroup(isExpanded: $helpOpen) {
                Text(tr("skills", "detail.overview.properties_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text(tr("skills", "detail.overview.properties_help")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            VStack(spacing: 0) {
                property(tr("skills", "detail.overview.name")) {
                    if canEdit {
                        TextField(tr("skills", "detail.name_placeholder"), text: $model.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                    } else {
                        readOnlyField(model.name, mono: true)
                    }
                }
                Divider()
                property(tr("skills", "detail.overview.description")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if canEdit {
                            SkillsTextArea(text: $model.descriptionText, placeholder: tr("skills", "detail.description_placeholder"), minHeight: 120)
                        } else {
                            readOnlyField(model.descriptionText, mono: false).frame(minHeight: 120, alignment: .topLeading)
                        }
                        HStack(alignment: .top) {
                            Text(tr("skills", "detail.overview.description_hint"))
                            Spacer(minLength: 16)
                            Text(tr("skills", "detail.overview.character_count", ["count": model.descriptionText.count])).monospacedDigit()
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Divider()
                property(tr("skills", "detail.overview.labels")) {
                    SkillsResourceLabelPicker(skillID: skill.id, canEdit: canEdit)
                }
            }
            .padding(.top, 16)

            HStack {
                Text(tr("skills", "detail.overview.used_by", ["count": agents.count])).font(Theme.Font.title)
                Spacer()
                Button(action: onAddToAgents) { Label(tr("skills", "actions.add_to_agent"), systemImage: "person.badge.plus") }
                    .controlSize(.small)
            }
            .padding(.top, 40)
            Group {
                if agents.isEmpty {
                    Text(tr("skills", "detail.overview.used_by_empty"))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 12)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                            if i > 0 { Divider() }
                            HStack(spacing: 10) {
                                SkillsAgentAvatar(agent: agent, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(agent.name).font(Theme.Font.bodyMedium).lineLimit(1)
                                    if !agent.description.isEmpty {
                                        Text(agent.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                }
            }
            .padding(.top, 12)

            Text(canEdit ? tr("skills", "detail.overview.permissions_owner")
                 : creatorName.map { tr("skills", "detail.overview.permissions_locked_creator", ["name": $0]) } ?? tr("skills", "detail.overview.permissions_locked"))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.05)))
                .padding(.top, 40)
        }
        .frame(maxWidth: 768, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, 28)
        .padding(.bottom, 96)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func property<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).font(Theme.Font.body).foregroundStyle(.secondary).frame(width: 128, alignment: .leading).padding(.top, 5)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private func readOnlyField(_ text: String, mono: Bool) -> some View {
        Text(text)
            .font(mono ? .system(size: 13, design: .monospaced) : Theme.Font.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }
}
