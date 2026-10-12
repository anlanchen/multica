import AppKit
import MulticaCore
import SwiftUI

/// Workspace property glyph (upstream PROPERTY_ICON_OPTIONS, Lucide keys
/// mapped to SF Symbols). No icon set → nothing drawn.
struct IssueModalPropertyIcon: View {
    let key: String?

    var body: some View {
        if let key, !key.isEmpty {
            Image(systemName: Self.symbol(key)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    static func symbol(_ key: String) -> String {
        switch key {
        case "circle-dot": return "smallcircle.filled.circle"
        case "signal-high": return "cellularbars"
        case "user-round": return "person"
        case "folder-kanban": return "folder"
        case "calendar-days": return "calendar"
        case "tag": return "tag"
        case "milestone": return "signpost.right"
        case "flag": return "flag"
        case "bookmark": return "bookmark"
        case "star": return "star"
        case "target": return "scope"
        case "shield": return "shield"
        case "bug": return "ladybug"
        case "zap": return "bolt"
        case "rocket": return "paperplane"
        case "sparkles": return "sparkles"
        case "lightbulb": return "lightbulb"
        case "globe-2": return "globe"
        case "link": return "link"
        case "hash": return "number"
        case "list-checks": return "checklist"
        case "circle-check": return "checkmark.circle"
        case "clock-3": return "clock"
        case "briefcase-business": return "briefcase"
        case "layers-3": return "square.3.layers.3d"
        case "gauge": return "gauge.medium"
        case "database": return "cylinder"
        case "code-2": return "chevron.left.forwardslash.chevron.right"
        case "palette": return "paintpalette"
        case "megaphone": return "megaphone"
        case "map-pin": return "mappin"
        case "package": return "shippingbox"
        case "wrench": return "wrench"
        case "heart": return "heart"
        case "circle-alert": return "exclamationmark.circle"
        case "lock-keyhole": return "lock"
        default: return "square.on.circle"
        }
    }
}

enum IssueModalProperties {
    static let editableTypes: Set<String> = ["select", "multi_select", "date", "checkbox", "text", "number", "url",
                                             "actor", "multi_actor", "multi_text", "multi_url"]

    /// Archived definitions, types newer than this build, and actor values
    /// of unknown kinds degrade to read-only (Clear stays available).
    static func isReadOnly(_ p: IssueProperty, _ value: JSONValue?) -> Bool {
        if p.archived || p.archivedAt != nil { return true }
        if !editableTypes.contains(p.type) { return true }
        if p.type == "actor" && IssueModalActorRefs.hasUnknown(value) { return true }
        return false
    }

    static func strings(_ value: JSONValue?) -> [String] {
        if case .array(let a)? = value { return a.compactMap(\.stringValue) }
        return []
    }
}

/// Read view of a custom property value (upstream CustomPropertyValueDisplay).
struct IssueModalPropertyValueDisplay: View {
    @Environment(WorkspaceSession.self) private var session
    let property: IssueProperty
    let value: JSONValue?

    var body: some View {
        if let value {
            content(value)
        } else {
            empty
        }
    }

    private var empty: some View {
        Text(tr("issues", "pickers.custom_property.empty")).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func content(_ value: JSONValue) -> some View {
        let options = property.config?.options ?? []
        switch property.type {
        case "select":
            if let o = options.first(where: { $0.id == value.stringValue }) {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: o.color)).frame(width: 8, height: 8)
                    Text(o.name).lineLimit(1)
                }
            } else {
                empty
            }
        case "multi_select":
            let ids = IssueModalProperties.strings(value)
            let chosen = options.filter { ids.contains($0.id) }
            if chosen.isEmpty {
                empty
            } else {
                HStack(spacing: 3) {
                    ForEach(chosen) { o in
                        HStack(spacing: 3) {
                            Circle().fill(Color(hex: o.color)).frame(width: 6, height: 6)
                            Text(o.name).lineLimit(1)
                        }
                        .font(Theme.Font.micro)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.border))
                    }
                }
            }
        case "actor", "multi_actor":
            let refs = IssueModalActorRefs.refs(value)
            if refs.isEmpty {
                if !IssueModalActorRefs.rawValues(value).isEmpty {
                    Text(tr("issues", "pickers.custom_property.unknown_value")).foregroundStyle(.secondary)
                } else {
                    empty
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(refs, id: \.self) { r in
                        ActorAvatar(type: r.type, id: r.id, size: 14, showName: true, nameFont: Theme.Font.caption)
                    }
                }
            }
        case "multi_text", "multi_url":
            let items = IssueModalProperties.strings(value)
            if items.isEmpty {
                empty
            } else {
                HStack(spacing: 3) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 3) {
                            if property.type == "multi_url" { Image(systemName: "arrow.up.right.square").font(.system(size: 8)).foregroundStyle(.secondary) }
                            Text(item).lineLimit(1)
                        }
                        .font(Theme.Font.micro)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.border))
                    }
                }
            }
        case "date":
            HStack(spacing: 4) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(value.stringValue.map(IssueModalDates.short) ?? "")
            }
        case "checkbox":
            Text(value.boolValue == true ? tr("issues", "pickers.custom_property.true_label") : tr("issues", "pickers.custom_property.false_label"))
        case "url":
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square").font(.system(size: 9)).foregroundStyle(.secondary)
                Text(value.stringValue ?? "").lineLimit(1)
            }
        default:
            Text(value.stringValue ?? "").monospacedDigit().lineLimit(1)
        }
    }
}

