import AppKit
import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

enum SkillsCreateMethod: String, CaseIterable {
    case chooser, manual, local, url, runtime

    var icon: String {
        switch self {
        case .chooser, .manual: return "plus"
        case .local: return "folder"
        case .url: return "arrow.down.to.line"
        case .runtime: return "internaldrive"
        }
    }
}

/// New-skill dialog (upstream CreateSkillDialog): a method chooser, then a
/// manual form, local folder/archive import, URL import or runtime copy.
struct SkillsCreateSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Skill) -> Void
    @State private var method: SkillsCreateMethod = .chooser
    @State private var local = SkillsLocalImportState()

    var body: some View {
        let wide = method == .runtime
        VStack(spacing: 0) {
            header
            switch method {
            case .chooser: chooser
            case .manual: SkillsManualForm(onCreated: created, onCancel: { method = .chooser })
            case .url: SkillsURLForm(onCreated: created, onCancel: { method = .chooser })
            case .local:
                SkillsLocalForm(state: local, onCreated: created, onCancel: {
                    local.reset()
                    method = .chooser
                })
            case .runtime:
                SkillsRuntimeImportPanel(onImported: created, onBulkDone: { dismiss() })
            }
        }
        .frame(width: wide ? 672 : 448, height: wide ? 600 : nil)
        .animation(.easeOut(duration: 0.25), value: wide)
    }

    private func created(_ skill: Skill) {
        session.skills.upsert(skill.skillsSummary)
        Task { await session.agentRecords.refreshIfLoaded() }
        dismiss()
        onCreated(skill)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if method != .chooser {
                Button {
                    local.reset()
                    method = .chooser
                } label: {
                    Image(systemName: "arrow.left").font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tr("skills", "create.back"))
                .accessibilityLabel(tr("skills", "create.back_aria"))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("skills", "create.method.\(method.rawValue).title")).font(Theme.Font.title).lineLimit(1)
                Text(tr("skills", "create.method.\(method.rawValue).desc")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .help(tr("skills", "create.close"))
            .accessibilityLabel(tr("skills", "create.close_aria"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var chooser: some View {
        VStack(spacing: 8) {
            ForEach([SkillsCreateMethod.manual, .local, .url, .runtime], id: \.self) { m in
                Button { choose(m) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: m.icon)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.06)))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("skills", "create.method.\(m.rawValue).title")).font(Theme.Font.bodyMedium)
                            Text(tr("skills", "create.method.\(m.rawValue).desc")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 10)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SkillsCardButtonStyle())
            }
        }
        .padding(20)
    }

    private func choose(_ next: SkillsCreateMethod) {
        if next == .local {
            // Switch first so cancelling the picker still lands on the local panel.
            method = .local
            local.chooseFolder()
            return
        }
        local.reset()
        method = next
    }
}

struct SkillsCardButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(hovering ? Theme.hover : Color.primary.opacity(0.02)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(hovering ? Theme.brand.opacity(0.4) : Theme.border))
            .onHover { hovering = $0 }
    }
}

/// Body + footer layout shared by the forms.
private struct SkillsFormLayout<Content: View, Footer: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                footer()
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private func skillsErrorText(_ error: String, hintKey: String) -> String {
    SkillsErrors.isNameConflict(error) ? error + tr("skills", hintKey) : error
}

private func skillsMessage(_ error: Error) -> String {
    (error as? APIError)?.message ?? (error as? SkillsError)?.message ?? error.localizedDescription
}

// MARK: - Manual

