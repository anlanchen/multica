import MulticaCore
import SwiftUI

enum RuntimesProfilesIntent {
    case manage
    case create(machineName: String?)
    case edit(RuntimeProfile)
}

/// Custom runtime management: browse (custom profiles + built-in reference
/// families) or a create (two steps) / edit form.
struct RuntimesProfilesDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let intent: RuntimesProfilesIntent

    private enum Surface: Equatable {
        case browse
        case createFamily
        case createDetails
        case edit(RuntimeProfile)
    }

    @State private var surface: Surface = .browse
    @State private var family = RuntimesProfileCatalog.runtimeTypes[0]
    @State private var selectedID: String?
    @State private var initialized = false

    private var isManage: Bool {
        if case .manage = intent { return true }
        return false
    }

    var body: some View {
        let profiles = session.runtimesStore.profiles
        let catalog = RuntimesProfileCatalog.build(profiles.items)
        VStack(spacing: 0) {
            header(hasCustoms: !catalog.customs.isEmpty)
            Divider()
            switch surface {
            case .browse:
                HStack(spacing: 0) {
                    RuntimesCatalogList(customs: catalog.customs, builtins: catalog.builtins, loading: !profiles.isLoaded && profiles.error == nil,
                                        selectedID: $selectedID) { surface = .createFamily }
                        .frame(width: 320)
                    Divider()
                    RuntimesCatalogDetail(entry: (catalog.customs + catalog.builtins).first { $0.id == selectedID },
                                          onEdit: { surface = .edit($0) }, onDeleted: { selectedID = nil })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .createFamily:
                familyStep
            case .createDetails:
                RuntimesProfileForm(profile: nil, family: family, hideEditHeading: false,
                                    onBack: { surface = .createFamily }, onCancel: cancel, onSaved: saved)
            case .edit(let profile):
                RuntimesProfileForm(profile: profile, family: RuntimesProfileCatalog.runtimeType(of: profile), hideEditHeading: !isManage,
                                    onBack: { surface = .browse }, onCancel: cancel, onSaved: saved)
            }
        }
        .frame(width: isManage ? 760 : 640, height: 580)
        .task { await profiles.loadIfNeeded() }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            switch intent {
            case .manage: surface = .browse
            case .create: surface = .createFamily
            case .edit(let p): surface = .edit(p)
            }
        }
    }

    private func cancel() {
        if isManage { surface = .browse } else { dismiss() }
    }

    private func saved(_ profile: RuntimeProfile) {
        if !isManage {
            dismiss()
            return
        }
        selectedID = profile.id
        surface = .browse
    }

    private func header(hasCustoms: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text(title).font(Theme.Font.title).lineLimit(1)
                Spacer()
                if surface == .browse && hasCustoms {
                    Button { surface = .createFamily } label: { Label(tr("runtimes", "profiles.add_new"), systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help(tr("runtimes", "profiles.close"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link(destination: RuntimesDocs.customRuntimes()) {
                    HStack(spacing: 4) {
                        Text(tr("runtimes", "profiles.learn_more")).underline()
                        Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                    }
                }
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            }
            .font(Theme.Font.caption)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var title: String {
        switch intent {
        case .create: return tr("runtimes", "profiles.form.create_title")
        case .edit: return tr("runtimes", "profiles.form.edit_title")
        case .manage: return tr("runtimes", "profiles.dialog_title")
        }
    }

    private var description: String {
        if case .create(let machine) = intent {
            return tr("runtimes", "profiles.create_dialog_description", ["machine": machine ?? tr("runtimes", "profiles.this_machine")])
        }
        return tr("runtimes", "profiles.dialog_description")
    }

    private var familyStep: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("runtimes", "profiles.form.step_progress", ["current": 1, "total": 2]).uppercased())
                        .font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
                    Text(tr("runtimes", "profiles.form.step_family_label")).font(Theme.Font.bodyMedium)
                    Text(tr("runtimes", "profiles.form.step_family_hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(RuntimesProfileCatalog.runtimeTypes, id: \.self) { option in
                            Button {
                                family = option
                                surface = .createDetails
                            } label: {
                                HStack(spacing: 8) {
                                    RuntimesProviderLogo(provider: option, size: 16)
                                    Text(RuntimesProfileCatalog.label(option).capitalized).font(Theme.Font.body).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .hoverHighlight()
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            HStack {
                if case .create = intent {
                    Spacer()
                    Button(tr("runtimes", "profiles.form.cancel")) { dismiss() }
                } else {
                    Button { surface = .browse } label: { Label(tr("runtimes", "profiles.form.back"), systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct RuntimesCatalogList: View {
    let customs: [RuntimesCatalogEntry]
    let builtins: [RuntimesCatalogEntry]
    let loading: Bool
    @Binding var selectedID: String?
    let onAddNew: () -> Void
    @State private var builtinsOpen = false

    var body: some View {
        VStack(spacing: 0) {
            Text(tr("runtimes", "profiles.list_title")).font(Theme.Font.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("runtimes", "profiles.custom_section_title", ["count": customs.count]).uppercased())
                                .font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
                            if customs.isEmpty {
                                emptyCustom
                            } else {
                                VStack(spacing: 2) {
                                    ForEach(customs) { e in RuntimesCatalogRow(entry: e, active: e.id == selectedID) { selectedID = e.id } }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                builtinsOpen.toggle()
                                if !builtinsOpen, builtins.contains(where: { $0.id == selectedID }) { selectedID = nil }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tr("runtimes", "profiles.builtin_section_title", ["count": builtins.count]).uppercased())
                                            .font(.system(size: 10, weight: .medium)).tracking(0.5)
                                        Text(tr("runtimes", "profiles.builtin_section_hint")).font(Theme.Font.caption).lineLimit(1)
                                    }
                                    .foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.down").rotationEffect(.degrees(builtinsOpen ? 180 : 0)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if builtinsOpen {
                                VStack(spacing: 2) {
                                    ForEach(builtins) { e in RuntimesCatalogRow(entry: e, active: e.id == selectedID) { selectedID = e.id } }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var emptyCustom: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "profiles.empty_title")).font(Theme.Font.bodyMedium)
                Text(tr("runtimes", "profiles.empty_description")).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(action: onAddNew) { Label(tr("runtimes", "profiles.add_new"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }
}

private struct RuntimesCatalogRow: View {
    let entry: RuntimesCatalogEntry
    let active: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                RuntimesProviderLogo(provider: entry.protocolFamily, size: 16)
                    .opacity(entry.isBuiltin ? 0.75 : 1)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        switch entry {
                        case .custom(let p):
                            Text(p.displayName).font(Theme.Font.bodyMedium).lineLimit(1)
                            if !p.enabled { RuntimesTag(text: tr("runtimes", "profiles.badge_disabled")) }
                        case .builtin(let f):
                            Text(RuntimesProfileCatalog.label(f).capitalized).font(Theme.Font.bodyMedium).lineLimit(1)
                        }
                    }
                    if case .custom = entry {
                        Text(RuntimesProfileCatalog.label(entry.protocolFamily).capitalized).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if entry.isBuiltin {
                    Text(tr("runtimes", "profiles.builtin_reference").uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(entry.isBuiltin && !active ? .secondary : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }
}

private struct RuntimesCatalogDetail: View {
    let entry: RuntimesCatalogEntry?
    let onEdit: (RuntimeProfile) -> Void
    let onDeleted: () -> Void
    @State private var deleting = false

    var body: some View {
        switch entry {
        case nil:
            VStack(spacing: 8) {
                Image(systemName: "server.rack").font(.system(size: 18)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                Text(tr("runtimes", "profiles.detail.default_title")).font(Theme.Font.title).padding(.top, 8)
                Text(tr("runtimes", "profiles.detail.default_description")).font(Theme.Font.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 360)
        case .builtin(let family):
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    logo(family)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RuntimesProfileCatalog.label(family).capitalized).font(Theme.Font.title)
                        Text(tr("runtimes", "profiles.builtin_detail.read_only")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                Text(tr("runtimes", "profiles.builtin_detail.description", ["family": RuntimesProfileCatalog.label(family)]))
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .custom(let profile):
            let type = RuntimesProfileCatalog.runtimeType(of: profile)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 12) {
                            logo(type)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName).font(Theme.Font.title).lineLimit(1)
                                Text(RuntimesProfileCatalog.label(type).capitalized).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                        }
                        row(tr("runtimes", "profiles.detail.base_family")) { Text(RuntimesProfileCatalog.label(type).capitalized) }
                        row(tr("runtimes", "profiles.detail.command")) {
                            Text(RuntimesProfileCatalog.format(commandName: profile.commandName, fixedArgs: profile.fixedArgs))
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                        row(tr("runtimes", "profiles.detail.description")) {
                            if let d = profile.description, !d.isEmpty {
                                Text(d)
                            } else {
                                Text(tr("runtimes", "profiles.detail.no_description")).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button { onEdit(profile) } label: { Label(tr("runtimes", "profiles.detail.edit"), systemImage: "pencil") }
                    Button(role: .destructive) { deleting = true } label: { Label(tr("runtimes", "profiles.detail.delete"), systemImage: "trash") }
                        .foregroundStyle(Theme.destructive)
                }
                .controlSize(.small)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.03))
                .overlay(alignment: .top) { Divider() }
            }
            .sheet(isPresented: $deleting) {
                RuntimesDeleteProfileDialog(profile: profile) {
                    deleting = false
                    onDeleted()
                }
            }
        }
    }

    private func logo(_ provider: String) -> some View {
        RuntimesProviderLogo(provider: provider, size: 20)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
            value().font(Theme.Font.body)
        }
    }
}

/// Create (step 2) or edit form for a custom runtime profile.
private struct RuntimesProfileForm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let profile: RuntimeProfile?
    let family: String
    let hideEditHeading: Bool
    let onBack: () -> Void
    let onCancel: () -> Void
    let onSaved: (RuntimeProfile) -> Void
    @State private var displayName = ""
    @State private var commandLine = ""
    @State private var descriptionText = ""
    @State private var errors: [RuntimesProfileField] = []
    @State private var duplicateName = false
    @State private var formError: String?
    @State private var submitting = false
    @State private var loaded = false

    private var isCreate: Bool { profile == nil }

    var body: some View {
        let parsed = RuntimesProfileCatalog.parse(commandLine)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isCreate {
                        Text(tr("runtimes", "profiles.form.step_progress", ["current": 2, "total": 2]).uppercased())
                            .font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(.secondary)
                    }
                    if isCreate || !hideEditHeading {
                        Text(tr("runtimes", isCreate ? "profiles.form.step_details_label" : "profiles.form.edit_title")).font(Theme.Font.bodyMedium)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("profiles.form.family_label")
                        HStack(spacing: 8) {
                            RuntimesProviderLogo(provider: family, size: 16)
                            Text(RuntimesProfileCatalog.label(family).capitalized).font(Theme.Font.body)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                        Text(tr("runtimes", "profiles.form.family_locked_hint")).font(Theme.Font.micro).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("profiles.form.display_name_label")
                        TextField(tr("runtimes", "profiles.form.display_name_placeholder"), text: $displayName)
                            .textFieldStyle(.roundedBorder)
                        if errors.contains(.displayName) {
                            error(tr("runtimes", "profiles.form.error_display_name_required"))
                        } else if duplicateName {
                            error(tr("runtimes", "profiles.form.error_duplicate_name"))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("profiles.form.command_name_label")
                        TextField(tr("runtimes", "profiles.form.command_name_placeholder"), text: $commandLine)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                        if let message = commandError(parsed) { error(message) }
                        if case .success(let cmd) = parsed {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Text(tr("runtimes", "profiles.form.command_preview_executable"))
                                    Text(cmd.commandName).font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary).lineLimit(1)
                                }
                                if !cmd.fixedArgs.isEmpty {
                                    HStack(spacing: 4) {
                                        Text(tr("runtimes", "profiles.form.command_preview_args"))
                                        ForEach(Array(cmd.fixedArgs.enumerated()), id: \.offset) { _, arg in
                                            Text(arg).font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary)
                                                .padding(.horizontal, 4)
                                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.canvas))
                                        }
                                    }
                                }
                            }
                            .font(Theme.Font.micro)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        label("profiles.form.description_label")
                        TextField(tr("runtimes", "profiles.form.description_placeholder"), text: $descriptionText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                    }
                    if let formError { error(formError) }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            HStack(spacing: 8) {
                if isCreate {
                    Button(action: onBack) { Label(tr("runtimes", "profiles.form.back"), systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button(tr("runtimes", "profiles.form.cancel"), action: onCancel)
                Button { Task { await submit(parsed) } } label: {
                    HStack(spacing: 6) {
                        if submitting { ProgressView().controlSize(.small) }
                        Text(tr("runtimes", isCreate ? (submitting ? "profiles.form.creating" : "profiles.form.create")
                                                     : (submitting ? "profiles.form.saving" : "profiles.form.save")))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(submitting)
            }
            .controlSize(.small)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let profile {
                displayName = profile.displayName
                commandLine = RuntimesProfileCatalog.format(commandName: profile.commandName, fixedArgs: profile.fixedArgs)
                descriptionText = profile.description ?? ""
            }
        }
    }

    private func label(_ key: String) -> some View {
        Text(tr("runtimes", key)).font(Theme.Font.caption).foregroundStyle(.secondary)
    }

    private func error(_ text: String) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
    }

    private func commandError(_ parsed: Result<RuntimesParsedCommand, RuntimesCommandLineError>) -> String? {
        guard errors.contains(.commandLine) else { return nil }
        if commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return tr("runtimes", "profiles.form.error_command_required") }
        guard case .failure(let e) = parsed else { return nil }
        switch e {
        case .unclosedQuote: return tr("runtimes", "profiles.form.error_command_unclosed_quote")
        case .trailingEscape: return tr("runtimes", "profiles.form.error_command_trailing_escape")
        case .shellExpansion: return tr("runtimes", "profiles.form.error_command_shell_expansion")
        case .shellSyntax: return tr("runtimes", "profiles.form.error_command_shell_syntax")
        case .empty: return tr("runtimes", "profiles.form.error_command_required")
        }
    }

    private func submit(_ parsed: Result<RuntimesParsedCommand, RuntimesCommandLineError>) async {
        formError = nil
        duplicateName = false
        var validation = RuntimesProfileCatalog.validate(displayName: displayName, commandLine: commandLine)
        if !validation.contains(.commandLine), case .failure = parsed { validation.append(.commandLine) }
        errors = validation
        guard validation.isEmpty, case .success(let cmd) = parsed else { return }
        let description = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        submitting = true
        defer { submitting = false }
        let store = session.runtimesStore
        do {
            let saved: RuntimeProfile
            if let profile {
                saved = try await session.api.updateRuntimeProfile(
                    workspaceId: session.workspace.id, profileId: profile.id,
                    UpdateRuntimeProfileRequest(displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines), commandName: cmd.commandName,
                                                description: description.isEmpty ? nil : description, fixedArgs: cmd.fixedArgs))
                toaster.success(tr("runtimes", "profiles.form.toast_updated"))
            } else {
                saved = try await session.api.createRuntimeProfile(
                    workspaceId: session.workspace.id,
                    CreateRuntimeProfileRequest(displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines), runtimeType: family,
                                                commandName: cmd.commandName, description: description.isEmpty ? nil : description, fixedArgs: cmd.fixedArgs))
                toaster.success(tr("runtimes", "profiles.form.toast_created"))
            }
            store.profiles.upsert(saved)
            Task {
                await store.profiles.load()
                await session.runtimeRecords.load()
            }
            onSaved(saved)
        } catch let e as APIError where e.status == 409 {
            duplicateName = true
        } catch {
            let message = (error as? APIError)?.message ?? ""
            formError = message.isEmpty ? tr("runtimes", "profiles.form.error_generic") : message
        }
    }
}
