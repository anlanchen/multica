import MulticaCore
import SwiftUI

/// Files tab: the file rail (main + supporting) and the selected file's
/// preview or editor (upstream FilesTab / FileTree / FileViewer).
struct SkillsFilesTab: View {
    @Bindable var model: SkillsDetailModel
    let canEdit: Bool

    var body: some View {
        let paths = model.filePaths
        let supporting = paths.filter { $0 != SkillsFiles.skillMD }
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    railHeading(tr("skills", "detail.files.main"))
                    SkillsFileTree(model: model, paths: [SkillsFiles.skillMD], allPaths: paths, canEdit: canEdit)
                    railHeading(tr("skills", "detail.files.supporting", ["count": supporting.count])).padding(.top, 12)
                    if !supporting.isEmpty {
                        SkillsFileTree(model: model, paths: supporting, allPaths: paths, canEdit: canEdit)
                    } else if !model.addingFile {
                        Text(tr("skills", "detail.files.supporting_empty"))
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    if canEdit {
                        if model.addingFile {
                            SkillsAddFileInline(model: model, existing: paths).padding(.top, 6)
                        } else {
                            Button { model.addingFile = true } label: {
                                Label(tr("skills", "detail.files.add_file"), systemImage: "plus")
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(HoverRowButtonStyle())
                            .padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .frame(width: 216)
            .accessibilityLabel(tr("skills", "detail.files.list_aria"))
            Divider()
            SkillsFilePane(model: model, canEdit: canEdit)
        }
    }

    private func railHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct SkillsFilePane: View {
    @Bindable var model: SkillsDetailModel
    let canEdit: Bool

    var body: some View {
        let path = model.selectedPath
        let isMarkdown = SkillsFiles.isMarkdown(path)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if isMarkdown {
                    Picker("", selection: $model.fileMode) {
                        Text(tr("skills", "detail.files.mode_preview")).tag(SkillsFileMode.preview)
                        Text(canEdit ? tr("skills", "detail.files.mode_edit") : tr("skills", "detail.files.mode_raw")).tag(SkillsFileMode.raw)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .accessibilityLabel(tr("skills", "detail.files.mode_aria"))
                }
                if path != SkillsFiles.skillMD && canEdit {
                    Button { model.deleteFile() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(tr("skills", "detail.delete_file"))
                        .accessibilityLabel(tr("skills", "detail.delete_file"))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Divider() }

            if isMarkdown && model.fileMode == .preview {
                SkillsMarkdownPreview(model: model, path: path)
            } else {
                SkillsCodeEditor(
                    text: Binding(get: { model.content(at: path) }, set: { model.setContent($0, at: path) }),
                    language: SkillsFiles.highlightLanguage(for: path),
                    isEditable: canEdit,
                    placeholder: isMarkdown ? tr("skills", "file_viewer.markdown_placeholder") : tr("skills", "file_viewer.raw_placeholder"),
                    focusToken: model.focusPath == path ? model.focusToken : 0,
                    onFocusHandled: { model.focusPath = nil }
                )
                .id(path)
                .accessibilityLabel(tr("skills", "file_viewer.raw_aria", ["path": path]))
            }
        }
    }
}

/// Rendered Markdown without the frontmatter, which the Overview tab
/// already shows as properties.
private struct SkillsMarkdownPreview: View {
    let model: SkillsDetailModel
    let path: String

    var body: some View {
        let body = model.previewBody(model.content(at: path))
        ScrollView {
            MarkdownView(source: body.isEmpty ? tr("skills", "file_viewer.no_content") : body)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Tree

private struct SkillsFileTree: View {
    let model: SkillsDetailModel
    let paths: [String]
    let allPaths: [String]
    let canEdit: Bool

    var body: some View {
        let tree = model.tree(paths)
        if tree.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.tertiary)
                Text(tr("skills", "file_tree.no_files")).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ForEach(tree) { node in
                SkillsTreeNodeView(model: model, node: node, depth: 0, allPaths: allPaths, canEdit: canEdit)
            }
        }
    }
}

private struct SkillsTreeNodeView: View {
    let model: SkillsDetailModel
    let node: SkillsFileNode
    let depth: Int
    let allPaths: [String]
    let canEdit: Bool
    @State private var expanded = true

    var body: some View {
        if node.isDirectory {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 10)
                    Image(systemName: expanded ? "folder.fill" : "folder").font(.system(size: 11))
                    Text(node.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(depth) * 12 + 2)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverRowButtonStyle())
            if expanded {
                ForEach(node.children) { child in
                    SkillsTreeNodeView(model: model, node: child, depth: depth + 1, allPaths: allPaths, canEdit: canEdit)
                }
            }
        } else {
            SkillsFileRow(model: model, node: node, depth: depth, allPaths: allPaths, canEdit: canEdit)
        }
    }
}

private struct SkillsFileRow: View {
    let model: SkillsDetailModel
    let node: SkillsFileNode
    let depth: Int
    let allPaths: [String]
    let canEdit: Bool
    @State private var hovering = false
    @State private var renaming = false

    var body: some View {
        let selected = model.selectedPath == node.path
        let canModify = canEdit && node.path != SkillsFiles.skillMD
        if renaming && canEdit {
            SkillsRenameRow(model: model, node: node, depth: depth, allPaths: allPaths) { renaming = false }
        } else {
            HStack(spacing: 0) {
                Button { model.selectedPath = node.path } label: {
                    HStack(spacing: 8) {
                        Image(systemName: SkillsFiles.isDocument(node.name) ? "doc.text" : "doc").font(.system(size: 11))
                        Text(node.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(selected ? Theme.Font.caption.weight(.medium) : Theme.Font.caption)
                    .foregroundStyle(selected || hovering ? .primary : .secondary)
                    .padding(.leading, CGFloat(depth) * 12 + 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if canEdit {
                    Menu { menuItems(canModify: canModify) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 22)
                    .padding(.trailing, 4)
                    .opacity(hovering ? 1 : 0)
                    .help(tr("skills", "file_tree.actions.label", ["path": node.path]))
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(selected ? Theme.selected : hovering ? Theme.hover : .clear))
            .onHover { hovering = $0 }
            .contextMenu { if canEdit { menuItems(canModify: canModify) } }
        }
    }

    @ViewBuilder private func menuItems(canModify: Bool) -> some View {
        Button { model.editFile(node.path) } label: { Label(tr("skills", "file_tree.actions.edit"), systemImage: "pencil.line") }
        if canModify {
            Button { renaming = true } label: { Label(tr("skills", "file_tree.actions.rename"), systemImage: "pencil") }
            Button(role: .destructive) { model.deleteFile(node.path) } label: { Label(tr("skills", "file_tree.actions.delete"), systemImage: "trash") }
        }
    }
}

/// Rename in place, validated by the same rules as "New file".
private struct SkillsRenameRow: View {
    let model: SkillsDetailModel
    let node: SkillsFileNode
    let depth: Int
    let allPaths: [String]
    let onDone: () -> Void
    @State private var value = ""
    @State private var error = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("", text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { finish() }
                .onChange(of: value) { error = "" }
                .onChange(of: focused) { if !focused { submit() } }
            if !error.isEmpty {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 10)
        .padding(.trailing, 4)
        .onAppear {
            value = node.path
            focused = true
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDone()
    }

    private func submit() {
        guard !finished else { return }
        let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if next == node.path {
            finish()
            return
        }
        let message = model.validate(next, existing: allPaths.filter { $0 != node.path })
        if !message.isEmpty {
            error = message
            return
        }
        model.renameFile(node.path, to: next)
        finish()
    }
}

private struct SkillsAddFileInline: View {
    let model: SkillsDetailModel
    let existing: [String]
    @State private var path = ""
    @State private var error = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(tr("skills", "detail.add_file.placeholder"), text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { model.addingFile = false }
                .onChange(of: path) { error = "" }
            if !error.isEmpty {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.destructive)
            }
            HStack(spacing: 6) {
                Button(tr("skills", "detail.add_file.add"), action: submit).buttonStyle(.borderedProminent)
                Button(tr("skills", "detail.add_file.cancel")) { model.addingFile = false }
            }
            .controlSize(.mini)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let message = model.validate(path, existing: existing)
        if !message.isEmpty {
            error = message
            return
        }
        model.addFile(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
