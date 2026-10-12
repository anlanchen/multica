import MulticaCore
import SwiftUI

/// Footer bar shared by the confirmation dialogs (`border-t bg-muted/25`).
private struct RuntimesDialogFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct RuntimesNotice: View {
    let text: String
    var icon = "info.circle"
    var tint: Color = Theme.warning
    var foreground: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true).foregroundStyle(foreground)
        }
        .font(Theme.Font.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.4)))
    }
}

// MARK: Rename machine

/// Names a whole machine: the name is applied to every runtime on the
/// daemon; clearing reverts to the device's default name.
struct RuntimesRenameMachineDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let runtimeID: String
    let currentName: String
    @State private var value = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "machine.rename_dialog.title")).font(Theme.Font.title)
                Text(tr("runtimes", "machine.rename_dialog.description")).font(Theme.Font.body).foregroundStyle(.secondary)
                TextField(tr("runtimes", "machine.rename_dialog.placeholder"), text: $value)
                    .textFieldStyle(.roundedBorder)
                    .padding(.top, 8)
                    .onChange(of: value) { if value.count > 100 { value = String(value.prefix(100)) } }
                    .onSubmit { if !submitting { Task { await save() } } }
                Text(tr("runtimes", "machine.rename_dialog.hint")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(20)
            RuntimesDialogFooter {
                Button(tr("runtimes", "machine.rename_dialog.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(tr("runtimes", submitting ? "machine.rename_dialog.saving" : "machine.rename_dialog.save")) { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting)
            }
        }
        .frame(width: 440)
        .interactiveDismissDisabled(submitting)
        .onAppear { value = currentName }
    }

    private func save() async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        defer { submitting = false }
        do {
            _ = try await session.api.updateRuntime(runtimeID, customName: trimmed, applyToMachine: true)
            toaster.success(tr("runtimes", trimmed.isEmpty ? "machine.rename_dialog.toast_cleared" : "machine.rename_dialog.toast_saved"))
            await session.runtimeRecords.load()
            dismiss()
        } catch {
            let message = (error as? APIError)?.message ?? ""
            toaster.error(message.isEmpty ? tr("runtimes", "machine.rename_dialog.toast_failed") : message)
        }
    }
}

// MARK: Delete runtime

