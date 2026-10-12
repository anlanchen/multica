import MulticaCore
import SwiftUI

struct AgentsUIInstructionsTab: View {
    let agent: AgentRecord
    let onDirtyChange: (Bool) -> Void
    let onSave: ([String: JSONValue]) async throws -> Void
    var body: some View { EmptyView() }
}

struct AgentsUISkillsTab: View {
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let canEdit: Bool
    var body: some View { EmptyView() }
}

struct AgentsUIMcpConfigTab: View {
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let canEdit: Bool
    let onSave: ([String: JSONValue]) async throws -> Void
    var body: some View { EmptyView() }
}

struct AgentsUIComposioTab: View {
    let agent: AgentRecord
    var body: some View { EmptyView() }
}

struct AgentsUIIntegrationsTab: View {
    let agent: AgentRecord
    var body: some View { EmptyView() }
}

struct AgentsUIEnvTab: View {
    let agent: AgentRecord
    let onDirtyChange: (Bool) -> Void
    var body: some View { EmptyView() }
}

struct AgentsUICustomArgsTab: View {
    let agent: AgentRecord
    let runtime: RuntimeDeviceRecord?
    let onDirtyChange: (Bool) -> Void
    let onSave: ([String: JSONValue]) async throws -> Void
    var body: some View { EmptyView() }
}

struct AgentsUIRuntimeConfigTab: View {
    let agent: AgentRecord
    let onDirtyChange: (Bool) -> Void
    let onSave: ([String: JSONValue]) async throws -> Void
    var body: some View { EmptyView() }
}

struct AgentsUIChooseMethodPage: View { var body: some View { EmptyView() } }
struct AgentsUIManualCreatePage: View { var body: some View { EmptyView() } }
struct AgentsUIAICreatePage: View { var body: some View { EmptyView() } }
struct AgentsUIBuilderSessionPage: View {
    let sessionID: String
    var body: some View { EmptyView() }
}
