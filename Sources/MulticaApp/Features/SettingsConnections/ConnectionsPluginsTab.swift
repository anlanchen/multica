import MulticaCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Plugins: publish packages, review the consent screen, and
/// manage installed plugins (upstream plugins-tab.tsx + plugins/plugin-hook-
/// activity.tsx + plugins/plugin-mcp-approval.tsx).
struct ConnectionsPluginsTab: View {
    @Environment(WorkspaceSession.self) private var session
    @State private var installations: ConnectionsLoad<[PluginInstallation]> = .pending

    private var canManage: Bool { session.connectionsIsManager }

    var body: some View {
        ConnectionsSettingsPage(title: tr("settings", "plugins.title"), scope: .workspace) {
            if session.connectionsIsMember && !canManage { ConnectionsReadOnlyNotice() }
            if canManage { ConnectionsPluginPublish(onInstalled: { Task { await load() } }) }
            ConnectionsSection(title: tr("settings", "plugins.installed.title")) {
                switch installations {
                case .pending:
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)).frame(height: 96)
                        .accessibilityLabel(tr("settings", "plugins.loading"))
                case .failed:
                    ConnectionsAlert(tone: .destructive, title: tr("settings", "plugins.load_failed"),
                                     message: tr("settings", "plugins.load_failed_description"))
                case .loaded(let list) where list.isEmpty:
                    ConnectionsCard {
                        Text(tr("settings", "plugins.empty")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(16)
                    }
                case .loaded(let list):
                    VStack(spacing: 16) {
                        ForEach(list, id: \.id) { inst in
                            ConnectionsInstalledPlugin(installation: inst, canManage: canManage) { updated in
                                if let updated { replace(updated) } else { Task { await load() } }
                            }
                        }
                    }
                }
            }
        }
        .task(id: session.revision("plugin")) { await load() }
    }

    private func load() async {
        do {
            installations = .loaded(try await session.api.listPluginInstallations(workspaceId: session.workspace.id).plugins)
        } catch {
            if installations.value == nil { installations = .failed }
        }
    }

    private func replace(_ inst: PluginInstallation) {
        guard var list = installations.value, let i = list.firstIndex(where: { $0.id == inst.id }) else { return }
        list[i] = inst
        installations = .loaded(list)
    }
}

/// Raw scope strings beside a plain-language line; never summarized away.
private struct ConnectionsScopeList: View {
    let scopes: [String]
    var highlighted: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(scopes, id: \.self) { scope in
                let d = ConnectionsPlugins.scopeKey(scope)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(scope).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    Text(tr("settings", "plugins.scopes.\(d.key)", d.args)).foregroundStyle(.secondary)
                    if highlighted.contains(scope) { Badge(text: tr("settings", "plugins.consent.new_scope")) }
                }
                .font(Theme.Font.caption)
            }
        }
    }
}

private struct ConnectionsScheduleList: View {
    let hooks: [ConnectionsScheduledHook]
    var showNextRun = false

    private static func frequency(_ cron: String) -> String {
        switch ConnectionsPlugins.frequency(cron) {
        case .minutes(let n): return tr("settings", "plugins.schedule.frequency_minutes", ["count": n])
        case .hourly(let m): return tr("settings", "plugins.schedule.frequency_hourly", ["minute": m])
        case .daily(let h, let m): return tr("settings", "plugins.schedule.frequency_daily", ["hour": h, "minute": m])
        case .custom: return tr("settings", "plugins.schedule.frequency_custom")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hooks) { hook in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(hook.name).fontWeight(.medium)
                    Text(Self.frequency(hook.cron))
                    Text(hook.cron).font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    Text(hook.timezone).foregroundStyle(.secondary)
                    if showNextRun, let next = hook.nextRunAt {
                        Text(tr("settings", "plugins.schedule.next_run", ["time": connectionsPluginTime(next)])).foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.caption)
            }
        }
        .padding(.top, 6)
    }
}

func connectionsPluginTime(_ raw: String?) -> String {
    guard let raw, let d = Timestamp.parse(raw) else { return "—" }
    return d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: L10n.shared.language)))
}

// MARK: - Publish & install

