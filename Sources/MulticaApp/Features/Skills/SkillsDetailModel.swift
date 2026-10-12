import MulticaCore
import Observation
import SwiftUI

enum SkillsDetailTab: String { case overview, files }

enum SkillsFileMode: Equatable { case preview, raw }

/// Server skill + editable draft for the detail page. Each draft field is
/// its own property so typing in one file only invalidates its readers.
@MainActor
@Observable
final class SkillsDetailModel {
    let skillID: String
    private(set) var skill: Skill?
    private(set) var isLoading = true
    private(set) var loadError: String?

    var name = "" { didSet { draftChanged() } }
    var descriptionText = "" { didSet { draftChanged() } }
    var content = "" { didSet { draftChanged() } }
    private(set) var files: [SkillsDraftFile] = [] { didSet { draftChanged() } }

    private(set) var filePaths: [String] = [SkillsFiles.skillMD]
    private(set) var dirty = SkillsDirtySummary()
    private(set) var conflictPending = false
    var selectedPath = SkillsFiles.skillMD
    var fileMode: SkillsFileMode = .preview
    var addingFile = false
    /// The file whose editor should take the caret next ("Edit").
    var focusPath: String?
    var focusToken = 0
    var saving = false

    @ObservationIgnored private var baseline: SkillsDraft?
    @ObservationIgnored private var seededKey: String?
    @ObservationIgnored private var adopting = false
    @ObservationIgnored private var previewCache: (source: String, body: String)?

    init(skillID: String) {
        self.skillID = skillID
    }

    var draft: SkillsDraft { SkillsDraft(name: name, description: descriptionText, content: content, files: files) }

    func load(api: APIClient) async {
        do {
            let fetched = try await api.getSkill(skillID)
            loadError = nil
            receive(fetched)
        } catch let error as APIError where error.status == 404 {
            skill = nil
            loadError = error.message
        } catch {
            if skill == nil { loadError = (error as? APIError)?.message ?? error.localizedDescription }
        }
        isLoading = false
    }

    /// A newer server version: adopt silently unless the user has local
    /// edits, in which case keep them and raise the conflict banner.
    func receive(_ fetched: Skill) {
        skill = fetched
        let key = "\(fetched.id)@\(fetched.updatedAt)"
        if seededKey == key { return }
        let sameSkill = seededKey?.hasPrefix("\(fetched.id)@") ?? false
        if sameSkill && draft.hasLocalEdits(against: baseline) {
            conflictPending = true
            return
        }
        adopt(fetched, resetSelection: !sameSkill)
    }

    /// The single writer of draft + baseline + seeded key + conflict flag.
    func adopt(_ s: Skill, resetSelection: Bool = false) {
        skill = s
        seededKey = "\(s.id)@\(s.updatedAt)"
        conflictPending = false
        let seeded = SkillsDraft(skill: s)
        adopting = true
        baseline = seeded
        name = seeded.name
        descriptionText = seeded.description
        content = seeded.content
        files = seeded.files
        adopting = false
        draftChanged()
        if resetSelection { selectedPath = SkillsFiles.skillMD }
    }

    func discard() {
        if let skill { adopt(skill) }
    }

    private func draftChanged() {
        guard !adopting else { return }
        let d = draft
        let summary = d.dirtySummary(against: baseline)
        if summary != dirty { dirty = summary }
        let paths = d.filePaths
        if paths != filePaths { filePaths = paths }
        if !filePaths.contains(selectedPath) { selectedPath = SkillsFiles.skillMD }
        // A conflict the user resolves by reverting their edits releases the page.
        if conflictPending, let skill, !d.hasLocalEdits(against: baseline) { adopt(skill) }
    }

    // MARK: Files

    func content(at path: String) -> String {
        path == SkillsFiles.skillMD ? content : files.first { $0.path == path }?.content ?? ""
    }

    func setContent(_ value: String, at path: String) {
        if path == SkillsFiles.skillMD {
            if content != value { content = value }
        } else if let i = files.firstIndex(where: { $0.path == path }), files[i].content != value {
            files[i].content = value
        }
    }

    @ObservationIgnored private var treeCache: [[String]: [SkillsFileNode]] = [:]

    func tree(_ paths: [String]) -> [SkillsFileNode] {
        if let hit = treeCache[paths] { return hit }
        let tree = SkillsFiles.buildTree(paths)
        if treeCache.count > 16 { treeCache.removeAll() }
        treeCache[paths] = tree
        return tree
    }

    /// Markdown preview body with the frontmatter stripped, memoised.
    func previewBody(_ source: String) -> String {
        if let hit = previewCache, hit.source == source { return hit.body }
        let body = SkillsFrontmatter.body(source)
        previewCache = (source, body)
        return body
    }

    func addFile(_ path: String) {
        files.append(SkillsDraftFile(path: path, content: ""))
        selectedPath = path
        addingFile = false
    }

    func deleteFile(_ path: String? = nil) {
        let target = path ?? selectedPath
        guard target != SkillsFiles.skillMD else { return }
        files.removeAll { $0.path == target }
        if target == selectedPath { selectedPath = SkillsFiles.skillMD }
    }

    func renameFile(_ from: String, to: String) {
        guard from != SkillsFiles.skillMD, let i = files.firstIndex(where: { $0.path == from }) else { return }
        files[i].path = to
        if from == selectedPath { selectedPath = to }
    }

    /// "Edit" from a row menu: open the file, switch to the editor, caret in.
    func editFile(_ path: String) {
        selectedPath = path
        fileMode = .raw
        focusPath = path
        focusToken += 1
    }

    func validate(_ path: String, existing: [String]) -> String {
        guard let error = SkillsFiles.validateNewPath(path, existing: existing) else { return "" }
        return tr("skills", "detail.add_file.errors.\(error.rawValue)")
    }

    // MARK: Save

    func save(api: APIClient) async throws -> Skill {
        guard let skill else { throw SkillsError("not loaded") }
        saving = true
        defer { saving = false }
        let updated = try await api.updateSkill(skill.id, draft.updateRequest)
        adopt(updated)
        return updated
    }
}