private struct SkillsManualForm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let onCreated: (Skill) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var loading = false
    @State private var error = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        SkillsFormLayout {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("skills", "create.manual.name_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                TextField(tr("skills", "create.manual.name_placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { Task { await submit() } }
                    .onChange(of: name) { error = "" }
                Text(tr("skills", "create.manual.name_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(tr("skills", "create.manual.description_label"), systemImage: "pencil")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                SkillsTextArea(text: $description, placeholder: tr("skills", "create.manual.description_placeholder"), minHeight: 60)
            }
            if !error.isEmpty { SkillsErrorBox(message: skillsErrorText(error, hintKey: "create.manual.name_conflict_hint")) }
        } footer: {
            Button(tr("skills", "create.manual.cancel"), action: onCancel).disabled(loading)
            Button { Task { await submit() } } label: {
                SkillsBusyLabel(title: loading ? tr("skills", "create.manual.submitting") : tr("skills", "create.manual.submit"), busy: loading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .onAppear { nameFocused = true }
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !loading else { return }
        loading = true
        error = ""
        do {
            let skill = try await session.api.createSkill(CreateSkillRequest(name: trimmed, description: description.trimmingCharacters(in: .whitespacesAndNewlines)))
            toaster.success(tr("skills", "create.manual.toast_created"))
            onCreated(skill)
        } catch {
            let message = skillsMessage(error)
            self.error = message.isEmpty ? tr("skills", "create.manual.fallback_error") : message
            loading = false
        }
    }
}

// MARK: - URL

private struct SkillsURLForm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let onCreated: (Skill) -> Void
    let onCancel: () -> Void
    @State private var url = ""
    @State private var loading = false
    @State private var error = ""
    @FocusState private var focused: Bool

    private enum Source { case clawhub, skillsSh, github }

    private var source: Source? {
        let u = url.trimmingCharacters(in: .whitespaces).lowercased()
        if u.contains("clawhub.ai") { return .clawhub }
        if u.contains("skills.sh") { return .skillsSh }
        if u.contains("github.com") { return .github }
        return nil
    }

    var body: some View {
        SkillsFormLayout {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("skills", "create.url.url_label")).font(Theme.Font.caption).foregroundStyle(.secondary)
                TextField("https://clawhub.ai/owner/skill", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.mono)
                    .focused($focused)
                    .onSubmit { Task { await submit() } }
                    .onChange(of: url) { error = "" }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("skills", "create.url.supported_sources")).font(Theme.Font.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    sourceCard("ClawHub", host: "clawhub.ai/owner/skill", browse: "https://clawhub.ai", active: source == .clawhub)
                    sourceCard("Skills.sh", host: "skills.sh/owner/repo/skill", browse: "https://skills.sh", active: source == .skillsSh)
                    sourceCard("GitHub", host: "github.com/owner/repo", browse: "https://github.com", active: source == .github)
                }
            }
            if !error.isEmpty { SkillsErrorBox(message: skillsErrorText(error, hintKey: "create.url.name_conflict_hint")) }
        } footer: {
            Button(tr("skills", "create.url.cancel"), action: onCancel).disabled(loading)
            Button { Task { await submit() } } label: {
                SkillsBusyLabel(title: submitLabel, icon: "arrow.down.to.line", busy: loading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .onAppear { focused = true }
    }

    private var submitLabel: String {
        guard loading else { return tr("skills", "create.url.import") }
        switch source {
        case .clawhub: return tr("skills", "create.url.importing_clawhub")
        case .skillsSh: return tr("skills", "create.url.importing_skills_sh")
        case .github: return tr("skills", "create.url.importing_github")
        case nil: return tr("skills", "create.url.importing")
        }
    }

    private func sourceCard(_ label: String, host: String, browse: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.Font.caption.weight(.medium))
            Button { SkillsLinks.open(browse) } label: {
                Text(host).font(.system(size: 10.5, design: .monospaced)).underline().foregroundStyle(Theme.brand).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(active ? Theme.brand.opacity(0.06) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(active ? Theme.brand : Theme.border))
    }

    private func submit() async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !loading else { return }
        loading = true
        error = ""
        do {
            let skill = try await session.api.importSkill(url: trimmed)
            toaster.success(tr("skills", "create.url.toast_imported"))
            onCreated(skill)
        } catch {
            let message = skillsMessage(error)
            self.error = message.isEmpty ? tr("skills", "create.url.fallback_error") : message
            loading = false
        }
    }
}

// MARK: - Local folder / archive

/// Folder/archive selection, prepared off the main actor. A generation
/// counter drops results from a selection the user already replaced.
@MainActor
@Observable
final class SkillsLocalImportState {
    var prepared: Result<SkillsArchive.Prepared, SkillsArchive.Failure>?
    var preparing = false
    var epoch = 0

    func reset() {
        epoch += 1
        prepared = nil
        preparing = false
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("skills", "create.local.choose_folder")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.prepareFolder(url) }
        }
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.zip]
        if let skill = UTType(filenameExtension: "skill") { types.append(skill) }
        panel.allowedContentTypes = types
        panel.prompt = tr("skills", "create.local.choose_archive")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.prepareArchive(url) }
        }
    }

    private func prepareFolder(_ url: URL) {
        epoch += 1
        let generation = epoch
        preparing = true
        prepared = nil
        Task.detached(priority: .userInitiated) {
            let result = Self.packFolder(url)
            await MainActor.run {
                guard generation == self.epoch else { return }
                self.prepared = result
                self.preparing = false
            }
        }
    }

    private func prepareArchive(_ url: URL) {
        epoch += 1
        preparing = false
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > SkillsArchive.maxArchiveBytes {
            prepared = .failure(.tooLarge)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            prepared = .failure(.empty)
            return
        }
        prepared = SkillsArchive.wrapExisting(fileName: url.lastPathComponent, data: data)
    }

    /// Paths are relative to the picked folder's parent so the folder name
    /// becomes the wrapper (as with the browser's directory picker).
    nonisolated static func packFolder(_ root: URL) -> Result<SkillsArchive.Prepared, SkillsArchive.Failure> {
        let fm = FileManager.default
        let base = root.deletingLastPathComponent().standardizedFileURL.path
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            return .failure(.empty)
        }
        var members: [SkillsArchive.Member] = []
        var sources: [String: URL] = [:]
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            var rel = file.standardizedFileURL.path
            if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
            while rel.hasPrefix("/") { rel.removeFirst() }
            members.append(SkillsArchive.Member(path: rel, size: values.fileSize ?? 0))
            if sources[rel] == nil { sources[rel] = file }
        }
        switch SkillsArchive.select(members) {
        case .failure(let f): return .failure(f)
        case .success(let selection):
            var data: [String: Data] = [:]
            for m in selection.selected where data[m.path] == nil {
                data[m.path] = sources[m.path].flatMap { try? Data(contentsOf: $0) } ?? Data()
            }
            return SkillsArchive.prepare(selection) { data[$0] ?? Data() }
        }
    }
}