private struct ConnectionsPluginPublish: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let onInstalled: () -> Void
    @State private var packages: ConnectionsLoad<[PluginPackage]> = .pending
    @State private var importing = false
    @State private var publishing = false
    @State private var busy = false
    @State private var preview: PluginPreview?
    @State private var installing = false

    var body: some View {
        ConnectionsSection(title: tr("settings", "plugins.publish.title")) {
            ConnectionsCard {
                HStack(spacing: 12) {
                    Text(tr("settings", "plugins.publish.hint")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { importing = true } label: {
                        HStack(spacing: 6) {
                            if publishing { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.up") }
                            Text(tr("settings", "plugins.publish.upload"))
                        }
                    }
                    .disabled(publishing)
                }
                .padding(16)
                Divider()
                switch packages {
                case .pending:
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)).frame(height: 64).padding(16)
                        .accessibilityLabel(tr("settings", "plugins.loading"))
                case .failed:
                    Text(tr("settings", "plugins.publish.empty")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(16)
                case .loaded(let list) where list.isEmpty:
                    Text(tr("settings", "plugins.publish.empty")).font(Theme.Font.caption).foregroundStyle(.secondary).padding(16)
                case .loaded(let list):
                    ForEach(list, id: \.id) { pkg in
                        if pkg.id != list.first?.id { Divider() }
                        packageRow(pkg)
                    }
                }
                if let preview {
                    Divider()
                    consent(preview)
                }
            }
        }
        .task { await loadPackages() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            Task { await publish(url) }
        }
    }

    private func loadPackages() async {
        do {
            packages = .loaded(try await session.api.listPluginPackages(workspaceId: session.workspace.id).packages)
        } catch {
            if packages.value == nil { packages = .failed }
        }
    }

    private func report(_ error: Error) {
        let message = (error as? APIError)?.message
        toaster.error(message?.isEmpty == false ? message! : tr("settings", "plugins.action_failed"))
    }

    private func publish(_ url: URL) async {
        publishing = true
        defer { publishing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let published = try await session.api.publishPluginPackage(workspaceId: session.workspace.id, fileName: url.lastPathComponent, data: data)
            toaster.success(tr("settings", "plugins.publish.published", ["name": published.name, "version": published.versions.first?.version ?? ""]))
            await loadPackages()
        } catch {
            report(error)
        }
    }

    private func packageRow(_ pkg: PluginPackage) -> some View {
        let installed = pkg.versions.contains { $0.installed }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pkg.name).font(Theme.Font.bodyMedium)
                    Text(pkg.pluginKey).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await deletePackage(pkg.id) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help(tr("settings", "plugins.publish.delete"))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pkg.versions, id: \.id) { v in
                    HStack(spacing: 8) {
                        Text(v.version).font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                        if v.installed { Badge(text: tr("settings", "plugins.publish.installed_version")) }
                        Text(String(v.publishedAt.prefix(10))).foregroundStyle(.secondary)
                        Text(String(v.digest.prefix(12))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).help(v.digest)
                        Spacer()
                        if !v.installed {
                            Button(tr("settings", installed ? "plugins.publish.review_upgrade" : "plugins.publish.review_install")) {
                                Task { await review(v.id) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy)
                        }
                    }
                    .font(Theme.Font.caption)
                }
            }
        }
        .padding(16)
    }

    private func deletePackage(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            try await session.api.deletePluginPackage(workspaceId: session.workspace.id, packageId: id)
            toaster.success(tr("settings", "plugins.publish.deleted"))
            await loadPackages()
        } catch {
            report(error)
        }
    }

    private func review(_ versionID: String) async {
        busy = true
        defer { busy = false }
        do {
            preview = try await session.api.previewPlugin(workspaceId: session.workspace.id, PluginPreviewRequest(versionId: versionID))
        } catch {
            preview = nil
            report(error)
        }
    }

    private func consent(_ p: PluginPreview) -> some View {
        let scheduled = ConnectionsPlugins.scheduledHooks(manifest: p.manifest?.contributes)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.manifest?.name ?? "").font(.system(size: 13, weight: .semibold))
                Text(tr("settings", "plugins.byline", ["author": ConnectionsPlugins.authorName(p.manifest?.author ?? .null), "version": p.version])
                     + (p.installed ? tr("settings", "plugins.consent.upgrade_from", ["version": p.installedVersion ?? ""]) : ""))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                if let d = p.manifest?.description, !d.isEmpty {
                    Text(d).font(Theme.Font.caption).padding(.top, 4)
                }
            }
            ConnectionsAlert(title: tr("settings", "plugins.consent.title"), message: tr("settings", "plugins.consent.description"))
            ConnectionsScopeList(scopes: p.scopes, highlighted: Set(p.addedScopes ?? []))
            if !scheduled.isEmpty {
                ConnectionsAlert(icon: "calendar.badge.clock", title: tr("settings", "plugins.schedule.consent_title"),
                                 message: tr("settings", "plugins.schedule.consent_description")) {
                    ConnectionsScheduleList(hooks: scheduled)
                }
            }
            HStack {
                Spacer()
                Button(tr("settings", "plugins.consent.cancel")) { preview = nil }
                    .buttonStyle(.borderless)
                Button {
                    Task { await install(p) }
                } label: {
                    HStack(spacing: 6) {
                        if installing { ProgressView().controlSize(.small) }
                        Text(tr("settings", p.installed ? "plugins.consent.confirm_upgrade" : "plugins.consent.confirm"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installing)
            }
        }
        .padding(16)
    }

    private func install(_ p: PluginPreview) async {
        installing = true
        defer { installing = false }
        do {
            _ = try await session.api.installPlugin(workspaceId: session.workspace.id,
                                                    PluginInstallRequest(versionId: p.versionId, grantedScopes: p.scopes))
            preview = nil
            toaster.success(tr("settings", "plugins.consent.installed"))
            await loadPackages()
            onInstalled()
        } catch {
            report(error)
        }
    }
}

