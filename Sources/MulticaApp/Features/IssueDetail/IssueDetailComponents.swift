import AppKit
import MulticaCore
import SwiftUI

extension WorkspaceSession {
    /// Resolvers for issue-detail copy (activity text, wakeup conditions).
    var issueDetailNames: IssueDetailNames {
        let catalog = issues.catalog
        return IssueDetailNames(
            actor: { [unowned self] type, id in self.actorInfo(type: type, id: id).name },
            status: { catalog.localizedName(for: IssueStatusKey(rawValue: $0)) },
            priority: { IssuePriority(rawValue: $0)?.localizedName ?? $0 },
            date: { IssueDetailDates.short($0) },
            time: { Formatters.date($0, style: .abbreviated, time: .shortened) },
            label: { [unowned self] id in self.labels.item(id)?.name },
            property: { [unowned self] id in self.properties.item(id)?.name })
    }
}

enum IssueDetailDates {
    /// Upstream shortDate: "Mar 5" for date-only values, "—" when unset.
    static func short(_ value: String?) -> String {
        guard let value, !value.isEmpty, let d = Formatters.dateOnly(value) ?? Timestamp.parse(value) else { return "—" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    static func isPast(_ value: String?) -> Bool {
        guard let value, let d = Formatters.dateOnly(value) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    static func dateOnly(addingDays days: Int) -> String {
        Formatters.dateOnlyString(Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date())
    }
}

enum IssueDetailIDs {
    static func isUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }
}

extension IssueStatusKey {
    func issueDetailIsFinished(_ catalog: StatusCatalog) -> Bool {
        let c = builtInCategory ?? catalog.entry(for: self)?.category ?? .unstarted
        return c == .done || c == .closed
    }
}

/// Collapsible sidebar section heading (upstream detail sidebar buttons).
struct IssueDetailSectionHeader<Trailing: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Text(title).font(Theme.Font.caption.weight(.medium))
                        .foregroundStyle(open ? .primary : .secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .hoverHighlight()
        .padding(.bottom, 4)
    }
}

extension IssueDetailSectionHeader where Trailing == EmptyView {
    init(title: String, open: Binding<Bool>) {
        self.title = title
        self._open = open
        self.trailing = { EmptyView() }
    }
}

/// Done/total pill with a progress ring (sub-issue progress).
struct IssueDetailProgressChip: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            ProgressRing(value: total > 0 ? Double(done) / Double(total) : 0, size: 11, color: Theme.info)
            Text("\(done)/\(total)").font(Theme.Font.micro.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Upstream QuickEmojiPicker: eight quick reactions, then the full set.
struct IssueDetailEmojiPicker: View {
    let onSelect: (String) -> Void
    @State private var open = false
    @State private var showAll = false

    static let quick = ["👍", "👌", "❤️", "✅", "🎉", "😕", "🚀", "👀"]
    static let all: [String] = [
        "👍", "👎", "👌", "👏", "🙌", "🙏", "💪", "🤝", "✌️", "🤞", "👋", "👀", "🧠", "❤️", "🧡", "💛", "💚", "💙",
        "💜", "🖤", "💔", "✅", "❌", "⚠️", "❓", "❗️", "💯", "🔥", "✨", "⭐️", "🌟", "🎉", "🎊", "🏆", "🚀", "💡",
        "🐛", "🔧", "🛠️", "📌", "📎", "📝", "📈", "📉", "⏰", "⏳", "🔒", "🔑", "😀", "😃", "😄", "😁", "😆", "😅",
        "😂", "🤣", "😊", "🙂", "😉", "😍", "🥰", "😘", "😎", "🤓", "🤔", "🤨", "😐", "😑", "😶", "🙄", "😏", "😮",
        "😯", "😲", "😳", "🥺", "😢", "😭", "😤", "😠", "😡", "🤯", "😱", "😴", "🤒", "🤢", "🤮", "🥳", "🤗", "🤫",
        "🤐", "😕", "😟", "🙃", "🫡", "🫠", "👻", "💀", "🤖", "👾", "🐶", "🐱", "🦄", "🍕", "☕️", "🍺",
    ]

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "face.smiling").font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(tr("issues", "comment.add_reaction"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                if showAll {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 9), spacing: 2) {
                            ForEach(Self.all, id: \.self) { e in emojiButton(e) }
                        }
                        .padding(6)
                    }
                    .frame(width: 300, height: 220)
                } else {
                    HStack(spacing: 2) { ForEach(Self.quick, id: \.self) { e in emojiButton(e) } }
                    Button(trd("ui", "emoji.more", "More emojis...")) { showAll = true }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .onDisappear { showAll = false }
        }
    }

    private func emojiButton(_ e: String) -> some View {
        Button {
            open = false
            onSelect(e)
        } label: {
            Text(e).font(.system(size: 17)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.small)
    }
}

struct IssueDetailReactionGroup: Hashable, Identifiable {
    var emoji: String
    var actors: [ActorRef]
    var mine: Bool
    var id: String { emoji }

