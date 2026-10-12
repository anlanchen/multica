import AppKit
import MulticaCore
import SwiftUI

extension WorkspaceSession {
    /// Agents-area projections (presence snapshot, activity, discovery).
    var agentsUIStore: AgentsUIStore { AgentsUIStore.shared(for: self) }

    /// The signed-in member's workspace role, nil until members load.
    var agentsUIRole: String? { directory.member(userID: currentUser.id)?.role }

    var agentsUIMembersLoaded: Bool { !directory.members.isEmpty }

    var agentsUIIsAdmin: Bool { AgentsUI.isAdminLike(agentsUIRole) }

    /// Keeps the agent/runtime catalogs and task projections in step with
    /// realtime; call from `.task(id:)` on the agents screens.
    func agentsUISync() {
        agentsUIStore.sync(task: revision("task"), agent: revision("agent"), runtime: revision("runtime"), daemon: revision("daemon"))
    }

    var agentsUISyncKey: [Int] { [revision("task"), revision("agent"), revision("runtime"), revision("daemon")] }
}

/// Transliteration used by list search (pinyin for CJK names), cached.
@MainActor
enum AgentsUILatin {
    private static var cache: [String: String] = [:]

    static func latin(_ s: String) -> String {
        if let hit = cache[s] { return hit }
        let needs = s.unicodeScalars.contains { $0.value >= 0x2E80 }
        let out = needs ? (s.applyingTransform(.mandarinToLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s) : s
        if cache.count > 2000 { cache.removeAll() }
        cache[s] = out
        return out
    }
}

// MARK: - Avatars

/// Agent avatar: uploaded image, `emoji:` avatar, or the robot fallback.
struct AgentsUIAvatar: View {
    let name: String
    let avatarURL: String?
    var size: CGFloat = 20
    var archived = false

    var body: some View {
        Group {
            if let emoji = AgentsUIAvatar.emoji(avatarURL) {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.purple.opacity(0.12))
                    Text(emoji).font(.system(size: size * 0.6))
                }
                .frame(width: size, height: size)
            } else {
                AvatarView(name: name, url: avatarURL, kind: .agent, size: size)
            }
        }
        .opacity(archived ? 0.5 : 1)
        .saturation(archived ? 0 : 1)
    }

    static func emoji(_ value: String?) -> String? {
        guard let value, value.hasPrefix("emoji:") else { return nil }
        let e = value.dropFirst(6).trimmingCharacters(in: .whitespaces)
        return e.isEmpty ? nil : e
    }
}

/// Avatar with an optional availability dot in the corner.
struct AgentsUIAgentAvatar: View {
    @Environment(WorkspaceSession.self) private var session
    let agentID: String
    var size: CGFloat = 20
    var availability: AgentsUI.Availability? = nil