// MARK: - Installed plugin

private struct ConnectionsInstalledPlugin: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let installation: PluginInstallation
    let canManage: Bool
    /// The server's updated installation, or nil to reload the list.
    let onChange: (PluginInstallation?) -> Void
    @State private var invocations: [PluginInvocation] = []
    @State private var mutating = false

    var body: some View {
        let hasHooks = !installation.hooks.isEmpty
        let scheduled = ConnectionsPlugins.scheduledHooks(installation.hooks)
        let mcp = ConnectionsPlugins.mcpHooks(installation.hooks)
        let contributions = installation.surfaces.map { "\($0.name) (\($0.type))" }
            + installation.hooks.map { "\($0.name) (\($0.triggers.joined(separator: ", ")))" }
            + installation.resources.map { "\($0.key) (\($0.type))" }
        ConnectionsCard {
            VStack(alignment: .leading, spacing: 16) {
                if hasHooks { hookActivity }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(installation.name).font(.system(size: 13, weight: .semibold))
                            Badge(text: tr("settings", "plugins.version", ["version": installation.version]))
                            if !installation.enabled { ConnectionsBillingBadge(text: tr("settings", "plugins.states.disabled"), style: .outline) }
                        }
                        Text(installation.pluginKey).font(Theme.Font.caption).foregroundStyle(.secondary)
                        if let d = installation.description, !d.isEmpty {
                            Text(d).font(Theme.Font.caption).frame(maxWidth: 640, alignment: .leading).padding(.top, 6)
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { installation.enabled }, set: { v in Task { await setEnabled(v) } }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(!canManage || mutating)
                            .help(tr("settings", "plugins.enabled_label"))
                        Button { Task { await uninstall() } } label: {
                            if mutating { ProgressView().controlSize(.small) } else { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canManage || mutating)
                        .help(tr("settings", "plugins.uninstall"))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("settings", "plugins.granted_scopes")).font(.system(size: 11, weight: .medium))
                    ConnectionsScopeList(scopes: installation.grantedScopes)
                }
                if !scheduled.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(tr("settings", "plugins.schedule.title"), systemImage: "calendar.badge.clock").font(.system(size: 11, weight: .medium))
                        ConnectionsScheduleList(hooks: scheduled, showNextRun: true)
                        scheduleActivity(scheduled)
                    }
                }
                if !mcp.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("settings", "plugins.mcp.badge")).font(.system(size: 11, weight: .medium))
                        ForEach(mcp, id: \.key) { hook in
                            ConnectionsPluginMCPApproval(installationID: installation.id, hook: hook, canManage: canManage)
                        }
                    }
                }
                if !contributions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("settings", "plugins.contributes")).font(.system(size: 11, weight: .medium))
                        Text(contributions.joined(separator: " · ")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            if !installation.configSchema.isEmpty {
                Divider()
                ConnectionsPluginConfigForm(installation: installation, canManage: canManage, onSaved: { onChange($0) })
            }
        }
        .task(id: installation.id) {
            guard hasHooks else { return }
            invocations = (try? await session.api.listPluginInvocations(workspaceId: session.workspace.id, installationId: installation.id)) ?? []
        }
    }

    /// Shown only while recent calls failed; red once the breaker tripped.
    @ViewBuilder private var hookActivity: some View {
        let summary = ConnectionsPlugins.summarize(invocations)
        if summary.failures > 0 {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.tripped ? tr("settings", "plugins.hook_circuit_open")
                         : tr("settings", "plugins.hook_recent_failures", ["count": summary.failures])).fontWeight(.medium)
                    if let last = summary.lastError { Text(last).lineLimit(1) }
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(summary.tripped ? Theme.destructive : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(summary.tripped ? Theme.destructive.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(summary.tripped ? Theme.destructive.opacity(0.4) : Theme.border))
        }
    }

    private func scheduleActivity(_ hooks: [ConnectionsScheduledHook]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("settings", "plugins.schedule.activity_title")).font(.system(size: 11, weight: .medium))
            ForEach(hooks) { hook in
                let last = invocations.first { $0.trigger == "schedule" && $0.hookKey == hook.key }
                (Text(hook.name).fontWeight(.medium).foregroundColor(.primary) + Text(" · ")
                 + Text(last.map {
                     tr("settings", "plugins.schedule.activity_last", ["status": $0.status, "planned": connectionsPluginTime($0.plannedAt),
                                                                       "actual": connectionsPluginTime($0.createdAt), "attempt": $0.attempt])
                 } ?? tr("settings", "plugins.schedule.activity_empty")))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    private func report(_ error: Error) {
        let message = (error as? APIError)?.message
        toaster.error(message?.isEmpty == false ? message! : tr("settings", "plugins.action_failed"))
    }

    private func setEnabled(_ enabled: Bool) async {
        mutating = true
        defer { mutating = false }
        do {
            let updated = try await session.api.setPluginEnabled(workspaceId: session.workspace.id, installationId: installation.id, enabled: enabled)
            toaster.success(tr("settings", enabled ? "plugins.enabled" : "plugins.disabled"))
            onChange(updated)
        } catch {
            report(error)
        }
    }

    private func uninstall() async {
        mutating = true
        defer { mutating = false }
        do {
            try await session.api.uninstallPlugin(workspaceId: session.workspace.id, installationId: installation.id)
            toaster.success(tr("settings", "plugins.uninstalled"))
            onChange(nil)
        } catch {
            report(error)
        }
    }
}

