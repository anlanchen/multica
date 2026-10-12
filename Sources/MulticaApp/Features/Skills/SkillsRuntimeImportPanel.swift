import MulticaCore
import SwiftUI

/// State machine of the runtime import panel (upstream
/// RuntimeLocalSkillImportPanel): idle → importing → resolving/done.
@MainActor
@Observable
final class SkillsRuntimeImportModel {
    enum Phase: Equatable { case idle, importing, resolving, done, cancelled }
    enum Status: Equatable { case created, updated, conflict, skipped, failed }

    struct Result: Identifiable, Equatable {
        var key: String
        var name: String
        var description: String?
        var status: Status
        var conflict: RuntimeLocalSkillImportConflict?
        var error: String?
        var skill: Skill?
        var id: String { key }
    }

    enum Inventory: Equatable {
        case unloaded, loading, loaded(SkillsLocalInventory), failed(String)
    }

    /// Upstream IMPORT_CONCURRENCY; bounded by the server's pending timeout.
    static let concurrency = 10

    var runtimeID = "" {
        didSet {
            guard runtimeID != oldValue else { return }
            resetSelection()
            Task { await loadInventory() }
        }
    }
    var inventory: Inventory = .unloaded
    var selected: Set<String> = []
    var query = ""
    var editName = ""
    var editDescription = ""
    var phase: Phase = .idle
    var total = 0
    var completed = 0
    var selectedCount = 0
    var results: [Result] = []
    var resolutions: [String: SkillsConflictResolution] = [:]
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored let session: WorkspaceSession

    init(session: WorkspaceSession) {
        self.session = session
    }

    var localRuntimes: [RuntimeDeviceRecord] {
        session.runtimeRecords.items.filter { $0.runtimeMode == "local" && $0.ownerId == session.currentUser.id }
    }

    var selectedRuntime: RuntimeDeviceRecord? { localRuntimes.first { $0.id == runtimeID } }

    var skills: [RuntimeLocalSkillSummary] {
        if case .loaded(let inv) = inventory { return inv.skills }
        return []
    }

    var filtered: [RuntimeLocalSkillSummary] {
        if case .loaded(let inv) = inventory { return inv.filtered(query) }
        return []
    }

    var singleSelected: RuntimeLocalSkillSummary? {
        selected.count == 1 ? skills.first { selected.contains($0.key) } : nil
    }

    var pendingConflicts: [Result] { results.filter { $0.status == .conflict && $0.conflict != nil } }

    var canApplyResolutions: Bool {
        let pending = pendingConflicts
        return !pending.isEmpty && pending.allSatisfy { r in
            resolutions[r.key]?.isApplicable(canOverwrite: r.conflict?.canOverwrite ?? false) ?? false
        }
    }

    var canImport: Bool {
        selectedRuntime?.status == "online" && !selected.isEmpty
            && (selected.count > 1 || !editName.trimmingCharacters(in: .whitespaces).isEmpty)
            && phase != .importing && phase != .resolving
    }

    func ensureRuntime() {
        if runtimeID.isEmpty, let first = localRuntimes.first { runtimeID = first.id }
    }

    private func resetSelection() {
        selected = []
        phase = .idle
        results = []
        resolutions = [:]
        query = ""
        editName = ""
        editDescription = ""
        inventory = .unloaded
    }

    func loadInventory() async {
        guard let runtime = selectedRuntime, runtime.status == "online" else {
            inventory = .unloaded
            return
        }
        let id = runtime.id
        if let cached = session.skillsStore.cachedInventory(id) {
            inventory = .loaded(cached)
            return
        }
        inventory = .loading
        do {
            let inv = try await session.skillsStore.inventory(id)
            if runtimeID == id { inventory = .loaded(inv) }
        } catch {
            if runtimeID == id { inventory = .failed((error as? APIError)?.message ?? (error as? SkillsError)?.message ?? error.localizedDescription) }
        }
    }

    // MARK: Selection

    private func seedEditFields() {
        if selected.count == 1, let only = skills.first(where: { selected.contains($0.key) }) {
            editName = only.name
            editDescription = only.description ?? ""
        }
    }

