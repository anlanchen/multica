import AppKit
import MulticaCore
import SwiftUI

/// Bottom-follow state shared with rows. A plain class: scroll position
/// changes every frame and must never re-render the list.
@MainActor
final class ChatUIScrollFollow {
    var atBottom = true
    var fetchingOlder = false
    var proxy: ScrollViewProxy?

    /// Keeps the live end in view while the reader is there.
    func follow() {
        guard atBottom, !fetchingOlder, let proxy else { return }
        proxy.scrollTo(ChatUIMessageList.bottomID, anchor: .bottom)
    }
}

private struct ChatUIFollowKey: EnvironmentKey {
    static let defaultValue: ChatUIScrollFollow? = nil
}

extension EnvironmentValues {
    var chatUIFollow: ChatUIScrollFollow? {
        get { self[ChatUIFollowKey.self] }
        set { self[ChatUIFollowKey.self] = newValue }
    }
}

private struct ChatUIBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One list row. A running task and the assistant message it becomes share
/// the key `task:<id>`, so the handoff updates the row in place.
struct ChatUIListItem: Hashable, Identifiable {
    let key: String
    let message: ChatMessage?
    let taskID: String?

    var id: String { key }

    static func message(_ m: ChatMessage) -> ChatUIListItem {
        let key = m.role == "assistant" && m.taskId != nil ? "task:\(m.taskId!)" : m.id
        return ChatUIListItem(key: key, message: m, taskID: m.taskId)
    }
}

/// The conversation transcript (upstream ChatMessageList): lazy rows, the
/// live row of the running task, the status pill, older-page loading and
/// stick-to-bottom while the reader is at the live end.
struct ChatUIMessageList: View {
    static let bottomID = "chat-ui-bottom"

    @Environment(WorkspaceSession.self) private var session
    let conversation: ChatUIConversation
    let surface: ChatUISurface
    let quickActionsDisabled: Bool
    @State private var follow = ChatUIScrollFollow()
    @State private var landed = false
    @State private var viewport: CGFloat = 0
    @State private var olderAnchor: String?

    var body: some View {
        let store = session.chatUI
        let c = conversation
        let pendingID = c.pendingTaskID
        let persisted = c.pendingAlreadyPersisted
        let live = pendingID.flatMap { id in ChatUIText.isTaskID(id) && !persisted ? store.timeline(id) : nil }
        let hasLive = live?.hasMessages == true
        let showPill = pendingID != nil && !persisted
        var items = c.renderMessages.map(ChatUIListItem.message)
        if hasLive, let pendingID { items.append(ChatUIListItem(key: "task:\(pendingID)", message: nil, taskID: pendingID)) }
        let latestID = c.latestAssistantMessageID
        let starterID = c.starterCardsMessageID
        let markerID = c.quickActionsMarker?.messageID

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 16)
                        .onAppear { loadOlder(firstKey: items.first?.key) }
                    if c.isFetchingOlder {
                        Text(tr("chat", "message_list.loading_older"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 8)
                    }
                    ForEach(items) { item in
                        ChatUIMessageRow(
                            item: item,
                            isPending: pendingID != nil && item.taskID == pendingID,
                            canRegenerate: item.message?.id == latestID,
                            markerPending: item.message.map { $0.id == markerID } ?? false,
                            showStarterCards: item.message.map { $0.id == starterID } ?? false,
                            quickActionsDisabled: quickActionsDisabled,
                            surface: surface
                        )
                        .equatable()
                        .chatUIColumn()
                        .padding(.vertical, 8)
                        .id(item.key)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        if showPill {
                            ChatUIStatusPill(pending: c.pending, timeline: live, availability: store.context.availability)
                        }
                    }
                    .chatUIColumn()
                    .padding(.bottom, 16)
                    Color.clear.frame(height: 1)
                        .id(Self.bottomID)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ChatUIBottomKey.self, value: g.frame(in: .named("chatUIScroll")).maxY)
                        })
                }
            }
            .coordinateSpace(name: "chatUIScroll")
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { viewport = g.size.height }
                    .onChange(of: g.size.height) { _, h in viewport = h }
            })
            .onPreferenceChange(ChatUIBottomKey.self) { maxY in
                follow.atBottom = maxY <= viewport + 120
            }
            .onAppear {
                follow.proxy = proxy
                land(proxy)
            }
            .onChange(of: items.count) { follow.follow() }
            .onChange(of: showPill) { follow.follow() }
            .onChange(of: c.olderCount) {
                if let anchor = olderAnchor { proxy.scrollTo(anchor, anchor: .top) }
                olderAnchor = nil
                follow.fetchingOlder = false
            }
            .onChange(of: c.isFetchingOlder) { _, fetching in
                if !fetching { follow.fetchingOlder = false }
            }
            .task(id: live?.id) {
                guard let id = live?.id else { return }
                store.retainLiveTimeline(id)
                await ChatUIUntilCancelled.wait()
                store.releaseLiveTimeline(id)
            }
            .opacity(landed ? 1 : 0)
            .environment(\.chatUIFollow, follow)
        }
    }

    /// Opens pinned to the newest message (twice: lazy rows settle their
    /// heights after the first pass).
    private func land(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                landed = true
            }
        }
    }

    private func loadOlder(firstKey: String?) {
        guard landed, conversation.hasOlder, !conversation.isFetchingOlder else { return }
        olderAnchor = firstKey
        follow.fetchingOlder = true
        session.chatUI.fetchOlder(conversation.id)
    }
}

