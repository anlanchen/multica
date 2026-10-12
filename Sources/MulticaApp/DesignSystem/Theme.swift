import AppKit
import MulticaCore
import SwiftUI

/// Design tokens from the upstream UI package (packages/ui/styles/tokens.css),
/// converted from oklch to sRGB, with light and dark variants.
enum Theme {
    static let brand = Color(light: 0x0070E3, dark: 0x4390EE)
    static let success = Color(light: 0x1C882D, dark: 0x4AA651)
    static let warning = Color(light: 0xDCA400, dark: 0xCB9400)
    static let destructive = Color(light: 0xE7000B, dark: 0xFF6467)
    static let info = Color(light: 0x0072D5, dark: 0x4390EE)
    static let sidebar = Color(light: 0xF3F3F4, dark: 0x18181B)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let muted = Color.secondary
    static let border = Color.primary.opacity(0.08)
    static let hover = Color.primary.opacity(0.05)
    static let selected = Color.primary.opacity(0.08)

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 10
    }

    enum Spacing {
        static let page: CGFloat = 24
        static let row: CGFloat = 8
    }

    /// Upstream text scale (text-caption / text-body / text-title).
    enum Font {
        static let micro = SwiftUI.Font.system(size: 10)
        static let caption = SwiftUI.Font.system(size: 11)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let pageTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }
}

extension Color {
    /// A color with separate light/dark sRGB values (0xRRGGBB).
    init(light: UInt32, dark: UInt32) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    /// `#rrggbb` (or `rrggbb`) → Color; gray for anything else.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        self = Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Shared formatting helpers (dates, sizes, durations, tokens, money).
enum Formatters {
    static func relative(_ timestamp: String?) -> String {
        guard let timestamp, let date = Timestamp.parse(timestamp) else { return "" }
        return relative(date)
    }

    /// Upstream `timeAgo`: just now / {{count}}m / {{count}}h / {{count}}d
    /// ago, then an absolute date after a month.
    static func relative(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return tr("common", "time.just_now") }
        if s < 3600 { return tr("common", "time.minutes_ago", ["count": Int(s / 60)]) }
        if s < 86400 { return tr("common", "time.hours_ago", ["count": Int(s / 3600)]) }
        if s < 86400 * 30 { return tr("common", "time.days_ago", ["count": Int(s / 86400)]) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func date(_ timestamp: String?, style: Date.FormatStyle.DateStyle = .abbreviated, time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        guard let timestamp, let d = Timestamp.parse(timestamp) ?? dateOnly(timestamp) else { return "" }
        return d.formatted(date: style, time: time)
    }

    /// Parses `YYYY-MM-DD` (due/start dates are date-only upstream).
    static func dateOnly(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    static func dateOnlyString(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(ms: Double) -> String {
        let s = ms / 1000
        if s < 1 { return "\(Int(ms))ms" }
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        if m < 60 { return "\(m)m \(Int(s) % 60)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    static func compact(_ n: Double) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func usd(_ n: Double) -> String {
        n.formatted(.currency(code: "USD").precision(.fractionLength(n < 1 ? 4 : 2)))
    }
}

/// `tr` with a fallback for keys the upstream catalogs do not define.
func trd(_ ns: String, _ key: String, _ fallback: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    let s = tr(ns, key, args)
    return s == key ? fallback : s
}