    var body: some View {
        let record = session.agentRecords.item(agentID)
        let info = session.actorInfo(type: "agent", id: agentID)
        AgentsUIAvatar(name: record?.name ?? info.name, avatarURL: record?.avatarUrl ?? info.avatarURL, size: size,
                       archived: record?.archivedAt != nil)
            .overlay(alignment: .bottomTrailing) {
                if let availability {
                    Circle().fill(availability.dotColor)
                        .frame(width: max(6, size * 0.26), height: max(6, size * 0.26))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
    }
}

// MARK: - Presence

extension AgentsUI.Availability {
    var dotColor: Color {
        switch self {
        case .online: return Theme.success
        case .unstable: return Theme.warning
        case .offline, .archived: return Color.secondary.opacity(0.4)
        }
    }

    var textColor: Color {
        switch self {
        case .online: return Theme.success
        case .unstable: return Theme.warning
        case .offline, .archived: return .secondary
        }
    }

    var label: String { tr("agents", "availability.\(rawValue)") }
}

/// Availability dot + label, plus the workload chip (upstream
/// AgentPresenceIndicator).
struct AgentsUIPresenceIndicator: View {
    let presence: AgentsUI.Presence?
    var compact = false

    var body: some View {
        if let p = presence {
            if compact {
                Circle().fill(p.availability.dotColor).frame(width: 6, height: 6)
                    .help(p.availability.label + (p.workload != .idle ? " · " + tr("agents", "workload.\(p.workload.rawValue)") : ""))
            } else {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Circle().fill(p.availability.dotColor).frame(width: 6, height: 6)
                        Text(p.availability.label).foregroundStyle(p.availability.textColor)
                    }
                    if p.availability != .archived {
                        Text("·").foregroundStyle(.secondary)
                        Text(tr("agents", "workload.\(p.workload.rawValue)")).foregroundStyle(workloadColor(p))
                        if p.workload == .working {
                            Text("\(p.runningCount) / \(p.capacity)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            if p.queuedCount > 0 {
                                Text(tr("agents", "presence.queue_badge", ["count": p.queuedCount]))
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                            }
                        }
                        if p.workload == .queued {
                            Text("\(p.queuedCount)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(Theme.Font.caption)
            }
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)).frame(width: compact ? 6 : 90, height: compact ? 6 : 10)
        }
    }

    private func workloadColor(_ p: AgentsUI.Presence) -> Color {
        switch p.workload {
        case .working: return Theme.brand
        case .queued: return p.availability == .online ? .secondary : Theme.warning
        case .idle: return .secondary
        }
    }
}

/// Read-only Personal / Workspace badge with tooltip.
struct AgentsUIVisibilityBadge: View {
    let visibility: String
    var compact = false

    var body: some View {
        let key = visibility == "private" ? "private" : "workspace"
        HStack(spacing: 4) {
            Image(systemName: key == "private" ? "lock" : "globe").font(.system(size: 10))
            if !compact { Text(tr("agents", "visibility.\(key).label")).lineLimit(1) }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .help(tr("agents", "visibility.\(key).tooltip"))
    }
}

/// "n / max" with warn at 90% and error past the cap.
struct AgentsUICharCounter: View {
    let length: Int
    let max: Int

    var body: some View {
        let over = length > max
        let near = !over && length >= Int(Double(max) * 0.9)
        Text("\(length) / \(max)" + (over ? tr("agents", "char_counter.over_limit", ["count": length - max]) : ""))
            .font(Theme.Font.caption.monospacedDigit())
            .foregroundStyle(over ? Theme.destructive : (near ? Theme.warning : .secondary))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Provider mark: a tinted rounded square with the provider's initial (the
/// upstream SVG logos are not bundled).
struct AgentsUIProviderLogo: View {
    let provider: String
    var size: CGFloat = 14

    var body: some View {
        let palette: [Color] = [.orange, .green, .blue, .purple, .pink, .teal, .indigo, .brown, .cyan]
        let sum = provider.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let color = palette[sum % palette.count]
        Text(String(AgentsUI.providerDisplayName(provider).prefix(1)))
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25).fill(color.opacity(0.16)))
            .help(AgentsUI.providerDisplayName(provider))
    }
}

/// Small online/offline dot for a runtime.
struct AgentsUIRuntimeDot: View {
    let online: Bool
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(online ? Theme.success : Color.secondary.opacity(0.4)).frame(width: size, height: size)
    }
}

// MARK: - Settings layout

/// Section header + content (upstream SettingsSection).
struct AgentsUISettingsSection<Content: View, Action: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var action: () -> Action
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.bodyMedium)
                    if let description {
                        Text(description).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                action()
            }
            content()
        }
    }
}

extension AgentsUISettingsSection where Action == EmptyView {
    init(title: String, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.action = { EmptyView() }
        self.content = content
    }
}

/// Bordered card whose direct children are separated by dividers.
struct AgentsUISettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            _VariadicView.Tree(AgentsUIDividedLayout()) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }
}

struct AgentsUIDividedLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Divider() }
        }
    }
}

/// Label on the left, control on the right (upstream SettingsRow).
struct AgentsUISettingsRow<Content: View>: View {
    let label: String
    var alignTop = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 24) {
            Text(label).font(Theme.Font.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, alignTop ? 4 : 0)
            content().frame(minWidth: 240, maxWidth: 380, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Dashed notice used for empty / discovering / unavailable states.
struct AgentsUINotice: View {
    let text: String
    var loading = false
    var icon = "server.rack"

    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// Bordered list container with dividers between rows.
struct AgentsUIListCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        AgentsUISettingsCard(content: content)
    }
}

/// Small inline field look for read-only values (disabled pickers).
struct AgentsUIFieldBox<Content: View>: View {
    var dashed = false
    var interactive = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .font(Theme.Font.body)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(interactive ? Color.clear : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : [])))
            .contentShape(Rectangle())
    }
}

