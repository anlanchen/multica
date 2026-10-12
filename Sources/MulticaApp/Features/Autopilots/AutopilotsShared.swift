import AppKit
import MulticaCore
import SwiftUI

private func t(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    tr("autopilots", key, args)
}

/// Date formatting shared by the autopilot screens (upstream
/// `formatInTimeZone`, `toLocaleDateString`).
enum AutopilotsFormat {
    static var locale: Locale { Locale(identifier: L10n.shared.language) }

    /// "Jul 13, 15:00" on the given zone's clock (the reader's when nil); an
    /// unparseable timestamp comes back as itself.
    static func instant(_ iso: String, timeZone: String? = nil) -> String {
        guard let date = Timestamp.parse(iso) else { return iso }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        style.locale = locale
        if let id = timeZone, let zone = TimeZone(identifier: id) { style.timeZone = zone }
        return date.formatted(style)
    }

    static func shortDate(_ iso: String) -> String {
        guard let date = Timestamp.parse(iso) else { return iso }
        var style = Date.FormatStyle(date: .numeric, time: .omitted)
        style.locale = locale
        return date.formatted(style)
    }

    static func relative(_ iso: String?) -> String { Formatters.relative(iso) }
}

/// Section heading of the detail page (uppercase, muted).
struct AutopilotsSectionTitle: View {
    let text: String
    var destructive = false

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.bodyMedium)
            .tracking(0.8)
            .foregroundStyle(destructive ? AnyShapeStyle(Theme.destructive) : AnyShapeStyle(.secondary))
    }
}

/// Small uppercase label above a dialog section.
struct AutopilotsFieldLabel: View {
    let text: String
    var required = false

    var body: some View {
        HStack(spacing: 2) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            if required {
                Text("*").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.destructive).accessibilityHidden(true)
            }
        }
    }
}

/// Dashed placeholder box (empty triggers / runs / deliveries).
struct AutopilotsDashedBox<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(Theme.Font.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(padding)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border.opacity(2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

/// Grey placeholder bar used by loading skeletons.
struct AutopilotsSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.primary.opacity(0.07))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Bordered card that groups rows (run history, deliveries).
struct AutopilotsRowsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
    }
}

/// A confirmation dialog that stays open, with its buttons disabled, while
/// the action runs (upstream AlertDialog with a pending state).
struct AutopilotsConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    var warning: String? = nil
    let cancelLabel: String
    let confirmLabel: String
    let busyLabel: String
    var destructive = true
    /// Returns whether the dialog should close.
    let action: () async -> Bool
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.Font.title)
            Text(message).font(Theme.Font.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning {
                Text(warning).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(cancelLabel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
                Button(role: destructive ? .destructive : nil) {
                    busy = true
                    Task {
                        let close = await action()
                        busy = false
                        if close { dismiss() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(busy ? busyLabel : confirmLabel)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .tint(destructive ? Theme.destructive : nil)
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(busy)
    }
}

/// Status of a run (upstream RUN_VISUAL): color and SF Symbol.
enum AutopilotsRunVisual {
    static func status(_ raw: String) -> String {
        AutopilotsRuns.knownStatuses.contains(raw) ? raw : "issue_created"
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "issue_created", "running": return .blue
        case "completed": return Theme.success
        case "failed": return Theme.destructive
        default: return .secondary
        }
    }

    static func symbol(_ status: String) -> String {
        switch status {
        case "issue_created": return "clock"
        case "running": return "arrow.triangle.2.circlepath"
        case "skipped": return "nosign"
        case "completed": return "checkmark.circle"
        case "failed": return "xmark.circle"
        default: return "clock"
        }
    }

    /// Dot color of the list's last-run cell.
    static func dot(_ status: String?) -> Color {
        switch status {
        case "completed", "issue_created": return .green
        case "failed": return .red
        case "skipped": return .orange
        case "running": return .blue
        default: return Color.secondary.opacity(0.4)
        }
    }
}

/// Spinning glyph for "running" states.
struct AutopilotsSpinner: View {
    var size: CGFloat = 14
    var color: Color = .blue
    @State private var spin = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: size * 0.85))
            .foregroundStyle(color)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
            .frame(width: size, height: size)
    }
}