/// Suspends until the surrounding task is cancelled.
enum ChatUIUntilCancelled {
    static func wait() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

// MARK: Rows

/// Equatable on its inputs so a streamed frame or a new message reconciles
/// only the rows it touched.
struct ChatUIMessageRow: View, Equatable {
    let item: ChatUIListItem
    let isPending: Bool
    let canRegenerate: Bool
    let markerPending: Bool
    let showStarterCards: Bool
    let quickActionsDisabled: Bool
    let surface: ChatUISurface

    var body: some View {
        if let m = item.message, m.role == "user" {
            ChatUIUserBubble(message: m)
        } else {
            ChatUIAssistantTurn(
                taskID: item.taskID,
                message: item.message,
                isPending: isPending,
                canRegenerate: canRegenerate,
                markerPending: markerPending,
                showStarterCards: showStarterCards,
                quickActionsDisabled: quickActionsDisabled,
                surface: surface
            )
        }
    }
}

struct ChatUIUserBubble: View {
    @Environment(Navigator.self) private var nav
    let message: ChatMessage
    @State private var inline: AttributedString?
    @State private var blocks = false

    var body: some View {
        let text = ChatUIText.displayMarkdown(message.content, attachments: message.attachments)
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .leading, spacing: 6) {
                if blocks {
                    ChatUIRichText(source: text)
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(inline ?? AttributedString(text))
                        .font(Theme.Font.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "mention" else { return .systemAction }
                            let id = url.pathComponents.dropFirst().first ?? ""
                            switch url.host() ?? "" {
                            case "issue": nav.push(.issue(id))
                            case "project": nav.push(.project(id))
                            case "agent": nav.push(.agent(id))
                            case "member": nav.push(.member(id))
                            case "squad": nav.push(.squad(id))
                            default: return .discarded
                            }
                            return .handled
                        })
                }
                ChatUIAttachmentList(attachments: message.attachments, content: text)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .task(id: message.content) {
            let source = ChatUIText.displayMarkdown(message.content, attachments: message.attachments)
            let parsed = await Task.detached(priority: .userInitiated) { MarkdownBlocks.cachedParse(source) }.value
            if parsed.count == 1, case .paragraph = parsed[0] {
                inline = await MarkdownCache.shared.render(source)
                blocks = false
            } else {
                blocks = !parsed.isEmpty
            }
        }
    }
}

