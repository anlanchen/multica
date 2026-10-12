import AppKit
import MulticaCore
import SwiftUI

enum RuntimesPalette {
    static let chart1 = Color(light: 0x2171CC, dark: 0x59A6FF)
    static let chart2 = Color(light: 0x5894E0, dark: 0x4C88D3)
    static let chart3 = Color(light: 0x85B4F0, dark: 0x3F6AA1)
    static let chart4 = Color(light: 0xB4D0F5, dark: 0x364E6D)
    static let chart5 = Color(light: 0xD8E6F9, dark: 0x293442)
    static let muted = Color(light: 0xF4F4F5, dark: 0x27272A)
    static let card = Color(nsColor: .controlBackgroundColor)
}

// MARK: Provider logo

/// Upstream `ProviderLogo`: the runtime's CLI vendor mark, decoded once.
struct RuntimesProviderLogo: View {
    let provider: String
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = RuntimesProviderLogoCache.image(provider, dark: scheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "desktopcomputer")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
enum RuntimesProviderLogoCache {
    private static var images: [String: NSImage?] = [:]

    static func assetKey(_ provider: String) -> String {
        switch provider {
        case "omp": return "pi"
        case "qoderclicn": return "qoder"
        default: return provider
        }
    }

    static func image(_ provider: String, dark: Bool) -> NSImage? {
        let key = assetKey(provider)
        let cacheKey = "\(key)|\(dark)"
        if let hit = images[cacheKey] { return hit }
        var image: NSImage?
        if let svg = RuntimesProviderAssets.svg[key] {
            let themed = svg.replacingOccurrences(of: "currentColor", with: dark ? "#FAFAFA" : "#18181B")
            image = NSImage(data: Data(themed.utf8))
        } else if let b64 = RuntimesProviderAssets.raster[key], let data = Data(base64Encoded: b64) {
            image = NSImage(data: data)
        }
        images[cacheKey] = image
        return image
    }
}

/// Up to four provider marks, then `+N`.
struct RuntimesProviderStack: View {
    let providers: [String]

    var body: some View {
        let visible = providers.prefix(4)
        HStack(spacing: -4) {
            ForEach(Array(visible), id: \.self) { p in
                RuntimesProviderLogo(provider: p, size: 14)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
            }
            if providers.count > 4 {
                Text("+\(providers.count - 4)")
                    .font(Theme.Font.micro.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 3).fill(RuntimesPalette.muted))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border))
            }
        }
    }
}

// MARK: Health

extension RuntimesHealth {
    var label: String { tr("runtimes", "health.\(rawValue).label") }
    var detail: String { tr("runtimes", "health.\(rawValue).description") }

    var color: Color {
        switch self {
        case .online: return Theme.success
        case .recentlyLost: return Theme.warning
        case .offline: return Color.secondary.opacity(0.4)
        case .longOffline: return Theme.destructive
        }
    }

    var tone: Color {
        switch self {
        case .online: return Theme.success
        case .recentlyLost: return Theme.warning
        case .offline: return .secondary
        case .longOffline: return Theme.destructive
        }
    }
}

/// Wifi-style health glyph: shape for reachability, colour for severity.
struct RuntimesHealthIcon: View {
    let health: RuntimesHealth
    var size: CGFloat = 11

    var body: some View {
        Group {
            switch health {
            case .online: Image(systemName: "wifi")
            case .recentlyLost: Image(systemName: "wifi", variableValue: 0.55)
            case .offline, .longOffline: Image(systemName: "wifi.slash")
            }
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(health.tone)
        .help(health.detail)
    }
}

struct RuntimesHealthDot: View {
    let health: RuntimesHealth
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(health.color).frame(width: size, height: size)
    }
}

struct RuntimesHealthBadge: View {
    let health: RuntimesHealth

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(health.color).frame(width: 6, height: 6)
            Text(health.label)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(health.tone)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(health.tone.opacity(0.1)))
        .help(health.detail)
    }
}

// MARK: Small pieces

/// Tiny square tag (Built-in / Custom / Registering / This device).
struct RuntimesTag: View {
    let text: String
    var color: Color = .secondary
    var filled = false
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 2) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .semibold)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(filled ? Color(nsColor: .windowBackgroundColor) : color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(filled ? Color.primary : (color == .secondary ? RuntimesPalette.muted : color.opacity(0.1))))
        .lineLimit(1)
        .fixedSize()
    }
}

