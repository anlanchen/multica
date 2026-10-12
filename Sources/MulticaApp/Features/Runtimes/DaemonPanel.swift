import AppKit
import MulticaCore
import SwiftUI

/// Local daemon status and controls, compact enough for the menu bar.
/// Status comes from the adaptive `/health` poller.
struct DaemonPanel: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RuntimesDaemonContextBadge(status: env.daemonStatus, runtimeCount: env.runtimesLocalRuntimeCount)
                Spacer()
            }
            RuntimesDaemonControls(compact: true)
            if let message = env.daemonStatus.message, env.daemonStatus.state != .running {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
            }
            Toggle(tr("settings", "desktop.daemon.auto_start_title"), isOn: $settings.autoStartDaemon)
                .font(.callout)
                .disabled(env.daemonStatus.externallyManaged)
            if let daemon = env.daemon {
                Text("\(tr("settings", "desktop.daemon.profile")) \(daemon.profile.name) · :\(daemon.profile.healthPort)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

extension AppEnvironment {
    /// Runtimes this Mac's daemon registered (context badge).
    var runtimesLocalRuntimeCount: Int {
        guard let id = daemonStatus.health?.daemonID, let session = app.session else { return 0 }
        return session.runtimeRecords.items.filter { $0.daemonId == id }.count
    }
}

enum RuntimesDaemonStateStyle {
    static func color(_ state: DaemonState) -> Color {
        switch state {
        case .running: return Color(red: 0.06, green: 0.73, blue: 0.51)
        case .stopped, .failed, .unknown: return Color.secondary.opacity(0.4)
        case .starting, .stopping, .recoveryPaused: return Color(red: 0.96, green: 0.62, blue: 0.04)
        case .installingCLI: return Color(red: 0.05, green: 0.65, blue: 0.91)
        case .cliNotFound, .authExpired: return Color(red: 0.94, green: 0.27, blue: 0.27)
        }
    }

    static func pulses(_ state: DaemonState) -> Bool {
        state == .starting || state == .stopping || state == .installingCLI
    }
}

struct RuntimesDaemonStateDot: View {
    let state: DaemonState
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(RuntimesDaemonStateStyle.color(state))
            .frame(width: 6, height: 6)
            .opacity(RuntimesDaemonStateStyle.pulses(state) && dim ? 0.35 : 1)
            .onAppear { animate() }
            .onChange(of: state) { animate() }
    }

    private func animate() {
        dim = false
        guard RuntimesDaemonStateStyle.pulses(state) else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
    }
}

/// `● Running · 1h 2m · 3 runtimes`.
struct RuntimesDaemonContextBadge: View {
    let status: DaemonStatus
    let runtimeCount: Int

    var body: some View {
        let running = status.state == .running
        HStack(spacing: 6) {
            RuntimesDaemonStateDot(state: status.state)
            Text(status.state.label).foregroundStyle(running ? .primary : .secondary)
            if running, let uptime = status.health?.uptime, !uptime.isEmpty {
                Text("· \(RuntimesFormat.uptime(uptime))").foregroundStyle(.secondary)
            }
            if running, runtimeCount > 0 {
                Text("· \(tr("settings", "desktop.daemon.runtime_count", ["count": runtimeCount]))").foregroundStyle(.secondary)
            }
        }
        .font(Theme.Font.caption.monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
    }
}

// MARK: Log model

/// The daemon log while a viewer is open: a kqueue tail of the profile's
/// log file, parsed off the main actor into a 500-line ring.
@MainActor
@Observable
final class RuntimesDaemonLogModel {
    private(set) var lines: [RuntimesDaemonLogLine] = []
    private(set) var counts: [RuntimesDaemonLogLevel: Int] = [:]
    private(set) var displayed: [RuntimesDaemonLogItem] = []
    private(set) var filteredLines: [RuntimesDaemonLogLine] = []
    var search = "" { didSet { if search != oldValue { recompute() } } }
    var levels: Set<RuntimesDaemonLogLevel> = [.info, .warn, .error] { didSet { if levels != oldValue { recompute() } } }
    @ObservationIgnored private var tailer: LogTailer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextID = 0

    var hasActiveFilter: Bool { !search.isEmpty || levels.count < RuntimesDaemonLogLevel.allCases.count }
    var bufferFull: Bool { lines.count >= RuntimesDaemonLog.maxLines }

    func start(url: URL) {
        stop()
        lines = []
        counts = [:]
        nextID = 0
        recompute()
        let tailer = LogTailer(url: url)
        self.tailer = tailer
        tailer.start(backlogBytes: 32 * 1024)
        task = Task { [weak self] in
            var first = true
            for await batch in tailer.lines {
                guard let self, !Task.isCancelled else { return }
                // The first batch is the file's tail: keep its last 200 lines.
                let raw = (first ? Array(batch.suffix(200)) : batch).filter { !$0.isEmpty }
                first = false
                let parsed = await RuntimesDaemonLog.parseBatch(raw, firstID: self.nextID + 1)
                self.nextID += parsed.count
                self.append(parsed)
            }
        }
    }

    func stop() {
        tailer?.stop()
        tailer = nil
        task?.cancel()
        task = nil
    }

    func clear() {
        lines = []
        counts = [:]
        recompute()
    }

    func toggle(_ level: RuntimesDaemonLogLevel) {
        if levels.contains(level) { levels.remove(level) } else { levels.insert(level) }
    }

    private func append(_ parsed: [RuntimesDaemonLogLine]) {
        guard !parsed.isEmpty else { return }
        var next = lines + parsed
        if next.count > RuntimesDaemonLog.maxLines { next.removeFirst(next.count - RuntimesDaemonLog.maxLines) }
        lines = next
        var c: [RuntimesDaemonLogLevel: Int] = [:]
        for l in next { if let level = l.level { c[level, default: 0] += 1 } }
        counts = c
        recompute()
    }

    private func recompute() {
        filteredLines = RuntimesDaemonLog.filter(lines, levels: levels, search: search)
        displayed = RuntimesDaemonLog.fold(filteredLines)
    }
}

// MARK: Log viewer

/// The local daemon log viewer (desktop `DaemonPanel` dialog): search,
/// level toggles, folded repeats, expandable fields, follow mode.
struct DaemonLogView: View {
    @Environment(AppEnvironment.self) private var env
    var onClose: (() -> Void)? = nil
    @State private var model = RuntimesDaemonLogModel()
    @State private var autoScroll = true
    @State private var expandedFields: Set<Int> = []
    @State private var expandedGroups: Set<Int> = []
    @State private var lastProgrammaticScroll = Date.distantPast

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text(tr("settings", "desktop.daemon.logs_title")).font(Theme.Font.bodyMedium)
                RuntimesDaemonContextBadge(status: env.daemonStatus, runtimeCount: env.runtimesLocalRuntimeCount)
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .help(tr("settings", "desktop.daemon.close"))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            toolbar
            Divider()
            viewport
            Divider()
            HStack {
                HStack(spacing: 4) {
                    Text(tr("settings", "desktop.daemon.showing_logs", ["shown": model.filteredLines.count, "total": model.lines.count]))
                    if model.bufferFull { Text(tr("settings", "desktop.daemon.buffer_full")) }
                }
                .monospacedDigit()
                Spacer()
                if !autoScroll {
                    Button { autoScroll = true } label: { Label(tr("settings", "desktop.daemon.jump_latest"), systemImage: "arrow.down") }
                        .buttonStyle(.borderless)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))
        }
        .onAppear {
            if let url = env.daemon?.profile.logURL { model.start(url: url) }
        }
        .onDisappear { model.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            SearchField(text: $model.search, prompt: tr("settings", "desktop.daemon.search")).frame(width: 224)
            HStack(spacing: 4) {
                ForEach(RuntimesDaemonLogLevel.allCases, id: \.self) { level in
                    RuntimesLevelChip(level: level, active: model.levels.contains(level), count: model.counts[level] ?? 0) { model.toggle(level) }
                }
            }
            Spacer()
            Button { copy() } label: { Label(tr("settings", "desktop.daemon.copy"), systemImage: "doc.on.doc") }
                .disabled(model.filteredLines.isEmpty)
            Button {
                model.clear()
                expandedFields = []
                expandedGroups = []
            } label: { Label(tr("settings", "desktop.daemon.clear"), systemImage: "trash") }
                .disabled(model.lines.isEmpty)
        }
        .buttonStyle(.borderless)
        .font(Theme.Font.caption)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var viewport: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.displayed.isEmpty {
                    emptyState.frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.displayed) { item in
                            switch item {
                            case .line(let line):
                                lineRow(line)
                            case .group(let first, let rest):
                                groupRows(first, rest)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { autoScroll = true }
                            .onDisappear {
                                if Date().timeIntervalSince(lastProgrammaticScroll) > 0.4 { autoScroll = false }
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .background(Color.primary.opacity(0.02))
            .onChange(of: model.lines.last?.id) { follow(proxy) }
            .onChange(of: autoScroll) { if autoScroll { follow(proxy) } }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard autoScroll else { return }
        lastProgrammaticScroll = Date()
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    @ViewBuilder private var emptyState: some View {
        let running = env.daemonStatus.state == .running
        VStack(spacing: 4) {
            if model.hasActiveFilter && !model.lines.isEmpty {
                Text(tr("settings", "desktop.daemon.no_matching_logs")).font(Theme.Font.body)
                Text(tr("settings", "desktop.daemon.no_matching_logs_description")).font(Theme.Font.caption)
            } else if !running {
                Text(tr("settings", "desktop.daemon.not_running")).font(Theme.Font.body)
                Text(tr("settings", "desktop.daemon.not_running_description")).font(Theme.Font.caption)
            } else if model.lines.isEmpty {
                Text(tr("settings", "desktop.daemon.waiting_logs")).font(Theme.Font.body)
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func lineRow(_ line: RuntimesDaemonLogLine) -> some View {
        RuntimesLogLineRow(line: line, expanded: expandedFields.contains(line.id), search: model.search) {
            if expandedFields.contains(line.id) { expandedFields.remove(line.id) } else { expandedFields.insert(line.id) }
        }
    }

    @ViewBuilder
    private func groupRows(_ first: RuntimesDaemonLogLine, _ rest: [RuntimesDaemonLogLine]) -> some View {
        let open = expandedGroups.contains(first.id)
        lineRow(first)
        if open {
            ForEach(rest) { lineRow($0) }
        }
        Button {
            if open { expandedGroups.remove(first.id) } else { expandedGroups.insert(first.id) }
        } label: {
            HStack(spacing: 8) {
                Text("···")
                Text(open
                     ? tr("settings", "desktop.daemon.collapse_repeated", ["count": rest.count + 1])
                     : tr("settings", "desktop.daemon.more_repeated", ["count": rest.count, "message": RuntimesDaemonLog.truncate(first.message, max: 48)]))
            }
            .font(.system(size: 10).italic())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(open ? .clear : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(Color.secondary.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.vertical, 2)
    }

    private func copy() {
        let text = model.filteredLines.map(\.raw).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) {
            env.toaster.success(tr("settings", "desktop.daemon.copied_lines", ["count": model.filteredLines.count]))
        } else {
            env.toaster.error(tr("settings", "desktop.daemon.copy_failed"))
        }
    }
}

private struct RuntimesLevelChip: View {
    let level: RuntimesDaemonLogLevel
    let active: Bool
    let count: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(level.rawValue)
                Text("\(count)").monospacedDigit().foregroundStyle(active ? RuntimesLogLevelStyle.color(level) : .secondary)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(active ? RuntimesLogLevelStyle.color(level) : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: active ? [] : [3, 2]))
                .foregroundStyle(active ? RuntimesLogLevelStyle.border(level) : Theme.border))
        }
        .buttonStyle(.plain)
    }
}

enum RuntimesLogLevelStyle {
    static func color(_ level: RuntimesDaemonLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return Theme.warning
        case .error: return Theme.destructive
        }
    }

    static func border(_ level: RuntimesDaemonLogLevel) -> Color {
        switch level {
        case .debug: return Color.secondary.opacity(0.25)
        case .info: return Color.primary.opacity(0.15)
        case .warn: return Theme.warning.opacity(0.4)
        case .error: return Theme.destructive.opacity(0.4)
        }
    }
}

private struct RuntimesLogLineRow: View, Equatable {
    let line: RuntimesDaemonLogLine
    let expanded: Bool
    let search: String
    let toggle: () -> Void
    @State private var hovering = false

    static func == (a: RuntimesLogLineRow, b: RuntimesLogLineRow) -> Bool {
        a.line.id == b.line.id && a.expanded == b.expanded && a.search == b.search
    }

    var body: some View {
        if let timestamp = line.timestamp, let level = line.level {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timestamp).foregroundStyle(.secondary).monospacedDigit()
                Text(level.rawValue)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(RuntimesLogLevelStyle.color(level))
                    .padding(.horizontal, 3)
                    .frame(height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(RuntimesLogLevelStyle.border(level)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.highlight(line.message, search)).fixedSize(horizontal: false, vertical: true)
                        if !line.fields.isEmpty && !expanded {
                            Text(line.fields.map { "\($0.key)=\(RuntimesDaemonLog.truncate($0.value))" }.joined(separator: "  "))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if expanded && !line.fields.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                            ForEach(Array(line.fields.enumerated()), id: \.offset) { _, f in
                                GridRow {
                                    Text(f.key).foregroundStyle(.secondary)
                                    Text(f.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !line.fields.isEmpty { toggle() } }
        } else {
            Text(Self.highlight(line.raw, search))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func highlight(_ text: String, _ query: String) -> AttributedString {
        var out = AttributedString(text)
        guard !query.isEmpty, let r = text.range(of: query, options: .caseInsensitive),
              let ar = Range(r, in: out) else { return out }
        out[ar].backgroundColor = Theme.warning.opacity(0.3)
        return out
    }
}

/// A standalone window for the daemon log, reachable from the menu bar,
/// the machine header and settings.
@MainActor
enum RuntimesDaemonLogWindow {
    private static var window: NSWindow?

    static func show(_ env: AppEnvironment) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = DaemonLogView(onClose: { window?.close() })
            .environment(env)
            .environment(env.toaster)
            .frame(minWidth: 720, minHeight: 420)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 680),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = tr("settings", "desktop.daemon.logs_title")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: root)
        w.center()
        w.setFrameAutosaveName("multica.daemon.log")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                window?.contentView = nil
                window = nil
            }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