/// An assistant turn, live or persisted (upstream AssistantMessage): the
/// process fold and answer from the task timeline, then attachments, the
/// elapsed/copy footer and follow-up suggestions.
struct ChatUIAssistantTurn: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(\.chatUIFollow) private var follow
    let taskID: String?
    let message: ChatMessage?
    let isPending: Bool
    let canRegenerate: Bool
    let markerPending: Bool
    let showStarterCards: Bool
    let quickActionsDisabled: Bool
    let surface: ChatUISurface

    var body: some View {
        let store = session.chatUI
        let timeline = taskID.map { store.timeline($0) }
        Group {
            if let message, let reason = message.failureReason, !reason.isEmpty {
                ChatUIFailureBubble(reason: reason, rawError: message.content, timeline: timeline, elapsedMs: message.elapsedMs)
            } else {
                content(store: store, timeline: timeline)
            }
        }
        .task(id: "\(taskID ?? "")|\(message != nil)") {
            if let taskID, message != nil { store.loadTimeline(taskID) }
        }
        .onChange(of: timeline?.items.count) { if message == nil { follow?.follow() } }
        .onChange(of: timeline?.finalText.count) { if message == nil { follow?.follow() } }
        .onChange(of: message?.quickActions?.count) { follow?.follow() }
        .onChange(of: markerPending) { follow?.follow() }
    }

    @ViewBuilder
    private func content(store: ChatUIStore, timeline: ChatUITaskTimeline?) -> some View {
        let isNoResponse = message?.messageKind == "no_response"
        let settled = message.map { ChatUIText.displayMarkdown(ChatUITimeline.canonicalAnswer($0), attachments: $0.attachments) }
        let canonical = !isNoResponse && !(settled ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? settled : nil
        let hasTimeline = !(timeline?.items.isEmpty ?? true)
        VStack(alignment: .leading, spacing: 6) {
            if let timeline, hasTimeline {
                ChatUITimelineView(timeline: timeline, settledAnswer: message == nil ? nil : canonical, isStreaming: message == nil)
            }
            if isNoResponse {
                Text(tr("chat", "message_list.no_response")).font(Theme.Font.body).italic().foregroundStyle(.secondary)
            } else if let message, !hasTimeline {
                ChatUIRichText(source: settled ?? message.content)
            }
            if let message {
                ChatUIAttachmentList(attachments: message.attachments, content: settled ?? message.content)
                ChatUIMessageFooter(message: message, items: timeline?.items ?? [], isPending: isPending)
                if showStarterCards {
                    ChatUIOnboardingCards(disabled: quickActionsDisabled || isPending) { action in
                        await store.send(action.prompt, attachmentIDs: [], attachments: [], draftKey: nil, surface: surface)
                    }
                } else if let actions = message.quickActions, !actions.isEmpty {
                    ChatUIQuickActions(
                        actions: actions,
                        disabled: quickActionsDisabled || isPending,
                        pending: markerPending,
                        canRegenerate: canRegenerate,
                        onSelect: { action in await store.send(action.prompt, attachmentIDs: [], attachments: [], draftKey: nil, surface: surface) },
                        onRegenerate: { try await store.regenerateQuickActions(messageID: message.id) }
                    )
                } else if markerPending {
                    ChatUIQuickActionsSkeleton()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Timeline

/// Streaming: preface text, the process fold, the answer so far. Settled:
/// preface + middle are process history and the persisted message is the
/// answer.
struct ChatUITimelineView: View {
    let timeline: ChatUITaskTimeline
    let settledAnswer: String?
    let isStreaming: Bool

    var body: some View {
        if let answer = settledAnswer {
            let process = timeline.preface + timeline.middle
            if !process.isEmpty {
                ChatUIProcessFold(items: process, isStreaming: false, stepCount: timeline.middle.count)
            }
            ChatUIRichText(source: answer)
        } else {
            if !timeline.preface.isEmpty {
                ChatUIRichText(source: timeline.prefaceText)
            }
            if !timeline.middle.isEmpty {
                ChatUIProcessFold(items: timeline.middle, isStreaming: isStreaming, stepCount: timeline.middle.count)
            }
            if !timeline.final.isEmpty {
                ChatUIRichText(source: timeline.finalText)
            }
        }
    }
}

/// The collapsible "N steps" box: open while the task streams so progress
/// is visible, collapsed once it settles.
struct ChatUIProcessFold: View {
    let items: [ChatUITimelineItem]
    let isStreaming: Bool
    let stepCount: Int
    @State private var open: Bool?

    var body: some View {
        let isOpen = open ?? isStreaming
        VStack(alignment: .leading, spacing: 4) {
            Button { open = !isOpen } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text(tr("chat", "message_list.process_steps", ["count": stepCount]))
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        ChatUITimelineRow(item: item).equatable()
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Color.primary.opacity(0.025)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.border))
            }
        }
        .onChange(of: isStreaming) { was, now in
            if was && !now { open = false }
        }
    }
}

struct ChatUITimelineRow: View, Equatable {
    let item: ChatUITimelineItem
    @State private var open = false

    static func == (a: ChatUITimelineRow, b: ChatUITimelineRow) -> Bool { a.item == b.item }

    var body: some View {
        switch item.kind {
        case .text:
            ChatUIRichText(source: ChatUIText.displayMarkdown(ChatUITimeline.stripQuickActionsProtocol(item.content), attachments: nil), font: Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        case .toolUse:
            toolCall
        case .toolResult:
            toolResult
        case .thinking:
            thinking
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.destructive)
                Text(item.content).foregroundStyle(Theme.destructive).textSelection(.enabled)
            }
            .font(Theme.Font.caption)
            .padding(.vertical, 2)
        }
    }

    private var toolCall: some View {
        let hasInput: Bool = {
            if case .object(let o)? = item.input { return !o.isEmpty }
            return false
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Button { if hasInput { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .opacity(hasInput ? 1 : 0)
                    Text(item.tool ?? "").fontWeight(.medium)
                    Text(ChatUIText.toolSummary(item.input)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.caption)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, let input = item.input {
                ChatUICodeBox(text: input.prettyPrinted, maxHeight: 128)
            }
        }
    }

    @ViewBuilder
    private var toolResult: some View {
        let output = item.output ?? ""
        if !output.isEmpty {
            let prefix = item.tool.map { tr("chat", "message_list.tool_result_named", ["tool": $0]) } ?? tr("chat", "message_list.tool_result_unnamed")
            VStack(alignment: .leading, spacing: 2) {
                Button { open.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(prefix + (output.count > 120 ? String(output.prefix(120)) + "..." : output))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ChatUICodeBox(text: output.count > 4000 ? String(output.prefix(4000)) + "\n... (truncated)" : output, maxHeight: 160)
                }
            }
        }
    }

    @ViewBuilder
    private var thinking: some View {
        if !item.content.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Button { open.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "brain").foregroundStyle(.tertiary)
                        Text(item.content.count > 150 ? String(item.content.prefix(150)) + "..." : item.content)
                            .italic().foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Font.caption)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    ChatUICodeBox(text: item.content, maxHeight: 160, monospaced: false)
                }
            }
        }
    }
}

