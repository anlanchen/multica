import MulticaCore
import SwiftUI

extension AgentRecord {
    /// The record with a PUT body applied, so pickers flip before the
    /// round-trip (upstream optimistic `handleUpdate`).
    func agentsUIApplying(_ patch: [String: JSONValue]) -> AgentRecord {
        var a = self
        func str(_ k: String) -> String? { patch[k]?.stringValue }
        if let v = str("name") { a.name = v }
        if let v = str("description") { a.description = v }
        if let v = str("instructions") { a.instructions = v }
        if let v = patch["avatar_url"] { a.avatarUrl = v.stringValue }
        if let v = str("runtime_id") {
            a.runtimeId = v
            a.runtimeBound = !v.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let v = str("model") { a.model = v }
        if let v = str("thinking_level") { a.thinkingLevel = v }
        if let v = str("service_tier") { a.serviceTier = v }
        if let v = patch["max_concurrent_tasks"]?.doubleValue { a.maxConcurrentTasks = Int(v) }
        if let v = str("permission_mode") { a.permissionMode = v }
        if case .array(let list)? = patch["invocation_targets"] {
            a.invocationTargets = list.map { AgentInvocationTarget(targetType: $0["target_type"]?.stringValue ?? "", targetId: $0["target_id"]?.stringValue) }
            a.visibility = AgentsUI.accessScope(permissionMode: a.permissionMode, targets: a.invocationTargets) == .workspace ? "workspace" : "private"
        }
        if case .array(let list)? = patch["custom_args"] { a.customArgs = list.compactMap(\.stringValue) }
        if let v = patch["mcp_config"] { a.mcpConfig = v.isNull ? nil : v }
        if case .object(let o)? = patch["runtime_config"] { a.runtimeConfig = o }
        if case .array(let list)? = patch["composio_toolkit_allowlist"] { a.composioToolkitAllowlist = list.compactMap(\.stringValue) }
        if case .array(let list)? = patch["conversation_starters"] {
            a.conversationStarters = list.compactMap {
                guard let l = $0["label"]?.stringValue, let p = $0["prompt"]?.stringValue else { return nil }
                return AgentConversationStarter(label: l, prompt: p)
            }
        }
        return a
    }
}

extension WorkspaceSession {
    /// Optimistic agent update: patch the cached record, adopt the server
    /// answer, roll back and toast on failure. Throws so callers can keep
    /// their draft for a retry.
    func agentsUIUpdate(_ agentID: String, _ patch: [String: JSONValue], toaster: Toaster, successToast: Bool = true) async throws {
        let previous = agentRecords.item(agentID)
        if let previous { agentRecords.upsert(previous.agentsUIApplying(patch)) }
        do {
            let updated = try await api.updateAgent(agentID, patch: patch)
            agentRecords.upsert(updated)
            if successToast { toaster.success(tr("agents", "detail.agent_updated_toast")) }
        } catch {
            if let previous { agentRecords.upsert(previous) }
            Task { await agentRecords.refreshIfLoaded() }
            toaster.show((error as? APIError)?.message ?? tr("agents", "detail.update_failed_toast"), kind: .error)
            throw error
        }
    }

    func agentsUIArchive(_ agentID: String, toaster: Toaster, toast: String) async {
        do {
            let a = try await api.archiveAgent(agentID)
            agentRecords.upsert(a)
            toaster.success(toast)
        } catch {
            toaster.show((error as? APIError)?.message ?? tr("agents", "row_actions.archive_failed_toast"), kind: .error)
        }
        await agentRecords.refreshIfLoaded()
    }

    func agentsUIRestore(_ agentID: String, toaster: Toaster, toast: String) async {
        do {
            let a = try await api.restoreAgent(agentID)
            agentRecords.upsert(a)
            toaster.success(toast)
        } catch {
            toaster.show((error as? APIError)?.message ?? tr("agents", "row_actions.restore_failed_toast"), kind: .error)
        }
        await agentRecords.refreshIfLoaded()
    }

    /// Updates the cached record with a server-side change made elsewhere
    /// (skills, MCP assignments) by refetching that one agent.
    func agentsUIReload(_ agentID: String) async {
        if let a = try? await api.getAgent(agentID) { agentRecords.upsert(a) }
    }
}
