import Foundation

/// Local skill import: picks the files of a skill folder with the server
/// importer's rules and packs them into a STORE zip (upstream
/// core/skills/pack-archive.ts).
public enum SkillsArchive {
    public static let maxFileBytes = 1 << 20
    public static let maxBundleBytes = 8 << 20
    public static let maxFileCount = 256
    public static let maxArchiveBytes = 16 << 20

    public enum Failure: String, Error, Sendable, Hashable {
        case missingSkillMD = "missing_skill_md"
        case empty
        case tooLarge = "too_large"
        case tooManyFiles = "too_many_files"
    }

    public struct Member: Sendable, Hashable {
        public var path: String
        public var size: Int
        public init(path: String, size: Int) {
            self.path = path
            self.size = size
        }
    }

    public struct Selection: Sendable, Hashable {
        /// Members to pack, input order, normalized paths.
        public var selected: [Member]
        public var skillMDPath: String
        /// Directory prefix of the skill root; "" when SKILL.md is at the root.
        public var prefix: String
    }

    public enum Source: String, Sendable, Hashable { case folder, archive }

    public struct Preview: Sendable, Hashable {
        public var displayName: String
        public var skillName: String
        public var description: String
        public var fileCount: Int?
        public var source: Source
    }

    public struct Prepared: Sendable, Hashable {
        public var fileName: String
        public var data: Data
        public var preview: Preview
    }

    /// The single place ignore rules and limits apply; decides from path and
    /// size alone so a folder can be rejected before any file is read.
    public static func select(_ files: [Member]) -> Result<Selection, Failure> {
        if files.isEmpty { return .failure(.empty) }
        var normalized: [Member] = []
        for file in files {
            let path = normalizeRelPath(file.path)
            if path.isEmpty || isIgnored(path) { continue }
            normalized.append(Member(path: path, size: file.size))
        }
        if normalized.isEmpty { return .failure(.empty) }

        var skillMD: (member: Member, prefix: String)?
        for file in normalized where isSkillMDPath(file.path) {
            let prefix = entryPrefix(file.path)
            if skillMD == nil || prefix.count < skillMD!.prefix.count { skillMD = (file, prefix) }
        }
        guard let root = skillMD else { return .failure(.missingSkillMD) }
        if root.member.size > maxFileBytes { return .failure(.tooLarge) }

        var selected: [Member] = []
        var supportingCount = 0
        var supportingBytes = 0
        for file in normalized {
            if !root.prefix.isEmpty && !file.path.hasPrefix(root.prefix) { continue }
            let rel = root.prefix.isEmpty ? file.path : String(file.path.dropFirst(root.prefix.count))
            if rel.isEmpty || rel.hasSuffix("/") { continue }
            if isSkillMDPath(rel) {
                selected.append(file)
                continue
            }
            if isLikelyBinary(rel) || file.size > maxFileBytes { continue }
            supportingCount += 1
            if supportingCount > maxFileCount { return .failure(.tooManyFiles) }
            supportingBytes += file.size
            if supportingBytes > maxBundleBytes { return .failure(.tooLarge) }
            selected.append(file)
        }
        return .success(Selection(selected: selected, skillMDPath: root.member.path, prefix: root.prefix))
    }

