import MulticaCore
import SwiftUI

/// The upstream issue status glyph (packages/views/issues/components/
/// status-icon.tsx), drawn with the same 14×14 geometry.
struct StatusIcon: View {
    enum Glyph: String {
        case dotted, circle, half, threeQuarters = "three_quarters", check, slash, cross
    }

    let glyph: Glyph
    let color: Color
    var size: CGFloat = 14

    init(glyph: Glyph, color: Color, size: CGFloat = 14) {
        self.glyph = glyph
        self.color = color
        self.size = size
    }

    /// Resolves glyph and color like upstream: built-ins use their semantic
    /// color, custom statuses their own `#rrggbb` and icon.
    init(status key: IssueStatusKey, entry: IssueStatusEntry? = nil, size: CGFloat = 14) {
        let category = entry?.category ?? key.builtInCategory ?? .unstarted
        let glyph: Glyph
        let color: Color
        switch key {
        case .backlog: glyph = .dotted; color = .secondary
        case .todo: glyph = .circle; color = .secondary
        case .inProgress: glyph = .half; color = Theme.warning
        case .inReview: glyph = .threeQuarters; color = Theme.success
        case .done: glyph = .check; color = Theme.info
        case .blocked: glyph = .slash; color = Theme.destructive
        case .cancelled: glyph = .cross; color = .secondary
        default:
            glyph = entry?.icon.flatMap(Glyph.init(rawValue:)) ?? StatusIcon.glyph(for: category)
            color = entry.map { Color(hex: $0.color) } ?? StatusIcon.color(for: category)
        }
        self.init(glyph: glyph, color: color, size: size)
    }

    static func glyph(for category: StatusCategory) -> Glyph {
        switch category {
        case .started: return .half
        case .done: return .check
        case .closed: return .cross
        default: return .circle
        }
    }

    static func color(for category: StatusCategory) -> Color {
        switch category {
        case .started: return Theme.warning
        case .done: return Theme.info
        default: return .secondary
        }
    }

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 14
            ctx.scaleBy(x: s, y: s)
            let cx = 7.0, cy = 7.0, outer = 6.0, fillR = 3.5
            let shading = GraphicsContext.Shading.color(color)
            func ring() {
                let r = Path(ellipseIn: CGRect(x: cx - outer, y: cy - outer, width: outer * 2, height: outer * 2))
                ctx.stroke(r, with: shading, lineWidth: 1.5)
            }
            func pie(_ progress: Double) {
                var p = Path()
                p.move(to: CGPoint(x: cx, y: cy))
                p.addLine(to: CGPoint(x: cx, y: cy - fillR))
                p.addArc(center: CGPoint(x: cx, y: cy), radius: fillR, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress), clockwise: false)
                p.closeSubpath()
                ctx.fill(p, with: shading)
            }
            switch glyph {
            case .dotted:
                for i in 0..<16 {
                    let a = Double(i) / 16 * .pi * 2 - .pi / 2
                    let x = cx + outer * cos(a), y = cy + outer * sin(a)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.55, y: y - 0.55, width: 1.1, height: 1.1)), with: shading)
                }
            case .circle:
                ring()
            case .half:
                ring(); pie(0.5)
            case .threeQuarters:
                ring(); pie(0.75)
            case .check:
                ring()
                ctx.fill(Path(ellipseIn: CGRect(x: cx - outer, y: cy - outer, width: outer * 2, height: outer * 2)), with: shading)
                var m = Path()
                m.move(to: CGPoint(x: 4.35, y: 7.85))
                m.addLine(to: CGPoint(x: 5.95, y: 9.45))
                m.addLine(to: CGPoint(x: 10.35, y: 4.85))
                ctx.stroke(m, with: .color(.white), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            case .slash:
                ring()
                var l = Path()
                l.move(to: CGPoint(x: cx + fillR * cos(.pi * 0.75), y: cy - fillR * sin(.pi * 0.75)))
                l.addLine(to: CGPoint(x: cx + fillR * cos(-.pi * 0.25), y: cy - fillR * sin(-.pi * 0.25)))
                ctx.stroke(l, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .cross:
                ring()
                var x = Path()
                x.move(to: CGPoint(x: 5, y: 5)); x.addLine(to: CGPoint(x: 9, y: 9))
                x.move(to: CGPoint(x: 9, y: 5)); x.addLine(to: CGPoint(x: 5, y: 9))
                ctx.stroke(x, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The upstream priority glyph (priority-icon.tsx): bars, urgent badge, or a dash.
struct PriorityIcon: View {
    let priority: IssuePriority
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 16
            ctx.scaleBy(x: s, y: s)
            switch priority {
            case .none:
                var p = Path()
                p.move(to: CGPoint(x: 3, y: 8)); p.addLine(to: CGPoint(x: 13, y: 8))
                ctx.stroke(p, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            case .urgent:
                ctx.fill(Path(roundedRect: CGRect(x: 2, y: 2, width: 12, height: 12), cornerRadius: 3), with: .color(Theme.destructive))
                var l = Path()
                l.move(to: CGPoint(x: 8, y: 5)); l.addLine(to: CGPoint(x: 8, y: 8.6))
                ctx.stroke(l, with: .color(.white), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: 7.05, y: 10.05, width: 1.9, height: 1.9)), with: .color(.white))
            default:
                let filled = PriorityIcon.bars(priority)
                let color = PriorityIcon.color(priority)
                let heights: [CGFloat] = [6, 9, 12]
                for i in 0..<3 {
                    let h = heights[i]
                    let rect = CGRect(x: 2.5 + CGFloat(i) * 4, y: 14 - h, width: 3, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(i < filled ? color : color.opacity(0.25)))
                }
            }
        }
        .frame(width: size, height: size)
        .help(priority.localizedName)
        .accessibilityLabel(priority.localizedName)
    }

    static func bars(_ p: IssuePriority) -> Int {
        switch p {
        case .urgent: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .none: return 0
        }
    }

    static func color(_ p: IssuePriority) -> Color {
        switch p {
        case .urgent: return Theme.destructive
        case .high, .medium: return Theme.warning
        case .low: return Theme.info
        case .none: return .secondary
        }
    }
}

extension IssuePriority {
    /// Upstream display order in pickers: none first, then urgent → low.
    static let displayOrder: [IssuePriority] = [.none, .urgent, .high, .medium, .low]

    var localizedName: String { tr("issues", "priority.\(rawValue)") }
}

extension IssueStatusKey {
    var localizedBuiltInName: String? {
        builtInName == nil ? nil : tr("issues", "status.\(rawValue)")
    }
}

extension StatusCatalog {
    /// Display name: localized for built-ins, the custom name otherwise.
    func localizedName(for key: IssueStatusKey) -> String {
        if let e = entry(for: key), !e.isSystem { return e.name }
        return key.localizedBuiltInName ?? displayName(for: key)
    }

    func icon(for key: IssueStatusKey, size: CGFloat = 14) -> StatusIcon {
        StatusIcon(status: key, entry: entry(for: key), size: size)
    }
}
