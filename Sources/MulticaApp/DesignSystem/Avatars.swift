import AppKit
import MulticaCore
import SwiftUI

/// Small image cache for avatars, logos and attachment thumbnails. Images are
/// decoded once and shared by every row that shows them.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()
    /// API origin used to resolve server-relative paths (`/uploads/...`).
    static var baseURL: URL?

    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 500
    }

    /// Upstream `resolvePublicFileUrl`: absolute URLs pass through, `/x` is
    /// joined to the API origin.
    static func resolve(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") {
            guard let base = baseURL else { return nil }
            var s = base.absoluteString
            while s.hasSuffix("/") { s.removeLast() }
            return URL(string: s + raw)
        }
        return URL(string: raw)
    }

    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let task = inflight[url] { return await task.value }
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = NSImage(data: data) else { return nil }
            return image
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// An image from a URL with a placeholder while it loads (cached).
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? url.flatMap({ ImageLoader.shared.cached($0) }) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ImageLoader.shared.load(url)
        }
    }
}

enum AvatarKind {
    case member, agent, squad, workspace

    init(actorType: String) {
        switch actorType {
        case "agent": self = .agent
        case "squad": self = .squad
        default: self = .member
        }
    }
}

/// Round avatar with initials fallback (agents: rounded square, robot glyph).
struct AvatarView: View {
    let name: String
    var url: String? = nil
    var kind: AvatarKind = .member
    var size: CGFloat = 20

    var body: some View {
        let resolved = ImageLoader.resolve(url)
        RemoteImage(url: resolved) { fallback }
            .frame(width: size, height: size)
            .clipShape(shape)
            .accessibilityLabel(name)
    }

    private var shape: AnyShape {
        switch kind {
        case .member: return AnyShape(Circle())
        case .agent, .squad: return AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        case .workspace: return AnyShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }

    @ViewBuilder private var fallback: some View {
        ZStack {
            Rectangle().fill(background)
            switch kind {
            case .agent:
                Image(systemName: "cpu")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.purple)
            case .squad:
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.teal)
            default:
                Text(AvatarView.initials(name))
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(kind == .workspace ? .white : Theme.brand)
            }
        }
    }

    private var background: Color {
        switch kind {
        case .agent: return Color.purple.opacity(0.16)
        case .squad: return Color.teal.opacity(0.16)
        case .workspace: return AvatarView.tint(for: name)
        case .member: return Theme.brand.opacity(0.14)
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" }).prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    /// Deterministic workspace tint from the name.
    static func tint(for name: String) -> Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count].opacity(0.85)
    }
}

/// Avatar for a workspace (upstream WorkspaceAvatar).
struct WorkspaceAvatar: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 20

    var body: some View {
        AvatarView(name: name, url: url, kind: .workspace, size: size)
    }
}

/// Resolves an actor (member/agent/squad) from the session directory.
struct ActorAvatar: View {
    @Environment(WorkspaceSession.self) private var session
    let type: String
    let id: String
    var size: CGFloat = 20
    var showName = false
    var nameFont: Font = Theme.Font.body

    var body: some View {
        let info = session.actorInfo(type: type, id: id)
        HStack(spacing: 6) {
            AvatarView(name: info.name, url: info.avatarURL, kind: AvatarKind(actorType: type), size: size)
            if showName {
                Text(info.name).font(nameFont).lineLimit(1)
            }
        }
        .help(info.name)
    }
}

struct ActorInfo {
    var name: String
    var avatarURL: String?
}

extension WorkspaceSession {
    /// Name and avatar for an actor reference, from whatever catalog knows it.
    func actorInfo(type: String, id: String) -> ActorInfo {
        switch type {
        case "agent":
            if let a = directory.agent(id) { return ActorInfo(name: a.name, avatarURL: a.avatarURL) }
            if let a = agentRecords.item(id) { return ActorInfo(name: a.name, avatarURL: a.avatarUrl) }
        case "squad":
            if let s = squads.item(id) { return ActorInfo(name: s.name, avatarURL: s.avatarUrl) }
        default:
            if let m = directory.member(userID: id) { return ActorInfo(name: m.name, avatarURL: m.avatarURL) }
            if id == currentUser.id { return ActorInfo(name: currentUser.name, avatarURL: currentUser.avatarURL) }
        }
        return ActorInfo(name: directory.name(type: type, id: id), avatarURL: nil)
    }
}