    /// Packs an approved selection. `data` supplies the bytes of a selected path.
    public static func prepare(_ selection: Selection, data: (String) -> Data) -> Result<Prepared, Failure> {
        let packed = selection.selected.map { (path: $0.path, data: data($0.path)) }
        let content = String(decoding: data(selection.skillMDPath), as: UTF8.self)
        let frontmatter = SkillsFrontmatter.parse(content).frontmatter
        let wrapper = wrapperName(selection.prefix)
        let fmName = frontmatter?["name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skillName = !fmName.isEmpty ? fmName : (!wrapper.isEmpty ? wrapper : "skill")
        let description = frontmatter?["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let zip = packStoreZip(packed)
        if zip.count > maxArchiveBytes { return .failure(.tooLarge) }
        return .success(Prepared(
            fileName: "\(sanitizeBasename(skillName)).skill",
            data: zip,
            preview: Preview(displayName: wrapper.isEmpty ? skillName : wrapper, skillName: skillName,
                             description: description, fileCount: packed.count, source: .folder)
        ))
    }

    /// An already-packed `.skill` / `.zip` the user picked.
    public static func wrapExisting(fileName: String, data: Data) -> Result<Prepared, Failure> {
        if data.count > maxArchiveBytes { return .failure(.tooLarge) }
        let base = fileName.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? fileName
        var name = base
        if let ext = [".skill", ".zip"].first(where: { name.lowercased().hasSuffix($0) }) {
            name = String(name.dropLast(ext.count))
        }
        return .success(Prepared(
            fileName: base,
            data: data,
            preview: Preview(displayName: base, skillName: name.isEmpty ? "skill" : name, description: "", fileCount: nil, source: .archive)
        ))
    }

    public static func isArchiveFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".skill") || lower.hasSuffix(".zip")
    }

    // MARK: Zip (STORE)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// Uncompressed zip with UTF-8 names; the server parser accepts STORE.
    public static func packStoreZip(_ entries: [(path: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32, _ d: inout Data) { for s in stride(from: 0, to: 32, by: 8) { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for entry in entries {
            let name = Data(entry.path.replacingOccurrences(of: "\\", with: "/").utf8)
            let crc = crc32(entry.data)
            let offset = UInt32(out.count)
            u32(0x0403_4B50, &out); u16(20, &out); u16(0x0800, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(UInt32(entry.data.count), &out); u32(UInt32(entry.data.count), &out)
            u16(name.count, &out); u16(0, &out)
            out.append(name)
            out.append(entry.data)

            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(crc, &central)
            u32(UInt32(entry.data.count), &central); u32(UInt32(entry.data.count), &central)
            u16(name.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(offset, &central)
            central.append(name)
        }
        let centralStart = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out)
        u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(centralStart, &out); u16(0, &out)
        return out
    }

    // MARK: Paths (mirror skill_import_archive.go)

    static func normalizeRelPath(_ p: String) -> String {
        var s = p.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    static func isSkillMDPath(_ path: String) -> Bool {
        (path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? "").lowercased() == "skill.md"
    }

    static func entryPrefix(_ name: String) -> String {
        guard let i = name.lastIndex(of: "/"), i != name.startIndex else { return "" }
        return String(name[...i])
    }

    static func wrapperName(_ prefix: String) -> String {
        var trimmed = prefix
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "" }
        let base = trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return base == "." || base == ".." ? "" : base
    }

    public static func isIgnored(_ rel: String) -> Bool {
        let segments = rel.split(separator: "/", omittingEmptySubsequences: false)
        for seg in segments where seg.isEmpty || seg == "__MACOSX" || seg.hasPrefix(".") { return true }
        let base = (segments.last.map(String.init) ?? "").lowercased()
        return base == "license" || base == "license.md" || base == "license.txt"
    }

    private static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "ico", "heic", "ttf", "otf", "woff", "woff2", "eot",
        "zip", "gz", "tar", "bz2", "7z", "rar", "pdf", "docx", "xlsx", "pptx", "doc", "xls", "ppt",
        "mp3", "mp4", "wav", "avi", "mov", "webm", "m4a", "flac", "exe", "dll", "so", "dylib", "class", "jar",
        "wasm", "db", "sqlite", "sqlite3", "pyc",
    ]

    public static func isLikelyBinary(_ path: String) -> Bool {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return false }
        return binaryExtensions.contains(base[base.index(after: dot)...].lowercased())
    }

    static func sanitizeBasename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        let cleaned = String(name.unicodeScalars.map { bad.contains($0) ? "-" : Character($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "skill" : cleaned
    }
}