    func toggle(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
        seedEditFields()
    }

    var allVisibleSelected: Bool {
        let visible = filtered
        return !visible.isEmpty && visible.allSatisfy { selected.contains($0.key) }
    }

    var someVisibleSelected: Bool {
        filtered.contains { selected.contains($0.key) } && !allVisibleSelected
    }

    func toggleAll() {
        let keys = filtered.map(\.key)
        if allVisibleSelected { selected.subtract(keys) } else { selected.formUnion(keys) }
        seedEditFields()
    }

    // MARK: Import

    private func record(_ result: Result) {
        results.append(result)
        completed += 1
    }

    func bulkImport() async {
        guard !runtimeID.isEmpty, !selected.isEmpty else { return }
        let runtimeID = self.runtimeID
        let toImport = skills.filter { selected.contains($0.key) }
        let single = toImport.count == 1
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelled = false
        phase = .importing
        total = toImport.count
        completed = 0
        selectedCount = toImport.count
        results = []
        let api = session.api
        let failedText = tr("skills", "runtime_import.toast_import_failed")

        await withTaskGroup(of: Result.self) { group in
            var iterator = toImport.makeIterator()
            func schedule(_ skill: RuntimeLocalSkillSummary) {
                let importName = single ? (name.isEmpty ? skill.name : name) : skill.name
                let importDescription: String? = single ? (description.isEmpty ? skill.description : description) : skill.description
                let desc = importDescription.flatMap { $0.isEmpty ? nil : $0 }
                group.addTask {
                    do {
                        let outcome = try await api.skillsImportLocalSkill(
                            runtimeID: runtimeID,
                            CreateRuntimeLocalSkillImportRequest(skillKey: skill.key, name: importName, description: desc, supportsConflict: true)
                        )
                        switch outcome {
                        case .conflict(let c): return Result(key: skill.key, name: importName, description: desc, status: .conflict, conflict: c)
                        case .created(let s): return Result(key: skill.key, name: s.name.isEmpty ? importName : s.name, description: desc, status: .created, skill: s)
                        case .updated(let s): return Result(key: skill.key, name: s.name.isEmpty ? importName : s.name, description: desc, status: .updated, skill: s)
                        }
                    } catch {
                        let message = (error as? APIError)?.message ?? (error as? SkillsError)?.message ?? error.localizedDescription
                        return Result(key: skill.key, name: skill.name, description: desc,
                                      status: SkillsErrors.isNameConflict(message) ? .skipped : .failed,
                                      error: message.isEmpty ? failedText : message)
                    }
                }
            }
            for _ in 0..<Self.concurrency {
                guard let next = iterator.next() else { break }
                schedule(next)
            }
            while let result = await group.next() {
                record(result)
                if !cancelled, let next = iterator.next() { schedule(next) }
            }
        }

        await refreshAfterImport()
        if !cancelled && results.contains(where: { $0.status == .conflict }) {
            seedResolutions()
            phase = .resolving
        } else {
            phase = cancelled ? .cancelled : .done
        }
    }

    func cancel() { cancelled = true }

    private func seedResolutions() {
        var next: [String: SkillsConflictResolution] = [:]
        for r in results where r.status == .conflict {
            if let c = r.conflict { next[r.key] = .initial(name: r.name, canOverwrite: c.canOverwrite) }
        }
        resolutions = next
    }

    func overwriteAll() {
        for r in pendingConflicts where r.conflict?.canOverwrite == true {
            resolutions[r.key] = SkillsConflictResolution(action: .overwrite, renameName: resolutions[r.key]?.renameName ?? SkillsConflictResolution.defaultRename(r.name))
        }
    }

    func skipAll() {
        for r in pendingConflicts {
            resolutions[r.key] = SkillsConflictResolution(action: .skip, renameName: resolutions[r.key]?.renameName ?? SkillsConflictResolution.defaultRename(r.name))
        }
    }

    private func update(_ key: String, _ change: (inout Result) -> Void) {
        guard let i = results.firstIndex(where: { $0.key == key }) else { return }
        change(&results[i])
    }

