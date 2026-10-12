import MulticaCore
import SwiftUI

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