struct ChatUICodeBox: View {
    let text: String
    var maxHeight: CGFloat = 160
    var monospaced = true

    var body: some View {
        ScrollView {
            Text(text)
                .font(monospaced ? .system(size: 11, design: .monospaced) : Theme.Font.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Color.primary.opacity(0.045)))
        .padding(.leading, 18)
    }
}

// MARK: Footer, failure, status

/// "Replied in 38s · Copy" under a settled reply.
struct ChatUIMessageFooter: View {
    @Environment(Toaster.self) private var toaster
    let message: ChatMessage
    let items: [ChatUITimelineItem]
    let isPending: Bool

    var body: some View {
        let noResponse = message.messageKind == "no_response"
        let copy = ChatUITimeline.copyText(message, items: items)
        let showCopy = !isPending && !noResponse && !copy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if message.elapsedMs != nil || showCopy {
            HStack(spacing: 6) {
                if let ms = message.elapsedMs {
                    Text(tr("chat", noResponse ? "message_list.finished_in" : "message_list.replied_in", ["elapsed": ChatUIText.elapsed(ms: ms)]))
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                if showCopy {
                    Button {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(copy, forType: .string) {
                            toaster.success(tr("chat", "message_list.copied_toast"))
                        } else {
                            toaster.error(tr("chat", "message_list.copy_failed_toast"))
                        }
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(tr("chat", "message_list.copy_action"))
                    .accessibilityLabel(tr("chat", "message_list.copy_action"))
                }
            }
        }
    }
}

/// A failed turn as a low-key note: friendly copy per failure reason, the
/// raw error behind "Show details", and whatever process the run produced.
struct ChatUIFailureBubble: View {
    let reason: String
    let rawError: String
    let timeline: ChatUITaskTimeline?
    let elapsedMs: Int?
    @State private var open = false

    static let copyKeys: [String: String] = [
        "agent_error": "agent_error", "timeout": "timeout", "codex_semantic_inactivity": "codex_semantic_inactivity",
        "runtime_offline": "runtime_offline", "runtime_access_denied": "runtime_access_denied", "runtime_recovery": "runtime_recovery",
        "manual": "manual", "cancelled": "manual", "skill_bundle_unavailable": "skill_bundle_unavailable",
        "runtime_cli_timeout": "runtime_cli_timeout", "environment_prepare_failed": "environment_prepare_failed",
        "agent_error.provider_network": "provider_network", "agent_error.provider_auth_or_access": "provider_auth_or_access",
        "agent_error.provider_quota_limit": "provider_quota_limit", "agent_error.provider_capacity_or_rate_limit": "provider_capacity_or_rate_limit",
        "agent_error.context_overflow": "context_overflow", "agent_error.runtime_missing_executable": "runtime_missing_executable",
        "agent_error.runtime_version_unsupported": "runtime_version_unsupported",
    ]

    var body: some View {
        let key = ChatUIAgents.failureKey(reason, known: Set(Self.copyKeys.keys)).flatMap { Self.copyKeys[$0] } ?? "fallback"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.destructive).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("chat", "message_list.failure.\(key)")).font(Theme.Font.body).foregroundStyle(Theme.destructive)
                    if !rawError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { open.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                                Text(tr("chat", "message_list.show_details"))
                            }
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        if open {
                            ChatUICodeBox(text: rawError, maxHeight: 160).padding(.leading, -18)
                        }
                    }
                }
            }
            if let timeline, !timeline.items.isEmpty {
                ChatUITimelineView(timeline: timeline, settledAnswer: nil, isStreaming: false)
            }
            if let elapsedMs {
                Text(tr("chat", "message_list.failed_after", ["elapsed": ChatUIText.elapsed(ms: elapsedMs)]))
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Thinking · 12s": the running stage and an elapsed timer anchored on the
/// server's task creation time (locked on first render, so it never snaps
/// back). Only this view ticks every second.
struct ChatUIStatusPill: View {
    let pending: ChatPendingTask
    let timeline: ChatUITaskTimeline?
    let availability: String?
    @State private var anchor: Date?

    var body: some View {
        let status = ChatUIStage.effectiveStatus(pending.status, hasMessages: timeline?.hasMessages == true)
        let stage = ChatUIStage.pick(status: status, latest: timeline?.latestKind.map { ($0, timeline?.latestTool) }, availability: availability)
        let label = Self.label(stage, waitReason: status == "waiting_local_directory" ? pending.waitReason : nil)
        let start = anchor ?? pending.createdAt.flatMap(Timestamp.parse) ?? Date()
        HStack(spacing: 6) {
            if !stage.isStatic { ChatUIBreathingDot() }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let secs = max(0, Int(context.date.timeIntervalSince(start)))
                (Text(label) + Text(" · \(ChatUIText.elapsed(seconds: secs))").foregroundColor(.secondary.opacity(0.8)).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .font(Theme.Font.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .onAppear { if anchor == nil { anchor = start } }
        .accessibilityElement(children: .combine)
    }

    static func label(_ stage: ChatUIStage, waitReason: String?) -> String {
        if let tool = stage.tool { return tr("chat", "status_pill.tools.\(tool.rawValue)") }
        if stage.needsWaitReason, let r = waitReason?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            return tr("chat", "status_pill.stages.waiting_local_directory_reason", ["reason": r])
        }
        return tr("chat", "status_pill.stages.\(stage.key.rawValue)")
    }
}

/// Pulsing dot driven by Core Animation, never by re-rendering.
struct ChatUIBreathingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.25 : 0.8)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: Follow-ups

/// Wrapping row layout for pills and cards.
struct ChatUIFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            let w = min(size.width, bounds.width)
            if x > bounds.minX && x + w > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: size.height))
            x += w + spacing
            row = max(row, size.height)
        }
    }
}