/// Pin the tools an `mcp` hook may expose; the checkbox state is the complete
/// approved set, and drifted tools start unchecked.
private struct ConnectionsPluginMCPApproval: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let installationID: String
    let hook: PluginHook
    let canManage: Bool
    @State private var tools: ConnectionsLoad<[PluginMCPTool]> = .pending
    @State private var loadError = ""
    /// nil until the administrator edits, so refetches don't undo an edit.
    @State private var selected: [String]?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(hook.name).font(.system(size: 11, weight: .medium))
                ConnectionsBillingBadge(text: tr("settings", "plugins.mcp.badge"), style: .outline)
            }
            Text(tr("settings", "plugins.mcp.description")).font(Theme.Font.caption).foregroundStyle(.secondary)
            switch tools {
            case .pending:
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)).frame(height: 64)
                    .accessibilityLabel(tr("settings", "plugins.mcp.loading"))
            case .failed:
                ConnectionsAlert(tone: .destructive, title: tr("settings", "plugins.mcp.unreachable"), message: loadError)
            case .loaded(let list) where list.isEmpty:
                Text(tr("settings", "plugins.mcp.empty")).font(Theme.Font.caption).foregroundStyle(.secondary)
            case .loaded(let list):
                let current = selected ?? ConnectionsPlugins.initialSelection(list)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(list, id: \.name) { tool in
                        Toggle(isOn: Binding(get: { current.contains(tool.name) }, set: { on in
                            selected = on ? current + [tool.name] : current.filter { $0 != tool.name }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(tool.name).font(.system(size: 11, design: .monospaced))
                                    if tool.drifted { ConnectionsBillingBadge(text: tr("settings", "plugins.mcp.drifted"), style: .destructive) }
                                }
                                if !tool.description.isEmpty { Text(tool.description).foregroundStyle(.secondary) }
                            }
                            .font(Theme.Font.caption)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!canManage || saving)
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        Task { await save(current) }
                    } label: {
                        HStack(spacing: 6) {
                            if saving { ProgressView().controlSize(.small) }
                            Text(tr("settings", "plugins.mcp.save"))
                        }
                    }
                    .controlSize(.small)
                    .disabled(!canManage || saving)
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        .task { await load() }
    }

    private func load() async {
        do {
            tools = .loaded(try await session.api.listPluginMCPTools(workspaceId: session.workspace.id, installationId: installationID, hookKey: hook.key))
        } catch {
            loadError = (error as? APIError)?.message ?? error.localizedDescription
            tools = .failed
        }
    }

    private func save(_ names: [String]) async {
        saving = true
        defer { saving = false }
        do {
            _ = try await session.api.approvePluginMCPTools(workspaceId: session.workspace.id, installationId: installationID,
                                                            hookKey: hook.key, tools: names)
            selected = nil
            toaster.success(tr("settings", "plugins.mcp.approved"))
            await load()
        } catch {
            let message = (error as? APIError)?.message
            toaster.error(message?.isEmpty == false ? message! : tr("settings", "plugins.action_failed"))
        }
    }
}