/// Mutation-free value editor for one custom property (upstream
/// CustomPropertyValueInput): the create dialog writes into the draft.
struct IssueModalPropertyEditor: View {
    @Environment(WorkspaceSession.self) private var session
    let property: IssueProperty
    let value: JSONValue?
    let onChange: (JSONValue?) -> Void
    let dismiss: () -> Void

    var body: some View {
        if IssueModalProperties.isReadOnly(property, value) {
            VStack(alignment: .leading, spacing: 0) {
                emptyRow
                Text(property.archived || property.archivedAt != nil
                     ? tr("issues", "pickers.custom_property.archived_hint")
                     : tr("issues", "pickers.custom_property.unknown_value_hint"))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .padding(.vertical, 4)
            .frame(width: 256)
        } else {
            editor
        }
    }

    private var emptyRow: some View {
        Button {
            onChange(nil)
            dismiss()
        } label: {
            HStack {
                Text(tr("issues", "pickers.custom_property.none")).foregroundStyle(.secondary)
                Spacer()
                if value == nil { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .font(Theme.Font.body)
        }
        .buttonStyle(HoverRowButtonStyle())
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var editor: some View {
        let options = property.config?.options ?? []
        switch property.type {
        case "select":
            IssueModalOptionList(
                options: [noneOption] + options.map { o in
                    IssueModalOption(id: o.id, title: o.name, leading: AnyView(Circle().fill(Color(hex: o.color)).frame(width: 10, height: 10)))
                },
                selected: [value?.stringValue ?? "__none__"],
                searchable: options.count > 7
            ) { id in
                onChange(id == "__none__" ? nil : .string(id))
                dismiss()
            }
        case "multi_select":
            let chosen = IssueModalProperties.strings(value)
            IssueModalOptionList(
                options: [noneOption] + options.map { o in
                    IssueModalOption(id: o.id, title: o.name, leading: AnyView(Circle().fill(Color(hex: o.color)).frame(width: 10, height: 10)))
                },
                selected: chosen.isEmpty ? ["__none__"] : Set(chosen),
                searchable: options.count > 7
            ) { id in
                if id == "__none__" {
                    onChange(nil)
                    dismiss()
                    return
                }
                let next = chosen.contains(id) ? chosen.filter { $0 != id } : chosen + [id]
                onChange(next.isEmpty ? nil : .array(next.map(JSONValue.string)))
            }
        case "actor", "multi_actor":
            actorEditor
        case "multi_text", "multi_url":
            IssueModalListPropertyEditor(property: property, value: value, onChange: onChange)
        case "date":
            IssueModalDateMenu(value: value?.stringValue, emptyLabel: tr("issues", "pickers.custom_property.none")) { day in
                onChange(day.map(JSONValue.string))
                dismiss()
            }
        case "checkbox":
            IssueModalOptionList(
                options: [noneOption,
                          IssueModalOption(id: "true", title: tr("issues", "pickers.custom_property.true_label")),
                          IssueModalOption(id: "false", title: tr("issues", "pickers.custom_property.false_label"))],
                selected: [value?.boolValue.map { $0 ? "true" : "false" } ?? "__none__"],
                searchable: false,
                width: 200
            ) { id in
                onChange(id == "__none__" ? nil : .bool(id == "true"))
                dismiss()
            }
        default:
            IssueModalTextPropertyEditor(property: property, value: value, onChange: onChange, dismiss: dismiss)
        }
    }

    private var noneOption: IssueModalOption {
        IssueModalOption(id: "__none__", title: tr("issues", "pickers.custom_property.none"), isEmptyValue: true)
    }

    @ViewBuilder
    private var actorEditor: some View {
        let multiple = property.type == "multi_actor"
        let raw = IssueModalActorRefs.rawValues(value)
        let atCapacity = multiple && raw.count >= IssueModalActorRefs.maxValues
        IssueModalOptionList(
            options: [noneOption] + session.directory.members.map { m in
                let key = IssueModalActorRefs.format(kind: "member", id: m.userID)
                return IssueModalOption(id: key, title: m.name, group: tr("issues", "pickers.assignee.members_group"),
                                        disabled: atCapacity && !raw.contains(key),
                                        leading: AnyView(AvatarView(name: m.name, url: m.avatarURL, size: 16)))
            },
            selected: raw.isEmpty ? ["__none__"] : Set(raw),
            searchPlaceholder: tr("issues", "pickers.custom_property.actor_search_placeholder")
        ) { key in
            if key == "__none__" {
                onChange(nil)
                dismiss()
            } else if multiple {
                onChange(IssueModalActorRefs.toggle(raw, key: key).map { .array($0.map(JSONValue.string)) })
            } else {
                onChange(.string(key))
                dismiss()
            }
        }
    }
}

/// text / number / url: an input, ↩ commits, empty clears.
private struct IssueModalTextPropertyEditor: View {
    let property: IssueProperty
    let value: JSONValue?
    let onChange: (JSONValue?) -> Void
    let dismiss: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            if property.type == "url", let s = value?.stringValue, let url = URL(string: s) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help(tr("issues", "pickers.custom_property.open_link"))
            }
        }
        .padding(8)
        .frame(width: 256)
        .onAppear {
            draft = value?.stringValue ?? ""
            focused = true
        }
    }

    private var placeholder: String {
        switch property.type {
        case "url": return tr("issues", "pickers.custom_property.url_placeholder")
        case "number": return tr("issues", "pickers.custom_property.number_placeholder")
        default: return tr("issues", "pickers.custom_property.value_placeholder")
        }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if value != nil { onChange(nil) }
            dismiss()
            return
        }
        if property.type == "number" {
            guard let n = Double(trimmed) else { return }
            onChange(.number(n))
        } else {
            onChange(.string(trimmed))
        }
        dismiss()
    }
}