/// Up to three follow-up pills; hovering shows the full prompt a click sends
/// in the member's name. The latest turn can regenerate them.
struct ChatUIQuickActions: View {
    @Environment(Toaster.self) private var toaster
    let actions: [ChatQuickAction]
    let disabled: Bool
    let pending: Bool
    let canRegenerate: Bool
    let onSelect: (ChatQuickAction) async -> Void
    let onRegenerate: () async throws -> Void
    @State private var submitting = false
    @State private var regenerating = false

    var body: some View {
        let blocked = disabled || submitting || regenerating || pending
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5).padding(.bottom, 8)
            ChatUIFlowLayout(spacing: 8) {
                Text(tr("chat", "message_list.quick_actions_heading")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .frame(height: 26)
                ForEach(Array(actions.prefix(3).enumerated()), id: \.offset) { _, action in
                    Button {
                        guard !blocked else { return }
                        submitting = true
                        Task {
                            await onSelect(action)
                            submitting = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(action.label).lineLimit(1)
                            if action.primary == true { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
                        }
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .foregroundStyle(action.primary == true ? Theme.brand : .primary)
                        .background(Capsule().fill(action.primary == true ? Theme.brand.opacity(0.1) : Color.clear))
                        .overlay(Capsule().strokeBorder(action.primary == true ? Theme.brand.opacity(0.25) : Theme.border))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(blocked)
                    .opacity(blocked ? 0.55 : 1)
                    .help(action.prompt)
                }
                if canRegenerate {
                    Button {
                        guard !blocked else { return }
                        regenerating = true
                        Task {
                            do { try await onRegenerate() } catch { toaster.error(tr("chat", "message_list.quick_actions_regenerate_failed")) }
                            regenerating = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .rotationEffect(.degrees(pending || regenerating ? 360 : 0))
                            .animation(pending || regenerating ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: pending || regenerating)
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .disabled(blocked)
                    .help(tr("chat", "message_list.quick_actions_regenerate"))
                    .accessibilityLabel(tr("chat", "message_list.quick_actions_regenerate"))
                }
            }
            .accessibilityLabel(tr("chat", "message_list.quick_actions_aria"))
        }
        .padding(.top, 8)
    }
}

struct ChatUIQuickActionsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5).padding(.bottom, 8)
            HStack(spacing: 8) {
                Text(tr("chat", "message_list.quick_actions_heading")).font(Theme.Font.caption).foregroundStyle(.secondary)
                ForEach([96, 128, 112], id: \.self) { w in
                    Capsule().fill(Color.primary.opacity(0.07)).frame(width: CGFloat(w), height: 26)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.top, 8)
    }
}

/// Product-fixed starter cards under Mika's onboarding opening (they replace
/// that turn's follow-up pills).
struct ChatUIOnboardingCards: View {
    let disabled: Bool
    let onPick: (ChatQuickAction) async -> Void
    @State private var submitting = false

