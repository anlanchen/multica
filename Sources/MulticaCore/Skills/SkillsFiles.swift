import Foundation

/// A node of the skill file rail. Directories are inferred from paths.
public struct SkillsFileNode: Identifiable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var children: [SkillsFileNode]

    public var id: String { path }
}

/// Why a new or renamed file path is refused; raw values are the keys under
/// `detail.add_file.errors`.
public enum SkillsPathError: String, Sendable, Hashable {
    case empty, absolute, reserved, exists
    case doubleDot = "double_dot"
    case isDirectory = "is_directory"
    case underFile = "under_file"
}

public enum SkillsFiles {
    public static let skillMD = "SKILL.md"

    /// Upstream `buildTree`: SKILL.md first, folders before files, then name.
    public static func buildTree(_ paths: [String]) -> [SkillsFileNode] {
        final class Box {
            var name: String
            var path: String
            var isDirectory: Bool
            var children: [Box] = []
            init(name: String, path: String, isDirectory: Bool) {
                self.name = name
                self.path = path
                self.isDirectory = isDirectory
            }
        }
        let root = Box(name: "", path: "", isDirectory: true)
        for filePath in paths {
            let parts = filePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var current = root
            for (i, name) in parts.enumerated() {
                let isLast = i == parts.count - 1
                let node: Box
                if let existing = current.children.first(where: { $0.name == name }) {
                    node = existing
                } else {
                    node = Box(name: name, path: parts[0...i].joined(separator: "/"), isDirectory: !isLast)
                    current.children.append(node)
                }
                if !isLast { current = node }
            }
        }
        func freeze(_ boxes: [Box]) -> [SkillsFileNode] {
            boxes.sorted { a, b in
                if a.path == skillMD { return b.path != skillMD }
                if b.path == skillMD { return false }
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCompare(b.name) == .orderedAscending
            }
            .map { SkillsFileNode(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, children: $0.isDirectory ? freeze($0.children) : []) }
        }
        return freeze(root.children)
    }

    /// Upstream `useValidateNewFilePath`. A file may not take a folder's
    /// name, nor nest under an existing file: the tree would merge them and
    /// the file would vanish from the rail while still being saved.
    public static func validateNewPath(_ path: String, existing: [String]) -> SkillsPathError? {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return .empty }
        if p.hasPrefix("/") { return .absolute }
        if p.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return .doubleDot }
        if p == skillMD { return .reserved }
        if existing.contains(p) { return .exists }
        if existing.contains(where: { $0.hasPrefix(p + "/") }) { return .isDirectory }
        if existing.contains(where: { p.hasPrefix($0 + "/") }) { return .underFile }
        return nil
    }

    public static func isMarkdown(_ path: String) -> Bool {
        path.hasSuffix(".md") || path.hasSuffix(".mdx")
    }

    /// `SyntaxHighlighter` language for a file path, by extension or name.
    public static func highlightLanguage(for path: String) -> String? {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        switch base.lowercased() {
        case "dockerfile", "makefile": return "sh"
        default: break
        }
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return nil }
        let ext = base[base.index(after: dot)...].lowercased()
        switch ext {
        case "md", "mdx", "markdown", "txt", "": return nil
        case "yml": return "yaml"
        case "zsh", "bash": return "sh"
        case "htm": return "html"
        default: return SyntaxHighlighter.grammar(ext) != nil || ext == "diff" || ext == "patch" ? ext : nil
        }
    }

    /// File-row glyph kind (upstream `getFileIcon`).
    public static func isDocument(_ name: String) -> Bool {
        name.hasSuffix(".md") || name.hasSuffix(".mdx")
    }
}