/// Unsaved-changes label + Save button row used by every editable tab.
struct AgentsUISaveBar: View {
    let dirty: Bool
    var canSave = true
    let saving: Bool
    var showUnsaved: Bool? = nil
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            if showUnsaved ?? dirty {
                Text(tr("agents", "tab_body.common.unsaved_changes")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Button(action: onSave) {
                HStack(spacing: 5) {
                    if saving { ProgressView().controlSize(.mini) } else { Image(systemName: "square.and.arrow.down") }
                    Text(tr("agents", "tab_body.common.save"))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!dirty || !canSave || saving)
            .keyboardShortcut("s", modifiers: .command)
        }
    }
}

// MARK: - Sparkline

/// 30-day stacked bars: completed (brand), other (muted), failed (red).
struct AgentsUISparkline: View {
    let buckets: [AgentsUI.ActivityBucket]
    var height: CGFloat = 32

    var body: some View {
        Canvas { ctx, size in
            let n = buckets.count
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Color.secondary.opacity(0.25)))
            guard n > 0 else { return }
            let gap: CGFloat = 1
            let col = max(1, floor((size.width - gap * CGFloat(n - 1)) / CGFloat(n)))
            let used = col * CGFloat(n) + gap * CGFloat(n - 1)
            let offset = floor((size.width - used) / 2)
            let maxTotal = CGFloat(max(1, buckets.map(\.total).max() ?? 1))
            let base = size.height - 1
            let usable = size.height - 1
            for (i, b) in buckets.enumerated() where b.total > 0 {
                let x = offset + CGFloat(i) * (col + gap)
                let totalH = max(1, (usable * CGFloat(b.total) / maxTotal).rounded())
                let failedH = b.failed > 0 ? min(totalH, max(1, (usable * CGFloat(b.failed) / maxTotal).rounded())) : 0
                let completedH = b.completed > 0 ? min(totalH - failedH, max(1, (usable * CGFloat(b.completed) / maxTotal).rounded())) : 0
                let neutralH = totalH - failedH - completedH
                let top = base - totalH
                if completedH > 0 {
                    ctx.fill(Path(CGRect(x: x, y: top + failedH + neutralH, width: col, height: completedH)), with: .color(Theme.brand.opacity(0.6)))
                }
                if neutralH > 0 {
                    ctx.fill(Path(CGRect(x: x, y: top + failedH, width: col, height: neutralH)), with: .color(Color.secondary.opacity(0.6)))
                }
                if failedH > 0 {
                    ctx.fill(Path(CGRect(x: x, y: top, width: col, height: failedH)), with: .color(Theme.destructive))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Profile card

/// Hover card for an agent (upstream AgentProfileCard).
struct AgentsUIProfileCard: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Navigator.self) private var nav
    let agentID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let agent = session.agentRecords.item(agentID) {
                let isArchived = agent.archivedAt != nil
                let runtime = session.runtimeRecords.item(agent.runtimeId)
                HStack(alignment: .top, spacing: 10) {
                    AgentsUIAvatar(name: agent.name, avatarURL: agent.avatarUrl, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(agent.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            if isArchived {
                                Badge(text: tr("agents", "row.archived"))
                            } else {
                                AgentsUIVisibilityBadge(visibility: agent.visibility, compact: true)
                            }
                        }
                        if !isArchived {
                            let presence = AgentsUI.presence(agent: agent, runtime: runtime,
                                                             tasks: session.agentsUIStore.snapshot.filter { $0.agentId == agent.id }, now: Date())
                            HStack(spacing: 5) {
                                Circle().fill(presence.availability.dotColor).frame(width: 6, height: 6)
                                Text(presence.availability.label).font(Theme.Font.caption).foregroundStyle(presence.availability.textColor)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if !isArchived {
                        Button(tr("agents", "profile_card.detail_link")) { nav.push(.agent(agent.id), title: agent.name) }
                            .buttonStyle(.link).font(Theme.Font.caption)
                    }
                }
                if !agent.description.isEmpty {
                    Text(agent.description).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                VStack(alignment: .leading, spacing: 5) {
                    metaRow(tr("agents", "profile_card.runtime_label")) {
                        AgentsUIRuntimeDot(online: runtime?.status == "online" || agent.runtimeMode == "cloud")
                        Text(runtime.map(AgentsUI.runtimeDisplayLabel)
                             ?? (agent.runtimeMode == "cloud" ? tr("agents", "row.fallback_runtime_cloud") : tr("agents", "profile_card.unknown_runtime")))
                            .lineLimit(1)
                    }
                    metaRow(tr("agents", "profile_card.model_label")) {
                        if agent.model.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(tr("agents", "profile_card.model_unset")).foregroundStyle(.secondary)
                        } else {
                            Text(agent.model).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
                        }
                        if let effort = agent.thinkingLevel?.trimmingCharacters(in: .whitespaces), !effort.isEmpty {
                            Badge(text: effort)
                        }
                    }
                    if !agent.skills.isEmpty {
                        metaRow(tr("agents", "profile_card.skills_label")) {
                            ForEach(agent.skills.prefix(3), id: \.id) { s in Badge(text: s.name) }
                            if agent.skills.count > 3 { Badge(text: "+\(agent.skills.count - 3)") }
                        }
                    }
                    if let owner = agent.ownerId.flatMap({ session.directory.member(userID: $0) }) {
                        metaRow(tr("agents", "profile_card.owner_label")) { Text(owner.name).lineLimit(1) }
                    }
                }
                .font(Theme.Font.caption)
            } else {
                Text(tr("agents", "profile_card.unavailable")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private func metaRow<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            content()
        }
    }
}

/// Opens the profile card after hovering for a moment.
struct AgentsUIProfileHover: ViewModifier {
    let agentID: String
    @State private var hovering = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        if hovering { shown = true }
                    }
                }
            }
            .popover(isPresented: $shown, arrowEdge: .trailing) { AgentsUIProfileCard(agentID: agentID) }
    }
}

extension View {
    func agentsUIProfileHover(_ agentID: String) -> some View { modifier(AgentsUIProfileHover(agentID: agentID)) }
}

// MARK: - Task status

extension AgentTaskRecord {
    /// Localized status word (upstream `taskStatusLabel`).
    var agentsUIStatusLabel: String {
        switch status {
        case "queued", "deferred": return tr("agents", "tab_body.activity.status.queued")
        case "dispatched", "waiting_local_directory", "running", "completed", "failed", "cancelled":
            return tr("agents", "tab_body.activity.status.\(status)")
        default: return status.capitalized
        }
    }

