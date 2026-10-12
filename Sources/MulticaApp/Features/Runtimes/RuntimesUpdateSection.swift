import MulticaCore
import SwiftUI

/// Daemon CLI version with an in-app self-update through one of the
/// machine's runtimes (upstream `UpdateSection`).
struct RuntimesUpdateSection: View {
    @Environment(WorkspaceSession.self) private var session
    /// Nil for a viewer who cannot use any runtime as the command channel.
    let runtimeID: String?
    let currentVersion: String?
    let isOnline: Bool
    /// "desktop" when a desktop app spawned the daemon and ships its CLI.
    let launchedBy: String?
    @State private var latest: String?
    @State private var status: String?
    @State private var output = ""
    @State private var error = ""
    @State private var target: String?
    @State private var poll: Task<Void, Never>?

    var body: some View {
        let managed = launchedBy == "desktop"
        let hasUpdate = currentVersion.flatMap { c in latest.map { RuntimesRelease.isNewer($0, than: c) } } ?? false
        let localBuild = currentVersion.map { RuntimesRelease.parseReleaseVersion($0) == nil } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(tr("runtimes", "update.cli_version_label")).foregroundStyle(.secondary)
                Text(currentVersion ?? tr("runtimes", "update.version_unknown")).font(.system(size: 11, design: .monospaced))
                if managed {
                    Text(tr("runtimes", "update.managed_by_desktop")).foregroundStyle(.secondary).help(tr("runtimes", "update.managed_by_desktop_title"))
                } else {
                    if localBuild && status == nil {
                        Text(tr("runtimes", "update.local_build")).foregroundStyle(.secondary).help(tr("runtimes", "update.local_build_title"))
                    }
                    if !localBuild && !hasUpdate && currentVersion != nil && latest != nil && status == nil {
                        Label(tr("runtimes", "update.latest"), systemImage: "checkmark").foregroundStyle(Theme.success)
                    }
                    if hasUpdate && status == nil {
                        Text("→").foregroundStyle(.secondary)
                        Text(latest ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.info)
                        Text(tr("runtimes", "update.available")).foregroundStyle(.secondary)
                    }
                    if hasUpdate && runtimeID == nil {
                        Label(tr("runtimes", "update.read_only"), systemImage: "lock").foregroundStyle(.secondary).help(tr("runtimes", "update.read_only_title"))
                    }
                    if hasUpdate, runtimeID != nil, isOnline, status == nil {
                        Button { Task { await startUpdate() } } label: { Label(tr("runtimes", "update.action"), systemImage: "arrow.up.circle") }
                            .controlSize(.mini)
                            .disabled(target != nil)
                    }
                }
                if let status {
                    HStack(spacing: 4) {
                        switch status {
                        case "pending", "running": ProgressView().controlSize(.mini)
                        case "completed": Image(systemName: "checkmark.circle")
                        default: Image(systemName: "xmark.circle")
                        }
                        Text(tr("runtimes", "update.status.\(status)"))
                    }
                    .foregroundStyle(statusColor(status))
                }
            }
            if status == "completed" && !output.isEmpty {
                Text(output).font(Theme.Font.caption).foregroundStyle(Theme.success)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.success.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            if (status == "failed" || status == "timeout") && !error.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
                    if status == "failed" {
                        Button(tr("runtimes", "update.retry")) { Task { await startUpdate() } }.controlSize(.mini).buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.destructive.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.destructive.opacity(0.2)))
            }
        }
        .font(Theme.Font.caption)
        .task { latest = await RuntimesRelease.latestVersion() }
        .onChange(of: currentVersion) {
            // The re-fetched runtime reports the target version: done.
            if let target, let currentVersion, !RuntimesRelease.isNewer(target, than: currentVersion) {
                complete("Updated to \(target)")
            }
        }
        .onDisappear { poll?.cancel() }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "running": return Theme.info
        case "completed": return Theme.success
        case "failed": return Theme.destructive
        case "timeout": return Theme.warning
        default: return .secondary
        }
    }

    private func complete(_ message: String) {
        poll?.cancel()
        poll = nil
        status = "completed"
        output = message
        target = nil
        Task {
            try? await Task.sleep(for: .seconds(5))
            status = nil
        }
    }

    private func startUpdate() async {
        guard let latest, let runtimeID else { return }
        poll?.cancel()
        target = latest
        status = "pending"
        error = ""
        output = ""
        do {
            let update = try await session.api.initiateUpdate(runtimeID, targetVersion: latest)
            poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let result = try? await session.api.getUpdateResult(runtimeID, updateId: update.id) else { continue }
                    status = result.status
                    if result.status == "completed" {
                        complete(result.output ?? "Updated to \(latest)")
                        return
                    }
                    if result.status == "failed" || result.status == "timeout" {
                        error = result.error ?? tr("runtimes", "update.unknown_error")
                        target = nil
                        return
                    }
                }
            }
        } catch {
            status = "failed"
            self.error = tr("runtimes", "update.initiate_failed")
            target = nil
        }
    }
}
