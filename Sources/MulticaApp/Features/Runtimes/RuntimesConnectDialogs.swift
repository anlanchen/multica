import MulticaCore
import SwiftUI

enum RuntimesCLIInstall {
    static let macosLinux = "curl -fsSL https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.sh | bash"
    static let windows = "irm https://raw.githubusercontent.com/multica-ai/multica/main/scripts/install.ps1 | iex"

    /// `multica setup` for Multica Cloud; explicit URLs for self-hosting.
    static func daemonCommands(_ config: ServerConfig) -> (setup: String, token: String) {
        func norm(_ u: URL) -> String {
            var s = u.absoluteString.trimmingCharacters(in: .whitespaces)
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        if config.apiURL != ServerConfig.production.apiURL {
            let server = norm(config.apiURL), app = norm(config.appURL)
            return ("multica setup self-host --server-url \(server) --app-url \(app)",
                    "multica config set server_url \(server)\nmultica config set app_url \(app)\nmultica login --token <YOUR_TOKEN>\nmultica daemon start")
        }
        return ("multica setup",
                "multica config set server_url https://api.multica.ai\nmultica config set app_url https://multica.ai\nmultica login --token <YOUR_TOKEN>\nmultica daemon start")
    }
}

/// "Add a computer": install + `multica setup`, then advance as soon as the
/// new daemon registers.
struct RuntimesConnectRemoteDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(Navigator.self) private var nav
    @Environment(\.dismiss) private var dismiss
    @State private var connected = false
    @State private var newRuntimeID: String?
    @State private var baseline: [String: String]?
    @State private var platform = 0
    @State private var troubleshooting = false