/// multi_text / multi_url: removable rows above an appending input.
private struct IssueModalListPropertyEditor: View {
    let property: IssueProperty
    let value: JSONValue?
    let onChange: (JSONValue?) -> Void
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let items = IssueModalProperties.strings(value)
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            HStack(spacing: 4) {
                                Text(item).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                if property.type == "multi_url", let url = URL(string: item) {
                                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                                        .buttonStyle(.borderless)
                                        .help(tr("issues", "pickers.custom_property.open_link"))
                                }
                                Button { save(items.filter { $0 != item }) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .help(tr("issues", "pickers.custom_property.remove_item", ["value": item]))
                            }
                            .font(Theme.Font.body)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .hoverHighlight(cornerRadius: Theme.Radius.small)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            TextField(property.type == "multi_url" ? tr("issues", "pickers.custom_property.url_placeholder")
                      : tr("issues", "pickers.custom_property.value_placeholder"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { add(items) }
                .onChange(of: draft) { error = nil }
            if let error {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
        }
        .padding(8)
        .frame(width: 256)
        .onAppear { focused = true }
    }

    private func add(_ items: [String]) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if property.type == "multi_url", !(trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")) {
            error = tr("issues", "pickers.custom_property.url_scheme_required")
            return
        }
        if items.contains(trimmed) {
            draft = ""
            return
        }
        save(items + [trimmed])
        draft = ""
    }

    private func save(_ next: [String]) {
        onChange(next.isEmpty ? nil : .array(next.map(JSONValue.string)))
    }
}
