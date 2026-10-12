import AppKit
import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

private func copyToPasteboard(_ s: String) -> Bool {
    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(s, forType: .string)
}

/// Webhook URL that hides its token until revealed (upstream
/// webhook-url-field). A reveal authorizes one URL: a rotated token must be
/// revealed again.
struct AutopilotsWebhookURLField<Actions: View>: View {
    @Environment(Toaster.self) private var toaster
    let url: String
    var large = false
    @ViewBuilder var actions: () -> Actions
    @State private var revealedURL: String?
    @State private var copied = false

    var body: some View {
        let revealed = revealedURL == url
        HStack(spacing: 6) {
            Group {
                if revealed {
                    Text(url).textSelection(.enabled)
                } else {
                    Button { revealedURL = url } label: {
                        Text(AutopilotsWebhook.masked(url)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t("trigger_row.show_url"))
                    .accessibilityLabel(t("trigger_row.hidden_url_aria"))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, large ? 10 : 8)
            .padding(.vertical, large ? 8 : 4)
            .background(RoundedRectangle(cornerRadius: large ? Theme.Radius.medium : Theme.Radius.small).fill(Color.primary.opacity(0.06)))
            .overlay {
                if large { RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border) }
            }
            iconButton(revealed ? "eye.slash" : "eye", help: revealed ? t("trigger_row.hide_url") : t("trigger_row.show_url")) {
                revealedURL = revealed ? nil : url
            }
            iconButton(copied ? "checkmark" : "doc.on.doc", help: t("trigger_row.copy_url"), tint: copied ? Theme.success : nil) {
                guard !url.isEmpty else { return }
                if copyToPasteboard(url) {
                    copied = true
                    toaster.success(t("trigger_row.url_copied"))
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } else {
                    toaster.error(t("trigger_row.url_copy_failed"))
                }
            }
            actions()
        }
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 13 : 11))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: large ? 32 : 26, height: large ? 32 : 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if large { RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Color.primary.opacity(0.15)) }
        }
        .hoverHighlight()
        .help(help)
        .accessibilityLabel(help)
    }
}

extension AutopilotsWebhookURLField where Actions == EmptyView {
    init(url: String, large: Bool = false) {
        self.url = url
        self.large = large
        self.actions = { EmptyView() }
    }
}

/// Copyable code block with a header and a 4 KiB on-screen cap.
struct AutopilotsCodeBlock: View {
    @Environment(Toaster.self) private var toaster
    let label: String
    let value: String
    var maxHeight: CGFloat = 190
    @State private var copied = false

    var body: some View {
        let truncated = value.count > AutopilotsWebhook.displayLimit
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                AutopilotsCopyChip(copied: copied) { copy() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(truncated ? String(value.prefix(AutopilotsWebhook.displayLimit)) : value)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if truncated {
                        Text(t("webhook_payload.truncated_marker")).font(Theme.Font.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: maxHeight)
            .background(Color.primary.opacity(0.03))
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }

    private func copy() {
        if copyToPasteboard(value) {
            copied = true
            toaster.success(t("webhook_payload.copied"))
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } else {
            toaster.error(t("webhook_payload.copy_failed"))
        }
    }
}

private struct AutopilotsCopyChip: View {
    let copied: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(copied ? Theme.success : .secondary)
                Text(copied ? t("webhook_payload.copied_short") : t("webhook_payload.copy"))
            }
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
    }
}