private struct SkillsLocalForm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let state: SkillsLocalImportState
    let onCreated: (Skill) -> Void
    let onCancel: () -> Void
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        let prepared = try? state.prepared?.get()
        let prepareError: String = {
            guard case .failure(let f)? = state.prepared else { return "" }
            switch f {
            case .missingSkillMD: return tr("skills", "create.local.missing_skill_md")
            case .tooLarge: return tr("skills", "create.local.too_large")
            case .empty: return tr("skills", "create.local.empty")
            case .tooManyFiles: return tr("skills", "create.local.too_many_files")
            }
        }()
        let displayError = error.isEmpty ? prepareError : error
        SkillsFormLayout {
            if state.preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("skills", "create.local.importing"))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }
            if let prepared {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prepared.preview.source == .archive ? tr("skills", "create.local.archive_label") : tr("skills", "create.local.folder_label"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Text(prepared.preview.displayName).font(Theme.Font.bodyMedium).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prepared.preview.skillName).font(Theme.Font.bodyMedium)
                        if !prepared.preview.description.isEmpty {
                            Text(prepared.preview.description).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        if let count = prepared.preview.fileCount {
                            Text(tr("skills", "create.local.files", ["count": count])).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button { state.chooseFolder() } label: {
                    Label(tr("skills", "create.local.choose_folder"), systemImage: "folder").frame(maxWidth: .infinity)
                }
                Button { state.chooseArchive() } label: {
                    Label(tr("skills", "create.local.choose_archive"), systemImage: "doc.zipper").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
            .disabled(loading || state.preparing)
            if !displayError.isEmpty { SkillsErrorBox(message: skillsErrorText(displayError, hintKey: "create.local.name_conflict_hint")) }
        } footer: {
            Button(tr("skills", "create.local.cancel"), action: onCancel).disabled(loading)
            Button { Task { await submit(prepared) } } label: {
                SkillsBusyLabel(title: loading ? tr("skills", "create.local.importing") : tr("skills", "create.local.import"), icon: "folder", busy: loading)
            }
            .buttonStyle(.borderedProminent)
            .disabled(prepared == nil || loading || state.preparing)
        }
        .id(state.epoch)
    }

    private func submit(_ prepared: SkillsArchive.Prepared?) async {
        guard let prepared, !loading else { return }
        loading = true
        error = ""
        do {
            let skill = try await session.api.skillsImportArchive(fileName: prepared.fileName, data: prepared.data)
            toaster.success(tr("skills", "create.local.toast_imported"))
            onCreated(skill)
        } catch {
            let message = skillsMessage(error)
            self.error = message.isEmpty ? tr("skills", "create.local.fallback_error") : message
            loading = false
        }
    }
}

/// Multi-line plain text input with a placeholder (upstream Textarea).
struct SkillsTextArea: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 60
    var isEditable = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .disabled(!isEditable)
                .padding(4)
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder).font(Theme.Font.body).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }
}
