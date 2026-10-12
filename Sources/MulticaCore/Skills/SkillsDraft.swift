import Foundation

public struct SkillsDraftFile: Sendable, Hashable {
    public var id: String?
    public var path: String
    public var content: String

    public init(id: String? = nil, path: String, content: String) {
        self.id = id
        self.path = path
        self.content = content
    }
}

public struct SkillsDirtySummary: Sendable, Hashable {
    public var nameChanged = false
    public var descriptionChanged = false
    public var changedFileCount = 0

    public init(nameChanged: Bool = false, descriptionChanged: Bool = false, changedFileCount: Int = 0) {
        self.nameChanged = nameChanged
        self.descriptionChanged = descriptionChanged
        self.changedFileCount = changedFileCount
    }

    public var isDirty: Bool { nameChanged || descriptionChanged || changedFileCount > 0 }
}

/// The editable fields of a skill detail page. Dirty state is always
/// measured against the draft handed to the user (the baseline), never
/// against the latest server skill, so a remote update cannot read as a
/// local edit (upstream MUL-5645).
public struct SkillsDraft: Sendable, Hashable {
    public var name: String
    public var description: String
    public var content: String
    public var files: [SkillsDraftFile]

    public init(name: String = "", description: String = "", content: String = "", files: [SkillsDraftFile] = []) {
        self.name = name
        self.description = description
        self.content = content
        self.files = files
    }

    /// Name and description are trimmed once here because Save trims them;
    /// file bodies are content and stay verbatim.
    public init(skill: Skill) {
        self.init(
            name: skill.name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: skill.description.trimmingCharacters(in: .whitespacesAndNewlines),
            content: skill.content,
            files: skill.files.map { SkillsDraftFile(id: $0.id.isEmpty ? nil : $0.id, path: $0.path, content: $0.content) }
        )
    }

    /// Order-insensitive: GET sorts files by path, PUT echoes request order.
    static func signature(_ files: [SkillsDraftFile]) -> [[String]] {
        files.map { [$0.path, $0.content] }.sorted { $0[0] < $1[0] }
    }

    public func hasLocalEdits(against baseline: SkillsDraft?) -> Bool {
        guard let baseline else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines) != baseline.name
            || description.trimmingCharacters(in: .whitespacesAndNewlines) != baseline.description
            || content != baseline.content
            || Self.signature(files) != Self.signature(baseline.files)
    }

    /// Files are matched by id so a rename counts as one change; SKILL.md
    /// is its own entry.
    public func dirtySummary(against baseline: SkillsDraft?) -> SkillsDirtySummary {
        guard let baseline else { return SkillsDirtySummary() }
        var byID: [String: SkillsDraftFile] = [:]
        for f in baseline.files { if let id = f.id { byID[id] = f } }
        var changed = content != baseline.content ? 1 : 0
        var draftIDs = Set<String>()
        for f in files {
            if let id = f.id { draftIDs.insert(id) }
            let base = f.id.flatMap { byID[$0] }
            if base == nil || base!.path != f.path || base!.content != f.content { changed += 1 }
        }
        for f in baseline.files { if let id = f.id, !draftIDs.contains(id) { changed += 1 } }
        return SkillsDirtySummary(
            nameChanged: name.trimmingCharacters(in: .whitespacesAndNewlines) != baseline.name,
            descriptionChanged: description.trimmingCharacters(in: .whitespacesAndNewlines) != baseline.description,
            changedFileCount: changed
        )
    }

    public var updateRequest: UpdateSkillRequest {
        UpdateSkillRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content,
            files: files.filter { !$0.path.trimmingCharacters(in: .whitespaces).isEmpty }.map { f in
                var o: [String: JSONValue] = ["path": .string(f.path), "content": .string(f.content)]
                if let id = f.id { o["id"] = .string(id) }
                return .object(o)
            }
        )
    }

    /// SKILL.md plus every supporting file with a path, in draft order.
    public var filePaths: [String] {
        [SkillsFiles.skillMD] + files.compactMap { $0.path.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.path }
    }

    public func content(at path: String) -> String {
        path == SkillsFiles.skillMD ? content : files.first { $0.path == path }?.content ?? ""
    }

    public mutating func setContent(_ value: String, at path: String) {
        if path == SkillsFiles.skillMD {
            content = value
        } else if let i = files.firstIndex(where: { $0.path == path }) {
            files[i].content = value
        }
    }

    public mutating func renameFile(_ from: String, to: String) {
        guard from != SkillsFiles.skillMD, let i = files.firstIndex(where: { $0.path == from }) else { return }
        files[i].path = to
    }

    public mutating func removeFile(_ path: String) {
        guard path != SkillsFiles.skillMD else { return }
        files.removeAll { $0.path == path }
    }
}