    var body: some View {
        VStack(spacing: 0) {
            if connected { success } else { instructions }
        }
        .frame(width: 520)
        .animation(.easeOut(duration: 0.2), value: connected)
        .onAppear {
            baseline = Dictionary(session.runtimeRecords.items.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        }
        .onChange(of: session.runtimeRecords.items) { detectRegistration() }
        .onChange(of: session.revision("daemon")) { Task { await session.runtimeRecords.load() } }
    }

    private func detectRegistration() {
        guard !connected, let baseline else { return }
        let registered = session.runtimeRecords.items.first { r in
            baseline[r.id] == nil || (baseline[r.id] != "online" && r.status == "online")
        }
        guard let registered else { return }
        newRuntimeID = registered.id
        connected = true
    }

    private var instructions: some View {
        let commands = RuntimesCLIInstall.daemonCommands(env.app.config)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "connect.title")).font(Theme.Font.title)
                Text(tr("runtimes", "connect.description")).font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    step(1, tr("runtimes", "connect.step1_label")) {
                        Picker(tr("runtimes", "connect.platform_group"), selection: $platform) {
                            Text(tr("runtimes", "connect.platform_macos_linux")).tag(0)
                            Text(tr("runtimes", "connect.platform_windows")).tag(1)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        RuntimesCommandRow(command: platform == 0 ? RuntimesCLIInstall.macosLinux : RuntimesCLIInstall.windows)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        step(2, tr("runtimes", "connect.step2_label")) { RuntimesCommandRow(command: commands.setup) }
                        Text(tr("runtimes", "connect.step2_hint")).font(Theme.Font.micro).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        RuntimesPulseDot()
                        Text(tr("runtimes", "connect.live_listening")).font(Theme.Font.caption.weight(.medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    troubleshootingBlock(commands.token)
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
            }
            .frame(maxHeight: 460)
            HStack {
                Spacer()
                Button(tr("runtimes", "connect.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func step<C: View>(_ n: Int, _ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(n). \(label)").font(Theme.Font.caption.weight(.medium))
            content()
        }
    }

    private func troubleshootingBlock(_ tokenCommand: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { troubleshooting.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(troubleshooting ? 90 : 0))
                    Text(tr("runtimes", "connect.troubleshooting"))
                }
                .font(Theme.Font.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if troubleshooting {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("runtimes", "connect.trouble_intro"))
                    step(2, tr("runtimes", "connect.step2_label")) { RuntimesCommandRow(command: tokenCommand) }
                    (Text(tr("runtimes", "connect.trouble_token_hint_prefix"))
                     + Text(tr("runtimes", "connect.trouble_token_hint_destination")).fontWeight(.medium).foregroundStyle(.primary)
                     + Text(tr("runtimes", "connect.trouble_token_hint_suffix")))
                    HStack(spacing: 6) {
                        Text(tr("runtimes", "connect.trouble_check_status"))
                        Text("multica daemon status").font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(RuntimesPalette.muted))
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 6) {
                        Text(tr("runtimes", "connect.trouble_view_logs"))
                        Text("multica daemon logs -f").font(.system(size: 10, design: .monospaced)).foregroundStyle(.primary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(RuntimesPalette.muted))
                            .textSelection(.enabled)
                    }
                }
                .font(Theme.Font.micro)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.border))
    }

    private var success: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("runtimes", "connect.success_title")).font(Theme.Font.title)
                Text(tr("runtimes", "connect.success_description")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
            Image(systemName: "checkmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.success)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.success.opacity(0.1)))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            HStack(spacing: 8) {
                Spacer()
                if let newRuntimeID {
                    Button(tr("runtimes", "connect.view_runtime")) {
                        dismiss()
                        nav.push(.runtime(newRuntimeID))
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    dismiss()
                    nav.push(.agents)
                } label: {
                    HStack(spacing: 4) {
                        Text(tr("runtimes", "connect.create_agent"))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
    }
}

private struct RuntimesPulseDot: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.success.opacity(0.6)).frame(width: 8, height: 8)
                .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.6)
            Circle().fill(Theme.success).frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

// MARK: Cloud runtime

/// Cloud Runtime fleet (web SaaS only upstream): launch nodes and list or
/// delete the existing ones; polls while a node is transitioning.
struct RuntimesCloudRuntimeDialog: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    static let instanceTypes = ["t4g.medium", "t4g.large"]
    static let pendingStatuses: Set<String> = ["launching", "pending", "starting", "stopping", "rebooting", "terminating"]
    @State private var name = ""
    @State private var instanceType = instanceTypes[0]
    @State private var diskSize = "20"
    @State private var creating = false
    @State private var refreshing = false

    var body: some View {
        let query = session.runtimesStore.cloudNodes()
        let nodes = (query.value ?? []).sorted { (Timestamp.parse($0.createdAt) ?? .distantPast) > (Timestamp.parse($1.createdAt) ?? .distantPast) }
        let anyPending = nodes.contains { Self.pendingStatuses.contains($0.status.lowercased()) }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label(tr("runtimes", "cloud_runtime.title"), systemImage: "cloud").font(Theme.Font.title)
                Text(tr("runtimes", "cloud_runtime.description")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("runtimes", "cloud_runtime.create_title")).font(Theme.Font.bodyMedium)
                    labeled(tr("runtimes", "cloud_runtime.fields.name")) {
                        TextField(tr("runtimes", "cloud_runtime.placeholders.name"), text: $name).textFieldStyle(.roundedBorder)
                    }
                    labeled(tr("runtimes", "cloud_runtime.fields.instance_type")) {
                        Picker("", selection: $instanceType) {
                            ForEach(Self.instanceTypes, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    labeled(tr("runtimes", "cloud_runtime.fields.disk_size")) {
                        TextField("20", text: $diskSize).textFieldStyle(.roundedBorder)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 0) {
                    HStack {
                        Text(tr("runtimes", "cloud_runtime.nodes_title")).font(Theme.Font.bodyMedium)
                        Spacer()
                        Button {
                            Task {
                                refreshing = true
                                await query.load(force: true)
                                refreshing = false
                            }
                        } label: {
                            Label(tr("runtimes", "cloud_runtime.refresh"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(refreshing)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.canvas)
                    Divider()
                    Group {
                        if query.value == nil && query.error == nil {
                            ProgressView().controlSize(.small).frame(height: 160)
                        } else if let error = query.error, query.value == nil {
                            VStack(spacing: 4) {
                                Text(tr("runtimes", "cloud_runtime.nodes_failed")).font(Theme.Font.bodyMedium)
                                Text(error.isEmpty ? tr("runtimes", "cloud_runtime.nodes_failed_hint") : error).font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            .frame(height: 160)
                        } else if nodes.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "cloud").font(.system(size: 22)).foregroundStyle(.tertiary)
                                Text(tr("runtimes", "cloud_runtime.nodes_empty")).font(Theme.Font.bodyMedium)
                            }
                            .frame(height: 160)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 8) {
                                    ForEach(nodes) { RuntimesCloudNodeRow(node: $0) }
                                }
                                .padding(8)
                            }
                            .frame(maxHeight: 410)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 280, maxWidth: .infinity)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            HStack(spacing: 8) {
                Spacer()
                Button(tr("runtimes", "cloud_runtime.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await create(query) } } label: {
                    HStack(spacing: 6) {
                        if creating { ProgressView().controlSize(.small) } else { Image(systemName: "paperplane") }
                        Text(tr("runtimes", creating ? "cloud_runtime.creating" : "cloud_runtime.create"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(creating)
            }
            .controlSize(.small)
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 760)
        .task { await query.load(staleAfter: 15) }
        .task(id: anyPending) {
            while anyPending && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await query.load(force: true)
            }
        }
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.Font.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func create(_ query: RuntimesQuery<[CloudRuntimeNode]>) async {
        let trimmed = diskSize.trimmingCharacters(in: .whitespaces)
        let size = trimmed.isEmpty ? 20 : Int(trimmed)
        guard let size, size > 0 else {
            toaster.error(tr("runtimes", "cloud_runtime.validation.disk_size_invalid"))
            return
        }
        creating = true
        defer { creating = false }
        do {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await session.api.createCloudRuntimeNode(CreateCloudRuntimeNodeRequest(instanceType: instanceType, name: n.isEmpty ? nil : n, diskSizeGb: size))
            toaster.success(tr("runtimes", "cloud_runtime.toast_created"))
            name = ""
            instanceType = Self.instanceTypes[0]
            diskSize = "20"
            await query.load(force: true)
        } catch {
            let message = (error as? APIError)?.message ?? ""
            toaster.error(message.isEmpty ? tr("runtimes", "cloud_runtime.toast_create_failed") : message)
        }
    }
}

private struct RuntimesCloudNodeRow: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    let node: CloudRuntimeNode
    @State private var confirming = false
    @State private var deleting = false

    var body: some View {
        let title = [node.name, node.instanceId].map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            ?? tr("runtimes", "cloud_runtime.node_fallback_name")
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(Theme.Font.bodyMedium).lineLimit(1)
                        statusBadge
                    }
                    HStack(spacing: 6) {
                        Text(node.instanceType)
                        Text("/").foregroundStyle(.tertiary)
                        Text(node.region)
                        if let created = Timestamp.parse(node.createdAt) {
                            Text("/").foregroundStyle(.tertiary)
                            Text(created.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button { confirming = true } label: {
                    if deleting { ProgressView().controlSize(.small) } else { Image(systemName: "trash") }
                }
                .buttonStyle(.borderless)
                .disabled(deleting)
                .help(tr("runtimes", "cloud_runtime.delete"))
            }
            if !node.instanceId.isEmpty {
                Text(node.instanceId).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        .confirmationDialog(tr("runtimes", "cloud_runtime.delete_confirm"), isPresented: $confirming) {
            Button(tr("runtimes", "cloud_runtime.delete"), role: .destructive) { Task { await delete() } }
        }
    }

    private var statusBadge: some View {
        let s = node.status.lowercased()
        let color: Color = ["running", "success"].contains(s) ? Theme.success
            : RuntimesCloudRuntimeDialog.pendingStatuses.contains(s) ? Theme.warning
            : ["failed", "terminated", "error"].contains(s) ? Theme.destructive : .secondary
        return Text(node.status.isEmpty ? "unknown" : node.status)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color == .secondary ? RuntimesPalette.muted : color.opacity(0.1)))
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await session.api.deleteCloudRuntimeNode(instanceId: node.instanceId)
            toaster.success(tr("runtimes", "cloud_runtime.toast_deleted"))
            await session.runtimesStore.cloudNodes().load(force: true)
        } catch {
            let message = (error as? APIError)?.message ?? ""
            toaster.error(message.isEmpty ? tr("runtimes", "cloud_runtime.toast_delete_failed") : message)
        }
    }
}