/// KPI tile: small caps label, big number, caption hint.
struct RuntimesKpiCard<Hint: View>: View {
    let label: String
    let value: String
    var accent: Color? = nil
    @ViewBuilder var hint: () -> Hint

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            hint().font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact pill segmented control (upstream usage-section `Segmented`).
struct RuntimesSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var disabled = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                let active = o.value == selection
                Button { selection = o.value } label: {
                    Text(o.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(active ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(active ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: active ? .black.opacity(0.08) : .clear, radius: 1, y: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(RuntimesPalette.muted))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }
}

/// Bordered card used for the runtime lists and detail blocks.
struct RuntimesCard<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(RuntimesPalette.card))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Upstream `CollectionPageHeader`: icon, title, count, tagline with a
/// learn-more link, actions on the right.
struct RuntimesCollectionHeader<Actions: View>: View {
    let icon: String
    let title: String
    var count: Int? = nil
    var description: String? = nil
    var learnMore: (label: String, url: URL)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        PageHeader {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(title).font(Theme.Font.bodyMedium).lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let description {
                    HStack(spacing: 4) {
                        Text(description).lineLimit(1)
                        if let learnMore { Link(learnMore.label, destination: learnMore.url).underline() }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                }
            }
        } trailing: {
            HStack(spacing: 8) { actions() }
        }
    }
}

/// Centered collection state (empty / not found / bootstrapping).
struct RuntimesStateView<Actions: View>: View {
    let icon: String
    let title: String
    var message: String? = nil
    var tone: Color = .secondary
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(tone)
                .frame(width: 48, height: 48)
                .background(Circle().fill(RuntimesPalette.muted))
            Text(title).font(Theme.Font.bodyMedium)
            if let message {
                Text(message).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            actions().padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
    }
}

extension RuntimesStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String? = nil, tone: Color = .secondary) {
        self.init(icon: icon, title: title, message: message, tone: tone) { EmptyView() }
    }
}

/// Monospaced shell command with an icon copy button.
struct RuntimesCommandRow: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            CopyButton(text: command).buttonStyle(.borderless).help(tr("runtimes", "connect.copy_aria"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(RuntimesPalette.muted))
    }
}

/// A short skeleton bar.
struct RuntimesSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color.primary.opacity(0.07))
            .frame(width: width, height: height)
    }
}

// MARK: Permissions & time

extension WorkspaceSession {
    /// Owner/admin of the workspace (upstream `role === "owner" || "admin"`).
    var runtimesIsAdmin: Bool {
        let role = memberRecords.items.first { $0.userId == currentUser.id }?.role
        return role == "owner" || role == "admin"
    }

    var runtimesStore: RuntimesStore { RuntimesStore.shared(for: self) }
}

/// Re-renders every 30 s so time-based health buckets stay honest.
struct RuntimesNowTick: ViewModifier {
    @Binding var tick: Int

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                tick &+= 1
            }
        }
    }
}

enum RuntimesDocs {
    /// `https://multica.ai/docs[/<lang>]/daemon-runtimes`.
    static func daemonRuntimes() -> URL {
        URL(string: "https://multica.ai/docs\(localePrefix())/daemon-runtimes")!
    }

    static func customRuntimes() -> URL {
        let lang = L10n.shared.language
        let anchor: String
        if lang.hasPrefix("zh") { anchor = "自定义运行时配置" }
        else if lang.hasPrefix("ja") { anchor = "カスタムランタイムプロファイル" }
        else if lang.hasPrefix("ko") { anchor = "사용자-지정-런타임-프로필" }
        else if lang.hasPrefix("fr") { anchor = "profils-de-runtime-personnalisés" }
        else { anchor = "custom-runtime-profiles" }
        let encoded = anchor.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? anchor
        return URL(string: daemonRuntimes().absoluteString + "#" + encoded)!
    }

    static func localePrefix() -> String {
        switch L10n.shared.language {
        case "zh-Hans": return "/zh"
        case "ja": return "/ja"
        case "ko": return "/ko"
        case "fr": return "/fr"
        default: return ""
        }
    }
}