    func applyResolutions(overrides: [String: SkillsConflictResolution] = [:]) async {
        let conflicts = pendingConflicts
        guard !runtimeID.isEmpty, !conflicts.isEmpty else { return }
        let runtimeID = self.runtimeID
        phase = .importing
        total = conflicts.count
        completed = 0
        for r in conflicts {
            defer { completed += 1 }
            guard let resolution = overrides[r.key] ?? resolutions[r.key] else {
                update(r.key) { $0.status = .failed; $0.error = tr("skills", "runtime_import.conflict_missing_resolution") }
                continue
            }
            if resolution.action == .skip {
                update(r.key) { $0.status = .skipped; $0.error = nil }
                continue
            }
            let name = resolution.action == .rename ? resolution.renameName.trimmingCharacters(in: .whitespacesAndNewlines) : r.name
            var request = CreateRuntimeLocalSkillImportRequest(skillKey: r.key, name: name, description: r.description, supportsConflict: true)
            if resolution.action == .overwrite, let c = r.conflict {
                request.action = "overwrite"
                request.targetSkillId = c.existingSkillId
            }
            do {
                switch try await session.api.skillsImportLocalSkill(runtimeID: runtimeID, request) {
                case .conflict(let c):
                    update(r.key) {
                        $0.name = name
                        $0.status = .conflict
                        $0.conflict = c
                        $0.error = tr("skills", "runtime_import.conflict_name_still_exists")
                    }
                    resolutions[r.key] = .initial(name: name, canOverwrite: c.canOverwrite)
                case .created(let s), .updated(let s):
                    let status: Status = request.action == "overwrite" ? .updated : .created
                    update(r.key) {
                        $0.name = s.name.isEmpty ? r.name : s.name
                        $0.status = status
                        $0.skill = s
                        $0.conflict = nil
                        $0.error = nil
                    }
                }
            } catch {
                let message = (error as? APIError)?.message ?? (error as? SkillsError)?.message ?? error.localizedDescription
                update(r.key) { $0.status = .failed; $0.error = message.isEmpty ? tr("skills", "runtime_import.toast_import_failed") : message }
            }
        }
        await refreshAfterImport()
        phase = results.contains { $0.status == .conflict } ? .resolving : .done
    }

    private func refreshAfterImport() async {
        session.skillsStore.invalidateInventory(runtimeID)
        for r in results where r.status == .created || r.status == .updated {
            if let s = r.skill { session.skills.upsert(s.skillsSummary) }
        }
        await session.skills.load()
        await session.agentRecords.refreshIfLoaded()
    }

    /// Single import → open the new skill; otherwise just close.
    var singleImported: Skill? {
        let succeeded = results.filter { $0.status == .created || $0.status == .updated }
        guard selectedCount == 1, succeeded.count == 1 else { return nil }
        return succeeded.first?.skill
    }
}

struct SkillsRuntimeImportPanel: View {
    @Environment(WorkspaceSession.self) private var session
    let onImported: (Skill) -> Void
    let onBulkDone: () -> Void
    @State private var model: SkillsRuntimeImportModel?

    var body: some View {
        Group {
            if let model {
                SkillsRuntimeImportContent(model: model, onImported: onImported, onBulkDone: onBulkDone)
            } else {
                Color.clear
            }
        }
        .task {
            if model == nil { model = SkillsRuntimeImportModel(session: session) }
            await session.runtimeRecords.loadIfNeeded()
            model?.ensureRuntime()
        }
    }
}

private struct SkillsRuntimeImportContent: View {
    @Environment(WorkspaceSession.self) private var session
    @Bindable var model: SkillsRuntimeImportModel
    let onImported: (Skill) -> Void
    let onBulkDone: () -> Void