    var body: some View {
        let cards: [(key: String, symbol: String)] = [("board", "square.grid.3x2"), ("delegate", "checklist"), ("digest", "clock")]
        ChatUIFlowLayout(spacing: 12) {
            ForEach(cards, id: \.key) { card in
                let title = tr("chat", "onboarding_cards.\(card.key).title")
                let prompt = tr("chat", "onboarding_cards.\(card.key).prompt")
                Button {
                    guard !disabled, !submitting else { return }
                    submitting = true
                    Task {
                        await onPick(ChatQuickAction(label: title, prompt: prompt))
                        submitting = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack {
                            LinearGradient(colors: [Color.primary.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                            VStack(spacing: 6) {
                                Image(systemName: card.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.brand.opacity(0.8))
                                if card.key == "digest" {
                                    Label(tr("chat", "onboarding_cards.digest_badge"), systemImage: "clock")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.brand)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.brand.opacity(0.12)))
                                }
                            }
                        }
                        .frame(height: 96)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                            Text(tr("chat", "onboarding_cards.\(card.key).desc")).font(Theme.Font.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                Text(tr("chat", "onboarding_cards.cta"))
                                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                            }
                            .font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(Theme.brand)
                        }
                        .padding(12)
                    }
                    .frame(width: 210, height: 220, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(disabled || submitting)
                .opacity(disabled || submitting ? 0.55 : 1)
                .help(prompt)
                .accessibilityLabel(title)
            }
        }
        .padding(.top, 12)
        .accessibilityLabel(tr("chat", "onboarding_cards.aria_label"))
    }
}