/// Configuration generated from the manifest schema (never plugin markup).
private struct ConnectionsPluginConfigForm: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let installation: PluginInstallation
    let canManage: Bool
    let onSaved: (PluginInstallation) -> Void
    @State private var values: [String: JSONValue] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var saving = false

    var body: some View {
        let configured = Set(installation.configuredSecrets)
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("settings", "plugins.config.title")).font(.system(size: 11, weight: .medium))
            ForEach(installation.configSchema, id: \.key) { field in
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(field.label).font(.system(size: 11, weight: .medium))
                            if field.required { Text("*").foregroundStyle(Theme.destructive) }
                        }
                        if let d = field.description, !d.isEmpty {
                            Text(d).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    control(field, secretConfigured: configured.contains(field.key))
                        .frame(width: 384, alignment: .leading)
                        .disabled(!canManage || saving)
                }
            }
            HStack {
                Spacer()
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if saving { ProgressView().controlSize(.small) }
                        Text(tr("settings", "plugins.config.save"))
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!canManage || saving)
            }
        }
        .padding(16)
        .onAppear { values = installation.config }
    }

    @ViewBuilder
    private func control(_ field: PluginConfigField, secretConfigured: Bool) -> some View {
        switch field.type {
        case "secret":
            SecureField(secretConfigured ? tr("settings", "plugins.config.secret_set") : (field.placeholder ?? ""),
                        text: Binding(get: { secrets[field.key] ?? "" }, set: { secrets[field.key] = $0 }))
                .textFieldStyle(.roundedBorder)
        case "bool":
            Toggle("", isOn: Binding(get: { values[field.key]?.boolValue == true }, set: { values[field.key] = .bool($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        case "enum":
            Picker("", selection: Binding(get: { values[field.key]?.stringValue ?? "" }, set: { values[field.key] = .string($0) })) {
                if values[field.key]?.stringValue == nil { Text("").tag("") }
                ForEach(field.options ?? [], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case "number":
            TextField(field.placeholder ?? "", text: Binding(
                get: { values[field.key]?.doubleValue.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" },
                set: { s in values[field.key] = Double(s).map { .number($0) } }))
                .textFieldStyle(.roundedBorder)
        default:
            if field.multiline == true {
                TextEditor(text: Binding(get: { values[field.key]?.stringValue ?? "" }, set: { values[field.key] = .string($0) }))
                    .font(Theme.Font.body)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            } else {
                TextField(field.placeholder ?? "", text: Binding(get: { values[field.key]?.stringValue ?? "" }, set: { values[field.key] = .string($0) }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let payload = ConnectionsPlugins.configPayload(values: values, secrets: secrets)
            let updated = try await session.api.configurePlugin(workspaceId: session.workspace.id, installationId: installation.id,
                                                                PluginConfigRequest(values: payload))
            secrets = [:]
            toaster.success(tr("settings", "plugins.config.saved"))
            onSaved(updated)
        } catch {
            let message = (error as? APIError)?.message
            toaster.error(message?.isEmpty == false ? message! : tr("settings", "plugins.action_failed"))
        }
    }
}