    var body: some View {
        let busy = model.phase == .importing || model.phase == .resolving
        VStack(spacing: 0) {
            picker
                .disabled(busy)
                .opacity(busy ? 0.6 : 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    middle
                    if model.phase == .idle {
                        Text(tr("skills", "runtime_import.ignored_files_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(model.phase)
                .transition(.opacity)
            }
            .animation(.easeOut(duration: 0.18), value: model.phase)
            footer
        }
        .onChange(of: session.runtimeRecords.items) {
            model.ensureRuntime()
            if model.inventory == .unloaded { Task { await model.loadInventory() } }
        }
    }

    // MARK: Runtime picker

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("skills", "runtime_import.runtime_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
            let machines = SkillsRuntimeLabels.machines(model.localRuntimes)
            Menu {
                ForEach(machines) { machine in
                    Section(machine.title) {
                        ForEach(machine.runtimes, id: \.id) { r in
                            Button(SkillsRuntimeLabels.rowLabel(r, machineTitle: machine.title)) { model.runtimeID = r.id }
                        }
                    }
                }
            } label: {
                HStack {
                    if let r = model.selectedRuntime {
                        Image(systemName: "cpu")
                        Text(SkillsRuntimeLabels.displayLabel(r)).lineLimit(1)
                    } else {
                        Text(tr("skills", "runtime_import.runtime_placeholder")).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .menuStyle(.button)
            .frame(maxWidth: .infinity)
            if let r = model.selectedRuntime {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                    Text(SkillsRuntimeLabels.displayLabel(r)).lineLimit(1)
                    Spacer()
                    Badge(text: r.status, color: r.status == "online" ? Theme.success : .secondary)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Middle

    @ViewBuilder private var middle: some View {
        switch model.phase {
        case .importing:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(tr("skills", "runtime_import.bulk_progress", ["completed": model.completed, "total": model.total])).font(Theme.Font.bodyMedium)
                ProgressView(value: Double(model.completed), total: Double(max(model.total, 1)))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.results) { r in
                        HStack(spacing: 8) {
                            SkillsResultIcon(status: r.status)
                            Text(r.name).lineLimit(1)
                        }
                        .font(Theme.Font.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        case .done, .cancelled:
            SkillsImportSummary(results: model.results)
        case .resolving:
            SkillsConflictPanel(model: model)
        case .idle:
            idle
        }
    }

    @ViewBuilder private var idle: some View {
        if model.localRuntimes.isEmpty {
            dashed(tr("skills", "runtime_import.no_local_runtimes_title"), hint: tr("skills", "runtime_import.no_local_runtimes_hint"))
        } else if let runtime = model.selectedRuntime {
            if runtime.status != "online" {
                SkillsNotice(text: tr("skills", "runtime_import.must_be_online"), icon: "exclamationmark.circle")
            } else {
                switch model.inventory {
                case .unloaded, .loading:
                    VStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 128, height: 12)
                                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(width: 192, height: 9)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
                        }
                    }
                case .failed(let message):
                    SkillsErrorBox(message: message.isEmpty ? tr("skills", "runtime_import.load_failed") : message)
                case .loaded(let inv):
                    if !inv.supported {
                        SkillsNotice(text: tr("skills", "runtime_import.not_supported"), tone: .muted, icon: "exclamationmark.circle")
                    } else if inv.skills.isEmpty {
                        dashed(tr("skills", "runtime_import.no_skills_title"))
                    } else {
                        skillList
                    }
                }
            }
        } else {
            dashed(tr("skills", "runtime_import.choose_runtime"))
        }
    }

    private func dashed(_ title: String, hint: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text(title).font(Theme.Font.body).foregroundStyle(.secondary)
            if let hint { Text(hint).font(Theme.Font.caption).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var skillList: some View {
        let visible = model.filtered
        return VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $model.query, prompt: tr("skills", "runtime_import.search_placeholder"))
            if visible.isEmpty {
                Text(tr("skills", "runtime_import.no_search_results_hint", ["query": model.query.trimmingCharacters(in: .whitespaces)]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                Button { model.toggleAll() } label: {
                    HStack(spacing: 8) {
                        SkillsCheckbox(checked: model.allVisibleSelected, indeterminate: model.someVisibleSelected)
                        Text(tr("skills", "runtime_import.select_all", ["count": visible.count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                LazyVStack(spacing: 8) {
                    ForEach(visible, id: \.key) { skill in
                        SkillsLocalSkillRow(model: model, skill: skill)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .done, .cancelled:
                Text(model.phase == .cancelled ? tr("skills", "runtime_import.bulk_cancelled_hint") : tr("skills", "runtime_import.bulk_complete_hint"))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("skills", "runtime_import.bulk_done_button")) {
                    if let skill = model.singleImported { onImported(skill) } else { onBulkDone() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .resolving:
                Text(tr("skills", "runtime_import.conflict_footer", ["count": model.pendingConflicts.count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("skills", "runtime_import.conflict_apply_button")) { Task { await model.applyResolutions() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApplyResolutions)
            case .importing:
                Text(tr("skills", "runtime_import.bulk_progress", ["completed": model.completed, "total": model.total])).font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("skills", "runtime_import.bulk_cancel_button")) { model.cancel() }
            case .idle:
                Group {
                    if let single = model.singleSelected {
                        Text(tr("skills", "runtime_import.ready") + " ")
                            + Text(model.editName.trimmingCharacters(in: .whitespaces).isEmpty ? single.name : model.editName.trimmingCharacters(in: .whitespaces))
                            .foregroundColor(.primary).fontWeight(.medium)
                            + Text(" " + tr("skills", "runtime_import.into_workspace"))
                    } else if model.selected.count > 1 {
                        Text(tr("skills", "runtime_import.bulk_ready", ["count": model.selected.count]))
                    } else {
                        Text(tr("skills", "runtime_import.select_skill"))
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                Spacer()
                Button { Task { await model.bulkImport() } } label: {
                    Label(model.selected.count > 1 ? tr("skills", "runtime_import.bulk_import_button", ["count": model.selected.count])
                                                   : tr("skills", "runtime_import.import_button"),
                          systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canImport)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct SkillsLocalSkillRow: View {
    @Bindable var model: SkillsRuntimeImportModel
    let skill: RuntimeLocalSkillSummary

    var body: some View {
        let checked = model.selected.contains(skill.key)
        let expanded = model.singleSelected?.key == skill.key
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            Button { model.toggle(skill.key) } label: {
                HStack(alignment: .top, spacing: 12) {
                    SkillsCheckbox(checked: checked).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            SkillsHighlightedText(text: skill.name, query: model.query).font(Theme.Font.bodyMedium).lineLimit(1)
                            SkillsHighlightedText(text: skill.provider, query: model.query)
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        if let d = skill.description, !d.isEmpty {
                            SkillsHighlightedText(text: d, query: model.query)
                                .font(Theme.Font.caption).foregroundStyle(.secondary)
                                .lineLimit(searching ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }
                        SkillsHighlightedText(text: skill.sourcePath, query: model.query)
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(tr("skills", "runtime_import.skill_files", ["count": skill.fileCount]))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.border))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("skills", "runtime_import.skill_name_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        TextField(skill.name, text: $model.editName).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("skills", "runtime_import.skill_description_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        SkillsTextArea(text: $model.editDescription, placeholder: tr("skills", "runtime_import.skill_description_placeholder"), minHeight: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.02))
                .overlay(alignment: .top) { Divider() }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(checked ? Theme.brand.opacity(0.05) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(checked ? Theme.brand : Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
    }
}

private struct SkillsResultIcon: View {
    let status: SkillsRuntimeImportModel.Status

    var body: some View {
        switch status {
        case .created: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .updated: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .conflict: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .skipped: Image(systemName: "forward.end").foregroundStyle(.yellow)
        case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.destructive)
        }
    }
}

private struct SkillsImportSummary: View {
    let results: [SkillsRuntimeImportModel.Result]

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                tile(.created, tr("skills", "runtime_import.bulk_summary_created"), .green)
                tile(.updated, tr("skills", "runtime_import.bulk_summary_updated"), .blue)
                tile(.conflict, tr("skills", "runtime_import.bulk_summary_conflicts"), .orange)
                tile(.skipped, tr("skills", "runtime_import.bulk_summary_skipped"), .yellow)
                tile(.failed, tr("skills", "runtime_import.bulk_summary_failed"), .red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { r in
                        HStack(spacing: 8) {
                            SkillsResultIcon(status: r.status)
                            Text(r.name).lineLimit(1)
                            Spacer(minLength: 8)
                            if let e = r.error { Text(e).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 200, alignment: .trailing).help(e) }
                        }
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 256)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
        }
        .padding(.vertical, 8)
    }

    private func tile(_ status: SkillsRuntimeImportModel.Status, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(results.filter { $0.status == status }.count)").font(Theme.Font.title).foregroundStyle(color)
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(color.opacity(0.1)))
    }
}

private struct SkillsConflictPanel: View {
    @Environment(WorkspaceSession.self) private var session
    @Bindable var model: SkillsRuntimeImportModel

    var body: some View {
        let conflicts = model.pendingConflicts
        let single = conflicts.count == 1
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(single ? tr("skills", "runtime_import.conflict_single_title") : tr("skills", "runtime_import.conflict_bulk_title", ["count": conflicts.count]))
                        .font(Theme.Font.bodyMedium)
                    Text(tr("skills", "runtime_import.conflict_hint")).font(Theme.Font.caption)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.orange.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.orange.opacity(0.3)))

            if !single {
                HStack(spacing: 8) {
                    Button { model.overwriteAll() } label: { Label(tr("skills", "runtime_import.conflict_overwrite_all"), systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!conflicts.contains { $0.conflict?.canOverwrite == true })
                    Button { model.skipAll() } label: { Label(tr("skills", "runtime_import.conflict_skip_all"), systemImage: "forward.end") }
                }
                .controlSize(.small)
            }

            ForEach(conflicts) { r in
                conflictCard(r, single: single)
            }
        }
        .padding(.vertical, 8)
    }

    private func conflictCard(_ r: SkillsRuntimeImportModel.Result, single: Bool) -> some View {
        let canOverwrite = r.conflict?.canOverwrite ?? false
        let resolution = model.resolutions[r.key] ?? .initial(name: r.name, canOverwrite: canOverwrite)
        let creatorName = r.conflict?.existingCreatedBy.flatMap { id in session.memberRecords.items.first { $0.userId == id }?.name }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.name).font(Theme.Font.bodyMedium).lineLimit(1)
                    if let e = r.error { Text(e).font(Theme.Font.caption).foregroundStyle(Theme.destructive) }
                    if !canOverwrite {
                        Text(creatorName.map { tr("skills", "runtime_import.conflict_locked_creator", ["creator": $0]) } ?? tr("skills", "runtime_import.conflict_locked"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                choice(tr("skills", "runtime_import.conflict_overwrite"), icon: "arrow.triangle.2.circlepath", active: resolution.action == .overwrite) {
                    let next = SkillsConflictResolution(action: .overwrite, renameName: resolution.renameName)
                    if single && canOverwrite {
                        model.resolutions[r.key] = next
                        Task { await model.applyResolutions(overrides: [r.key: next]) }
                    } else {
                        model.resolutions[r.key] = next
                    }
                }
                .disabled(!canOverwrite)
                choice(tr("skills", "runtime_import.conflict_rename"), icon: nil, active: resolution.action == .rename) {
                    model.resolutions[r.key] = SkillsConflictResolution(action: .rename, renameName: resolution.renameName)
                }
                choice(single ? tr("skills", "runtime_import.conflict_cancel") : tr("skills", "runtime_import.conflict_skip"),
                       icon: "xmark.circle", active: resolution.action == .skip) {
                    model.resolutions[r.key] = SkillsConflictResolution(action: .skip, renameName: resolution.renameName)
                }
            }
            .controlSize(.small)
            if resolution.action == .rename {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("skills", "runtime_import.conflict_rename_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    TextField("", text: Binding(
                        get: { model.resolutions[r.key]?.renameName ?? resolution.renameName },
                        set: { model.resolutions[r.key] = SkillsConflictResolution(action: .rename, renameName: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private func choice(_ title: String, icon: String?, active: Bool, action: @escaping () -> Void) -> some View {
        let label = Group {
            if let icon { Label(title, systemImage: icon) } else { Text(title) }
        }
        if active {
            Button(action: action) { label }.buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered)
        }
    }
}