/// Runtime deletion: a short confirm when nothing is bound, a cascade plan
/// (unbind agents, cancel runs) otherwise. A structured 409 swaps in the
/// server's authoritative plan and requires a fresh confirmation.
struct RuntimesDeleteRuntimeDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let runtime: RuntimeDeviceRecord
    let onDeleted: () -> Void
    @State private var plan: [AgentRecord] = []
    @State private var confirmed = false
    @State private var submitting = false
    @State private var notice: String?

    var body: some View {
        let cascade = !plan.isEmpty
        let name = RuntimesKit.displayLabel(runtime)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cascade ? tr("runtimes", "detail.delete_dialog.cascade.title", ["count": plan.count]) : tr("runtimes", "detail.delete_dialog.light.title"))
                        .font(Theme.Font.title)
                    Text(tr("runtimes", cascade ? "detail.delete_dialog.cascade.description" : "detail.delete_dialog.light.description", ["name": name]))
                        .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !(runtime.profileId ?? "").isEmpty {
                    RuntimesNotice(text: tr("runtimes", "detail.delete_dialog.profile_backed_notice"))
                } else if RuntimesKit.isSelfHealing(runtime) {
                    RuntimesNotice(text: tr("runtimes", "detail.delete_dialog.self_heal_notice"))
                }
                if cascade {
                    RuntimesNotice(text: tr("runtimes", "detail.delete_dialog.cascade.warning"), icon: "exclamationmark.triangle",
                                   tint: Theme.destructive, foreground: Theme.destructive)
                    if let notice {
                        Text(notice).font(Theme.Font.caption)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    }
                    RuntimesAgentPlanTable(agents: plan, runtime: runtime)
                }
            }
            .padding(20)
            VStack(alignment: .leading, spacing: 12) {
                if cascade {
                    Toggle(isOn: $confirmed) {
                        Text(tr("runtimes", "detail.delete_dialog.cascade.checkbox", ["count": plan.count])).fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(submitting)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button(tr("runtimes", cascade ? "detail.delete_dialog.cascade.cancel" : "detail.delete_dialog.light.cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(submitting)
                    Button(role: .destructive) { Task { await confirm() } } label: {
                        Text(submitting
                             ? tr("runtimes", cascade ? "detail.delete_dialog.cascade.submitting" : "detail.delete_dialog.light.submitting")
                             : cascade ? tr("runtimes", "detail.delete_dialog.cascade.confirm", ["count": plan.count]) : tr("runtimes", "detail.delete_dialog.light.confirm"))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.destructive)
                    .disabled(submitting || (cascade && !confirmed))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, cascade ? 16 : 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: cascade ? 640 : 440)
        .interactiveDismissDisabled(submitting)
        .onAppear {
            plan = session.agentRecords.items.filter { $0.runtimeId == runtime.id && $0.archivedAt == nil }
        }
    }

    private func confirm() async {
        submitting = true
        notice = nil
        defer { submitting = false }
        do {
            if plan.isEmpty {
                do {
                    try await session.api.deleteRuntime(runtime.id)
                } catch {
                    if let conflict = RuntimesConflict.runtimeDelete(error), conflict.code == .hasActiveAgents {
                        plan = conflict.agents
                        confirmed = false
                        notice = tr("runtimes", "detail.delete_dialog.cascade.notice_runtime_has_active_agents")
                        return
                    }
                    throw error
                }
            } else {
                _ = try await session.api.unbindAgentsAndDeleteRuntime(runtime.id, expectedActiveAgentIds: plan.map(\.id))
            }
            await finish()
        } catch {
            if let conflict = RuntimesConflict.runtimeDelete(error), conflict.code == .planChanged {
                plan = conflict.agents
                confirmed = false
                notice = tr("runtimes", "detail.delete_dialog.cascade.notice_runtime_delete_plan_changed")
                return
            }
            let message = (error as? APIError)?.message ?? ""
            toaster.error(message.isEmpty ? tr("runtimes", "detail.delete_dialog.cascade.delete_failed_toast") : message)
        }
    }

    private func finish() async {
        session.runtimeRecords.remove(runtime.id)
        session.runtimesStore.invalidateUsage()
        onDeleted()
        dismiss()
        Task {
            await session.runtimeRecords.load()
            await session.agentRecords.load()
            await session.runtimesStore.loadTasks()
        }
    }
}

private struct RuntimesAgentPlanTable: View {
    @Environment(WorkspaceSession.self) private var session
    let agents: [AgentRecord]
    let runtime: RuntimeDeviceRecord

    var body: some View {
        let tasks = session.runtimesStore.tasks
        VStack(spacing: 0) {
            row(header: true) {
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.header_agent"))
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.header_owner"))
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.header_status"))
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.header_visibility"))
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.header_model"))
            }
            .font(.system(size: 10))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.04))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(agents) { agent in
                        let owner = agent.ownerId.flatMap { id in session.memberRecords.items.first { $0.userId == id } }
                        row(header: false) {
                            HStack(spacing: 8) {
                                ActorAvatar(type: "agent", id: agent.id, size: 18)
                                Text(agent.name).fontWeight(.medium).lineLimit(1)
                            }
                            HStack(spacing: 6) {
                                if let owner { ActorAvatar(type: "member", id: owner.userId, size: 18) }
                                Text(owner.map { $0.userId == session.currentUser.id ? tr("runtimes", "detail.delete_dialog.cascade.table.owner_self") : $0.name }
                                     ?? tr("runtimes", "detail.delete_dialog.cascade.table.owner_unassigned"))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            RuntimesPlanPresence(presence: RuntimesPresence(runtime: runtime, tasks: tasks.filter { $0.agentID == agent.id }))
                            if agent.visibility == "public" || agent.visibility == "workspace" {
                                Label(tr("runtimes", "detail.delete_dialog.cascade.table.visibility_workspace"), systemImage: "globe").foregroundStyle(.secondary)
                            } else {
                                Label(tr("runtimes", "detail.delete_dialog.cascade.table.visibility_private"), systemImage: "lock").foregroundStyle(.secondary)
                            }
                            Text(agent.model.isEmpty ? tr("runtimes", "detail.delete_dialog.cascade.table.model_unset") : agent.model)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .font(Theme.Font.caption)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row<C: View>(header: Bool, @ViewBuilder _ cells: () -> C) -> some View {
        RuntimesPlanRowLayout { cells() }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// Five proportional columns (1.6 : 1 : 1.2 : 0.8 : 1).
private struct RuntimesPlanRowLayout: Layout {
    static let weights: [CGFloat] = [1.6, 1, 1.2, 0.8, 1]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width / 5, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let gap: CGFloat = 12
        let total = Self.weights.reduce(0, +)
        let usable = bounds.width - gap * CGFloat(max(0, subviews.count - 1))
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            let w = usable * (i < Self.weights.count ? Self.weights[i] : 1) / total
            sub.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + gap
        }
    }
}

private struct RuntimesPlanPresence: View {
    let presence: RuntimesPresence

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(presence.availability == .offline ? Color.secondary.opacity(0.4) : presence.availabilityColor).frame(width: 6, height: 6)
            switch presence.workload {
            case .idle:
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.workload_idle")).foregroundStyle(presence.availabilityColor)
            case .working:
                ProgressView().controlSize(.mini)
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.workload_working")).foregroundStyle(presence.availabilityColor)
                Text(presence.queued > 0 ? "\(presence.running) +\(presence.queued)q" : "\(presence.running)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            case .queued:
                Image(systemName: "clock").foregroundStyle(Theme.warning)
                Text(tr("runtimes", "detail.delete_dialog.cascade.table.workload_queued")).foregroundStyle(presence.availabilityColor)
                Text("\(presence.queued)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

// MARK: Delete custom runtime profile

/// Deletes a custom runtime from the workspace; a 409 (agents still bound)
/// is explained inline and keeps the dialog open.
struct RuntimesDeleteProfileDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let profile: RuntimeProfile
    let onDeleted: () -> Void
    @State private var submitting = false
    @State private var boundMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "profiles.delete_dialog.title")).font(Theme.Font.title)
                Text(tr("runtimes", "profiles.delete_dialog.description", ["name": profile.displayName]))
                    .font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let boundMessage {
                    RuntimesNotice(text: boundMessage, icon: "exclamationmark.triangle").padding(.top, 8)
                }
            }
            .padding(20)
            RuntimesDialogFooter {
                Button(tr("runtimes", "profiles.delete_dialog.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button(role: .destructive) { Task { await confirm() } } label: {
                    Text(tr("runtimes", submitting ? "profiles.delete_dialog.deleting" : "profiles.delete_dialog.confirm"))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.destructive)
                .disabled(submitting)
            }
        }
        .frame(width: 440)
        .interactiveDismissDisabled(submitting)
    }

    private func confirm() async {
        submitting = true
        boundMessage = nil
        defer { submitting = false }
        do {
            try await session.api.deleteRuntimeProfile(workspaceId: session.workspace.id, profileId: profile.id)
            toaster.success(tr("runtimes", "profiles.delete_dialog.toast_deleted"))
            session.runtimesStore.profiles.remove(profile.id)
            onDeleted()
            dismiss()
            Task {
                await session.runtimesStore.profiles.load()
                await session.runtimeRecords.load()
            }
        } catch {
            if let message = RuntimesConflict.profileBound(error) {
                boundMessage = message.isEmpty ? tr("runtimes", "profiles.delete_dialog.error_bound") : message
                return
            }
            let message = (error as? APIError)?.message ?? ""
            toaster.error(message.isEmpty ? tr("runtimes", "profiles.delete_dialog.error_generic") : message)
        }
    }
}

// MARK: Custom pricing

/// Per-million-token rates for models without a maintained price. Every
/// unmapped model plus every saved override is editable here.
struct RuntimesCustomPricingDialog: View {
    @Environment(\.dismiss) private var dismiss
    let unmapped: [String]
    @State private var drafts: [String: [String]] = [:]
    @State private var rows: [String] = []

    private var pricing: RuntimesCustomPricing { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "usage.custom_pricing.title")).font(Theme.Font.title)
                Text(tr("runtimes", "usage.custom_pricing.description")).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if rows.isEmpty {
                        Text(tr("runtimes", "usage.custom_pricing.empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    ForEach(rows, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(key).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                Spacer()
                                if pricing.pricings[key] != nil {
                                    Button { pricing.remove(key) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                        .help(tr("runtimes", "usage.custom_pricing.remove_aria"))
                                }
                            }
                            HStack(spacing: 8) {
                                field(key, 0, "usage.custom_pricing.field_input")
                                field(key, 1, "usage.custom_pricing.field_output")
                                field(key, 2, "usage.custom_pricing.field_cache_read")
                                field(key, 3, "usage.custom_pricing.field_cache_write")
                            }
                        }
                        .padding(12)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    }
                    Text(tr("runtimes", "usage.custom_pricing.unit_hint")).font(Theme.Font.micro).foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button(tr("runtimes", "usage.custom_pricing.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("runtimes", "usage.custom_pricing.save")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            rows = Array(Set(unmapped).union(pricing.pricings.keys)).sorted()
            for key in rows {
                if let p = pricing.pricings[key] {
                    drafts[key] = [p.input, p.output, p.cacheRead, p.cacheWrite].map { RuntimesFormat.trimmedNumber($0) }
                } else {
                    drafts[key] = ["", "", "", ""]
                }
            }
        }
    }

    private func field(_ key: String, _ index: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("runtimes", label)).font(Theme.Font.micro).foregroundStyle(.secondary)
            TextField("0.00", text: Binding(
                get: { drafts[key]?[index] ?? "" },
                set: { drafts[key, default: ["", "", "", ""]][index] = $0 }))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        for key in rows {
            let draft = drafts[key] ?? ["", "", "", ""]
            if draft.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                pricing.remove(key)
                continue
            }
            let values = draft.map { s -> Double? in
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? 0 : Double(t)
            }
            guard values.allSatisfy({ ($0 ?? -1) >= 0 && $0!.isFinite }) else { continue }
            pricing.set(key, RuntimesModelPrice(input: values[0]!, output: values[1]!, cacheRead: values[2]!, cacheWrite: values[3]!))
        }
        dismiss()
    }
}