// MARK: - Mutations

/// The autopilot writes every screen shares, keeping `session.autopilots`
/// current the way upstream's mutation hooks keep the list query current.
@MainActor
enum AutopilotsActions {
    /// Pauses or resumes each row not already in `status`; optimistic, rolled
    /// back on failure.
    static func setStatus(_ rows: [Autopilot], _ status: String, session: WorkspaceSession, toaster: Toaster) async {
        for row in rows where row.status != status {
            let previous = session.autopilots.item(row.id) ?? row
            var optimistic = previous
            optimistic.status = status
            session.autopilots.upsert(optimistic)
            do {
                let updated = try await session.api.updateAutopilot(row.id, UpdateAutopilotRequest(status: status))
                session.autopilots.upsert(updated)
            } catch {
                session.autopilots.upsert(previous)
                toaster.error(error)
                return
            }
        }
    }

    /// Deletes rows one by one; stops at the first failure.
    static func delete(_ rows: [Autopilot], session: WorkspaceSession) async throws {
        for row in rows {
            try await session.api.deleteAutopilot(row.id)
            session.autopilots.remove(row.id)
        }
    }
}

/// Detail-only data of one autopilot: the record with its triggers and
/// collaborators, and its run history. Refetched on `autopilot` revisions.
@MainActor
@Observable
final class AutopilotsDetailModel {
    let id: String
    var detail: GetAutopilotResponse?
    var isLoading = true
    var runs: [AutopilotRun] = []
    var runsLoading = true

    init(id: String) {
        self.id = id
    }

    var autopilot: Autopilot? { detail?.autopilot }
    var triggers: [AutopilotTrigger] { detail?.triggers ?? [] }
    var collaborators: [AutopilotCollaborator] { detail?.collaborators ?? [] }

    func load(_ session: WorkspaceSession) async {
        let api = session.api
        let id = self.id
        async let detailTask = try? api.getAutopilot(id)
        async let runsTask = try? api.listAutopilotRuns(id)
        let (d, r) = await (detailTask, runsTask)
        if let d, d.autopilot != nil {
            if d != detail { detail = d }
            if let a = d.autopilot, session.autopilots.isLoaded { session.autopilots.upsert(a) }
        } else if detail == nil || d != nil {
            detail = nil
        }
        isLoading = false
        if let r, r.runs != runs { runs = r.runs }
        runsLoading = false
    }

    func reloadRuns(_ session: WorkspaceSession) async {
        if let r = try? await session.api.listAutopilotRuns(id), r.runs != runs { runs = r.runs }
        runsLoading = false
    }

    func apply(_ autopilot: Autopilot, session: WorkspaceSession) {
        detail?.autopilot = autopilot
        if session.autopilots.isLoaded { session.autopilots.upsert(autopilot) }
    }

    func setCollaborators(_ list: [AutopilotCollaborator]) {
        detail?.collaborators = list
    }
}

extension View {
    /// Pointing-hand cursor over clickable non-button areas.
    func autopilotsLinkCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// The localized label of a known enum value, else the raw server value.
enum AutopilotsLabels {
    static func executionMode(_ mode: String) -> String {
        mode == "create_issue" || mode == "run_only" ? t("execution_mode.\(mode)") : mode
    }

    static func triggerKind(_ kind: String) -> String {
        ["schedule", "webhook", "api"].contains(kind) ? t("trigger_kind.\(kind)") : kind
    }

    static func triggerSymbol(_ kind: String) -> String {
        switch kind {
        case "schedule": return "clock"
        case "webhook": return "point.3.connected.trianglepath.dotted"
        case "api": return "chevron.left.forwardslash.chevron.right"
        default: return "bolt"
        }
    }

    static func runStatus(_ status: String) -> String {
        AutopilotsRuns.knownStatuses.contains(status) ? t("run_status.\(status)") : status
    }

    static func runSource(_ source: String) -> String {
        ["schedule", "manual", "webhook", "api"].contains(source) ? t("run_source.\(source)") : source
    }

    static func status(_ status: String) -> String {
        ["active", "paused", "archived"].contains(status) ? t("status.\(status)") : status
    }
}
