import MulticaCore
import SwiftUI

extension Color {
    /// `#rrggbb` → Color; falls back to gray for anything else.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

enum Formatters {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ timestamp: String?) -> String {
        guard let timestamp, let date = Timestamp.parse(timestamp) else { return "" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

struct StatusIcon: View {
    let category: StatusCategory
    let color: String

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(Color(hex: color))
            .imageScale(.small)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch category {
        case .started: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .closed: return "xmark.circle.fill"
        default: return "circle.dashed"
        }
    }
}

extension StatusCatalog {
    func icon(for key: IssueStatusKey) -> StatusIcon {
        let entry = entry(for: key)
        return StatusIcon(category: entry?.category ?? key.builtInCategory ?? .unstarted, color: entry?.color ?? "#8a8f98")
    }
}

struct PriorityIcon: View {
    let priority: IssuePriority

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(priority == .urgent ? Color.orange : Color.secondary)
            .imageScale(.small)
            .frame(width: 16)
            .help(priority.label)
    }

    private var symbol: String {
        switch priority {
        case .urgent: return "exclamationmark.square.fill"
        case .high: return "cellularbars"
        case .medium: return "chart.bar.fill"
        case .low: return "chart.bar"
        case .none: return "minus"
        }
    }
}

struct Avatar: View {
    let name: String
    var isAgent = false
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(isAgent ? Color.purple.opacity(0.22) : Color.accentColor.opacity(0.18))
            if isAgent {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.purple)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}

struct ActorBadge: View {
    let ref: ActorRef?
    let directory: Directory
    var showName = false

    var body: some View {
        if let ref {
            let name = directory.name(of: ref)
            HStack(spacing: 4) {
                Avatar(name: name, isAgent: ref.type == "agent")
                if showName { Text(name).lineLimit(1) }
            }
            .help(name)
        } else {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.tertiary)
                .help("Unassigned")
        }
    }
}

struct LabelChip: View {
    let label: IssueLabel

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(hex: label.color)).frame(width: 6, height: 6)
            Text(label.name).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

/// Pulsing dot shown while agents work on an issue. It is a fixed node whose
/// animation is owned by Core Animation, so streamed messages never replace
/// it (the upstream MUL-7227 regression replaced a DOM node per message).
struct RunningIndicator: View {
    let count: Int
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            if count > 1 {
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .help(count == 1 ? "An agent is working on this" : "\(count) agents are working on this")
    }
}

struct TaskStatusPill: View {
    let status: TaskStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var label: String {
        switch status {
        case .queued: return "Queued"
        case .dispatched: return "Dispatched"
        case .waitingLocalDirectory: return "Waiting"
        case .deferred: return "Deferred"
        case .running: return "Running"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        default: return status.rawValue.capitalized
        }
    }

    private var color: Color {
        switch status {
        case .running: return .green
        case .completed: return .blue
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .orange
        }
    }
}

/// Markdown rendered from the background-parsed cache.
struct MarkdownText: View {
    let source: String
    @State private var rendered: AttributedString?

    var body: some View {
        Text(rendered ?? MarkdownCache.shared.cached(source) ?? AttributedString(source))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: source) {
                if MarkdownCache.shared.cached(source) == nil {
                    rendered = await MarkdownCache.shared.render(source)
                } else {
                    rendered = MarkdownCache.shared.cached(source)
                }
            }
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.bar)
    }
}