    static func group(_ items: [(emoji: String, type: String, id: String)], me: String) -> [IssueDetailReactionGroup] {
        var order: [String] = []
        var byEmoji: [String: IssueDetailReactionGroup] = [:]
        for r in items {
            if byEmoji[r.emoji] == nil {
                order.append(r.emoji)
                byEmoji[r.emoji] = IssueDetailReactionGroup(emoji: r.emoji, actors: [], mine: false)
            }
            byEmoji[r.emoji]?.actors.append(ActorRef(type: r.type, id: r.id))
            if r.type == "member" && r.id == me { byEmoji[r.emoji]?.mine = true }
        }
        return order.compactMap { byEmoji[$0] }
    }
}

/// Upstream ReactionBar: one chip per emoji with its count; mine are tinted.
struct IssueDetailReactionBar: View {
    @Environment(WorkspaceSession.self) private var session
    let groups: [IssueDetailReactionGroup]
    var showPicker = false
    let onToggle: (String) -> Void

    var body: some View {
        if !groups.isEmpty || showPicker {
            HStack(spacing: 4) {
                ForEach(groups) { g in
                    Button { onToggle(g.emoji) } label: {
                        HStack(spacing: 3) {
                            Text(g.emoji).font(.system(size: 12))
                            Text("\(g.actors.count)").font(Theme.Font.caption).monospacedDigit()
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().fill(g.mine ? Theme.brand.opacity(0.12) : Color.primary.opacity(0.03)))
                        .overlay(Capsule().strokeBorder(g.mine ? Theme.brand.opacity(0.4) : Theme.border))
                    }
                    .buttonStyle(.plain)
                    .help(g.actors.map { session.actorInfo(type: $0.type, id: $0.id).name }.joined(separator: ", "))
                }
                if showPicker { IssueDetailEmojiPicker(onSelect: onToggle) }
            }
        }
    }
}

/// Attachments a comment carries that its Markdown does not reference
/// (upstream AttachmentList): images full width, other files as cards.
struct IssueDetailAttachmentList: View {
    @Environment(Navigator.self) private var nav
    let attachments: [Attachment]
    var content: String = ""
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
        let standalone = attachments.filter { a in
            content.isEmpty || !(content.contains(a.id) || (!a.markdownUrl.isEmpty && content.contains(a.markdownUrl)) || content.contains(a.url))
        }
        if !standalone.isEmpty {
            let images = standalone.filter { $0.contentType.hasPrefix("image/") }
            let files = standalone.filter { !$0.contentType.hasPrefix("image/") }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(images) { a in
                    ZStack(alignment: .topTrailing) {
                        RemoteImage(url: ImageLoader.resolve(a.downloadUrl.isEmpty ? a.url : a.downloadUrl)) {
                            RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.05)).frame(height: 120)
                        }
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 400, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                        .onTapGesture { nav.push(.attachmentPreview(a.id)) }
                        removeButton(a)
                    }
                }
                if !files.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(files) { a in
                            HStack(spacing: 8) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.filename).font(Theme.Font.caption.weight(.medium)).lineLimit(1)
                                    Text(Formatters.bytes(Int64(a.sizeBytes))).font(Theme.Font.micro).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                removeButton(a)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color.primary.opacity(0.03)))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
                            .contentShape(Rectangle())
                            .onTapGesture { nav.push(.attachmentPreview(a.id)) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func removeButton(_ a: Attachment) -> some View {
        if let onRemove {
            Button { onRemove(a.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }
}

/// Upstream RevisionConflictCompare: both versions side by side with an
/// action under each.
struct IssueDetailRevisionCompare: View {
    let title: String
    let server: String
    let local: String
    let onUseServer: () -> Void
    let onKeepLocal: () -> Void
    var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.warning)
            HStack(alignment: .top, spacing: 8) {
                column(tr("issues", "revision.server_version"), server) {
                    Button(tr("issues", "revision.use_server"), action: onUseServer)
                }
                column(tr("issues", "revision.local_version"), local) {
                    Button(tr("issues", "revision.keep_local"), action: onKeepLocal).disabled(saving)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large).fill(Theme.warning.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(Theme.warning.opacity(0.3)))
    }

    private func column<A: View>(_ label: String, _ text: String, @ViewBuilder action: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Theme.Font.micro.weight(.medium)).foregroundStyle(.secondary)
            ScrollView {
                Text(text).font(Theme.Font.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            action().controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Color(nsColor: .textBackgroundColor)))
    }
}

/// Stacked avatars with an overflow count (upstream AvatarGroup).
struct IssueDetailAvatarStack: View {
    let actors: [ActorRef]
    var max = 4
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: -5) {
            ForEach(Array(actors.prefix(max).enumerated()), id: \.offset) { _, a in
                ActorAvatar(type: a.type, id: a.id, size: size)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
            if actors.count > max {
                Text("+\(actors.count - max)")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
        }
    }
}

enum IssueDetailFiles {
    /// Native file picker (upstream FileUploadButton).
    @MainActor
    static func pick(multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