    var agentsUIStatusIcon: (String, Color) {
        switch status {
        case "dispatched": return ("play.circle", Theme.info)
        case "running": return ("arrow.triangle.2.circlepath", Theme.brand)
        case "completed": return ("checkmark.circle", Theme.success)
        case "failed": return ("xmark.circle", Theme.destructive)
        case "cancelled": return ("xmark.circle", .secondary)
        default: return ("clock", .secondary)
        }
    }

    /// The localized outcome reason (failure, or a server cancel reason).
    var agentsUIFailureLabel: String? {
        func label(_ reason: String?) -> String? {
            switch AgentsUI.failureLabel(reason) {
            case .key(let k)?: return tr("agents", "task_failure.reasons.\(k)")
            case .raw(let r)?: return r
            case nil: return nil
            }
        }
        if status == "failed" { return label(failureReason) }
        guard status == "cancelled" else { return nil }
        if let r = label(failureReason) { return r }
        return (error?.isEmpty == false && cancelledBy == nil) ? tr("agents", "task_failure.cancelled_by_system") : nil
    }

    /// "Cancelled by Alice" / "Cancelled by the system", else nil.
    var agentsUICancellationLabel: String? {
        guard status == "cancelled", let by = cancelledBy else { return nil }
        switch by.type {
        case "system": return tr("agents", "task_failure.cancelled_by_system")
        case "member", "agent":
            let name = by.name?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : tr("agents", "task_failure.cancelled_by_actor", ["name": name])
        default: return nil
        }
    }

    /// The hand-written task model for the shared transcript sheet.
    var agentsUITask: AgentTask {
        var t = AgentTask(id: id, agentID: agentId, issueID: issueId, status: TaskStatus(rawValue: status), createdAt: createdAt)
        t.runtimeID = runtimeId
        t.startedAt = startedAt
        t.completedAt = completedAt
        t.dispatchedAt = dispatchedAt
        t.error = error
        t.failureReason = failureReason
        t.chatSessionID = chatSessionId
        return t
    }
}
