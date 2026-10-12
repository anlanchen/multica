import AppKit
import MulticaCore
import SwiftUI

/// Shared color picker (upstream color-picker.tsx): the palette, a hex
/// field, Random, and the system color panel for anything else. Values
/// travel as `#rrggbb`.
struct SettingsColorPickerButton<Label: View>: View {
    @Binding var color: String
    @ViewBuilder var label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SettingsColorPanel(color: $color)
            }
    }
}

struct SettingsColorPanel: View {
    @Binding var color: String
    @State private var hexDraft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(get: { Color(hex: color) }, set: { if let hex = Self.hex($0) { commit(hex) } }), supportsOpacity: false)
                    .labelsHidden()
                    .help(tr("common", "color_picker.saturation"))
                TextField("", text: Binding(get: { hexDraft ?? color }, set: { draft in
                    hexDraft = draft
                    if let hex = SettingsColor.normalizeHex(draft) { color = hex }
                }))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { hexDraft = nil }
                .accessibilityLabel(tr("common", "color_picker.hex"))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("common", "color_picker.presets")).font(Theme.Font.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                    ForEach(SettingsColor.presets, id: \.self) { preset in
                        Button { commit(preset) } label: {
                            Circle().fill(Color(hex: preset))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(SettingsColor.normalizeHex(color) == preset ? 0.8 : 0.1),
                                                               lineWidth: SettingsColor.normalizeHex(color) == preset ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset)
                    }
                }
            }
            Button { commit(SettingsColor.random(avoiding: color)) } label: {
                Label(tr("common", "color_picker.random"), systemImage: "dice")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 220)
    }

    private func commit(_ hex: String) {
        hexDraft = nil
        color = hex
    }

    static func hex(_ color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

/// Swatch + hex trigger used by the label and status editors.
struct SettingsColorField<Swatch: View>: View {
    @Binding var color: String
    @ViewBuilder var swatch: () -> Swatch

    var body: some View {
        SettingsColorPickerButton(color: $color) {
            HStack(spacing: 10) {
                swatch()
                Text(color.uppercased()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(Theme.settingsCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
    }
}