/// The webhook envelope of a run, collapsed by default (upstream
/// webhook-payload-preview).
struct AutopilotsWebhookPayloadPreview: View {
    @Environment(Toaster.self) private var toaster
    let envelope: AutopilotsWebhook.Envelope
    @State private var open = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(t("webhook_payload.label")).fontWeight(.medium)
                    Text(envelope.event ?? t("webhook_payload.unknown_event")).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let receivedAt = envelope.receivedAt {
                        Text(receivedAt).foregroundStyle(.secondary)
                    }
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .font(Theme.Font.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Divider()
                HStack {
                    Text(envelope.contentType.map { t("webhook_payload.content_type", ["type": $0]) } ?? t("webhook_payload.payload"))
                    Spacer()
                    AutopilotsCopyChip(copied: copied) {
                        if copyToPasteboard(envelope.fullJSON) {
                            copied = true
                            toaster.success(t("webhook_payload.copied"))
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } else {
                            toaster.error(t("webhook_payload.copy_failed"))
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(envelope.displayJSON).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if envelope.isTruncated {
                            Text(t("webhook_payload.truncated_marker")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 256)
                .background(Color.primary.opacity(0.03))
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }
}

/// Event filters of a webhook trigger (upstream webhook-event-filter-section).
struct AutopilotsEventFilterSection: View {
    @Binding var filters: [WebhookEventFilter]
    @State private var newEvent = ""
    @State private var newActions = ""

    private var docsURL: URL {
        let lang = L10n.shared.language
        if lang.hasPrefix("zh") {
            return URL(string: "https://multica.ai/docs/zh/autopilots#%E4%BA%8B%E4%BB%B6%E8%BF%87%E6%BB%A4")!
        }
        if lang.hasPrefix("fr") {
            return URL(string: "https://multica.ai/docs/fr/autopilots#filtres-d%C3%A9v%C3%A9nements")!
        }
        return URL(string: "https://multica.ai/docs/autopilots#event-filters")!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                AutopilotsFieldLabel(text: t("dialog.event_filter_label"))
                Link(destination: docsURL) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
                .help(t("dialog.event_filter_docs_link_label"))
                .accessibilityLabel(t("dialog.event_filter_docs_link_label"))
            }
            if !filters.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(filters.enumerated()), id: \.offset) { idx, f in
                        HStack(spacing: 6) {
                            Text(f.event).font(.system(size: 11, weight: .medium, design: .monospaced))
                            if let actions = f.actions, !actions.isEmpty {
                                Text(": \(actions.joined(separator: ", "))").foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button { filters.remove(at: idx) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(t("dialog.event_filter_remove_label"))
                            .accessibilityLabel(t("dialog.event_filter_remove_label"))
                        }
                        .font(Theme.Font.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                    }
                }
            }
            HStack(spacing: 6) {
                TextField(t("dialog.event_filter_event_placeholder"), text: $newEvent)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(add)
                TextField(t("dialog.event_filter_actions_placeholder"), text: $newActions)
                    .font(Theme.Font.caption)
                    .frame(width: 112)
                    .onSubmit(add)
                Button(action: add) {
                    Label(t("dialog.event_filter_add"), systemImage: "plus").font(Theme.Font.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newEvent.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            Text(t("dialog.event_filter_hint")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add() {
        guard let f = AutopilotsWebhook.makeFilter(event: newEvent, actions: newActions) else { return }
        filters.append(f)
        newEvent = ""
        newActions = ""
    }
}

// MARK: - Deliveries

private enum AutopilotsDeliveryVisual {
    static func color(_ status: String) -> Color {
        switch status {
        case "queued": return .blue
        case "dispatched": return Theme.success
        case "rejected", "failed": return Theme.destructive
        default: return .secondary
        }
    }

    static func symbol(_ status: String) -> String {
        switch status {
        case "queued": return "arrow.triangle.2.circlepath"
        case "dispatched": return "checkmark.circle"
        case "rejected": return "shield.slash"
        case "ignored": return "nosign"
        case "failed": return "xmark.circle"
        default: return "exclamationmark.triangle"
        }
    }

    static func label(_ status: String) -> String {
        ["queued", "dispatched", "rejected", "ignored", "failed"].contains(status) ? t("deliveries.status.\(status)") : status
    }

    static func date(_ iso: String) -> String { iso.isEmpty ? "—" : AutopilotsFormat.instant(iso) }
}

/// Webhook deliveries of an autopilot (upstream webhook-deliveries-section);
/// rendered and fetched only when it has a webhook trigger.
struct AutopilotsDeliveriesSection: View {
    @Environment(WorkspaceSession.self) private var session
    let autopilotID: String
    @State private var deliveries: [WebhookDelivery] = []
    @State private var loading = true
    @State private var openDelivery: WebhookDelivery?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AutopilotsSectionTitle(text: t("deliveries.section_title"))
            if loading {
                VStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in AutopilotsSkeleton(height: 36) } }
            } else if deliveries.isEmpty {
                AutopilotsDashedBox { Text(t("deliveries.empty")) }
            } else {
                AutopilotsRowsCard {
                    ForEach(Array(deliveries.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { Divider() }
                        AutopilotsDeliveryRow(delivery: d) { openDelivery = d }
                            .equatable()
                    }
                }
            }
        }
        .task(id: session.revision("autopilot")) { await load() }
        .sheet(item: $openDelivery) { d in
            AutopilotsDeliveryDetailSheet(autopilotID: autopilotID, delivery: d) { Task { await load() } }
        }
    }

    private func load() async {
        if let r = try? await session.api.listAutopilotDeliveries(autopilotId: autopilotID), r.deliveries != deliveries {
            deliveries = r.deliveries
        }
        loading = false
    }
}

private struct AutopilotsDeliveryRow: View, Equatable {
    let delivery: WebhookDelivery
    let onOpen: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.delivery == b.delivery }

    var body: some View {
        let d = delivery
        let color = AutopilotsDeliveryVisual.color(d.status)
        Button(action: onOpen) {
            HStack(spacing: 12) {
                if d.status == "queued" {
                    AutopilotsSpinner(size: 14, color: color)
                } else {
                    Image(systemName: AutopilotsDeliveryVisual.symbol(d.status)).foregroundStyle(color).frame(width: 14)
                }
                Text(AutopilotsDeliveryVisual.label(d.status)).font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                    .frame(width: 96, alignment: .leading)
                Text(d.provider.isEmpty ? "—" : d.provider).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 80, alignment: .leading)
                Text(d.event.isEmpty ? t("webhook_payload.unknown_event") : d.event)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if d.replayedFromDeliveryId != nil {
                    Label(t("deliveries.row.replay_badge"), systemImage: "arrow.clockwise").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                if d.attemptCount > 1 {
                    Text(t("deliveries.row.attempts", ["count": d.attemptCount])).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.border))
                }
                Text(AutopilotsDeliveryVisual.date(d.receivedAt.isEmpty ? d.createdAt : d.receivedAt))
                    .font(Theme.Font.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 128, alignment: .trailing)
            }
            .font(Theme.Font.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
    }
}

private struct AutopilotsDeliveryDetailSheet: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(Toaster.self) private var toaster
    @Environment(\.dismiss) private var dismiss
    let autopilotID: String
    let delivery: WebhookDelivery
    let onReplayed: () -> Void
    @State private var detail: WebhookDelivery?
    @State private var loading = true
    @State private var replaying = false

    var body: some View {
        let full = detail ?? delivery
        let color = AutopilotsDeliveryVisual.color(full.status)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                Text(t("deliveries.detail.title")).font(Theme.Font.title)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: AutopilotsDeliveryVisual.symbol(full.status)).foregroundStyle(color)
                            Text(AutopilotsDeliveryVisual.label(full.status)).font(Theme.Font.bodyMedium).foregroundStyle(color)
                        }
                        badge(full.provider.isEmpty ? "—" : full.provider, outline: true)
                        Text(full.event.isEmpty ? t("webhook_payload.unknown_event") : full.event)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Color.primary.opacity(0.06)))
                        signatureBadge(full.signatureStatus)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            meta(t("deliveries.detail.received_at"), AutopilotsDeliveryVisual.date(full.receivedAt))
                            meta(t("deliveries.detail.last_attempt_at"), AutopilotsDeliveryVisual.date(full.lastAttemptAt))
                        }
                        GridRow {
                            meta(t("deliveries.detail.attempt_count"), String(full.attemptCount))
                            meta(t("deliveries.detail.dispatch_attempts"), String(full.dispatchAttempts))
                        }
                        GridRow {
                            if full.status == "queued" {
                                meta(t("deliveries.detail.available_at"), AutopilotsDeliveryVisual.date(full.availableAt))
                            }
                            meta(t("deliveries.detail.response_status"), full.responseStatus.map { String(Int($0)) } ?? "—")
                        }
                        GridRow {
                            meta(t("deliveries.detail.dedupe_key"), full.dedupeKey ?? "—", mono: true)
                            meta(t("deliveries.detail.dedupe_source"), full.dedupeSource ?? "—")
                        }
                        if full.contentType != nil || full.replayedFromDeliveryId != nil {
                            GridRow {
                                if let ct = full.contentType { meta(t("deliveries.detail.content_type"), ct, mono: true) }
                                if let from = full.replayedFromDeliveryId { meta(t("deliveries.detail.replayed_from"), from, mono: true) }
                            }
                        }
                    }
                    if let error = full.error, !error.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("deliveries.detail.error_label")).fontWeight(.medium)
                            Text(error).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.destructive)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.destructive.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.destructive.opacity(0.3)))
                    }
                    if loading && detail == nil {
                        AutopilotsSkeleton(height: 96)
                        AutopilotsSkeleton(height: 64)
                    } else if let detail {
                        if let raw = detail.rawBody, !raw.isEmpty {
                            AutopilotsCodeBlock(label: t("deliveries.detail.raw_body"), value: raw)
                        }
                        if let headers = detail.selectedHeaders, !headers.isEmpty {
                            AutopilotsCodeBlock(label: t("deliveries.detail.selected_headers"), value: AutopilotsWebhook.prettyJSON(.object(headers)))
                        }
                        if let body = detail.responseBody, !body.isEmpty {
                            AutopilotsCodeBlock(label: t("deliveries.detail.response_body"), value: body)
                        }
                    }
                    HStack {
                        if let hint = AutopilotsWebhook.replayHintKey(full) {
                            Text(t("deliveries.replay.\(hint)")).font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await replay(full) } } label: {
                            HStack(spacing: 5) {
                                if replaying { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                                Text(replaying ? t("deliveries.replay.in_progress") : t("deliveries.replay.action"))
                            }
                        }
                        .controlSize(.small)
                        .disabled(!AutopilotsWebhook.canReplay(full) || replaying)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 640)
        .frame(minHeight: 360, maxHeight: 720)
        .task {
            detail = try? await session.api.getAutopilotDelivery(autopilotId: autopilotID, deliveryId: delivery.id)
            loading = false
        }
    }

    private func replay(_ d: WebhookDelivery) async {
        replaying = true
        defer { replaying = false }
        do {
            _ = try await session.api.replayAutopilotDelivery(autopilotId: autopilotID, deliveryId: d.id)
            toaster.success(t("deliveries.replay.toast_success"))
            onReplayed()
            dismiss()
        } catch {
            toaster.error((error as? APIError)?.message ?? t("deliveries.replay.toast_failed"))
        }
    }

    private func meta(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(mono ? .system(size: 11, design: .monospaced) : Theme.Font.caption).lineLimit(1).truncationMode(.middle)
                .help(value).textSelection(.enabled)
        }
        .font(Theme.Font.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(_ text: String, outline: Bool) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(outline ? Color.clear : Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(outline ? Theme.border.opacity(2) : .clear))
    }

    private func signatureBadge(_ status: String) -> some View {
        let label = ["not_required", "valid", "invalid", "missing"].contains(status) ? t("deliveries.signature.\(status)") : status
        let (fg, bg): (Color, Color) = {
            switch status {
            case "valid": return (Color(nsColor: .windowBackgroundColor), Color.primary)
            case "invalid": return (.white, Theme.destructive)
            case "missing": return (.primary, Color.primary.opacity(0.1))
            default: return (.primary, .clear)
            }
        }()
        return Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(status == "not_required" || !["valid", "invalid", "missing"].contains(status) ? Theme.border.opacity(2) : .clear))
    }
}
