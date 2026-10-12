import Foundation
import MulticaCore
import Observation
import UniformTypeIdentifiers

/// Upstream `use-file-upload` + the editor's file-upload extension: uploads a
/// local file and yields the Markdown the editor persists for it.
enum AttachmentUpload {
    /// Upstream `MAX_FILE_SIZE`.
    static let maxBytes = 100 * 1024 * 1024

    struct TooLarge: LocalizedError {
        var errorDescription: String? { "File exceeds 100 MB limit" }
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Upstream escapeMarkdownLabel: `[ ] \ ( )` break link labels.
    static func escapeLabel(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "[]\\()".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// `![name](url)` for images, `!file[name](url)` for everything else,
    /// always with the stable per-attachment URL (never the signed one).
    static func markdown(for a: Attachment) -> String {
        let href = a.markdownUrl.isEmpty ? a.url : a.markdownUrl
        let label = escapeLabel(a.filename.isEmpty ? "file" : a.filename)
        return a.contentType.hasPrefix("image/") ? "![\(label)](\(href))" : "!file[\(label)](\(href))"
    }
}

extension WorkspaceSession {
    /// Reads and uploads a local file off the main thread.
    func upload(fileAt url: URL, issueID: String? = nil, commentID: String? = nil, chatSessionID: String? = nil) async throws -> Attachment {
        let data = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > AttachmentUpload.maxBytes { throw AttachmentUpload.TooLarge() }
            return try Data(contentsOf: url)
        }.value
        if data.count > AttachmentUpload.maxBytes { throw AttachmentUpload.TooLarge() }
        return try await api.uploadFile(
            name: url.lastPathComponent,
            mimeType: AttachmentUpload.mimeType(for: url),
            data: data,
            issueId: issueID,
            commentId: commentID,
            chatSessionId: chatSessionID
        )
    }
}

/// Tracks uploads started from one composer: an in-flight counter (upstream
/// keeps a counter, not a boolean, so N concurrent drops gate submit until
/// all land) plus the attachment ids to bind on submit.
@MainActor
@Observable
final class ComposerUploads {
    private(set) var inFlight = 0
    private(set) var attachmentIDs: [String] = []
    var isUploading: Bool { inFlight > 0 }

    /// Uploads each file and hands its Markdown to `insert` as it lands.
    func upload(_ urls: [URL], session: WorkspaceSession, issueID: String? = nil, commentID: String? = nil,
                chatSessionID: String? = nil, insert: @escaping (String) -> Void, onError: @escaping (Error) -> Void) {
        for url in urls {
            inFlight += 1
            Task {
                defer { inFlight -= 1 }
                do {
                    let a = try await session.upload(fileAt: url, issueID: issueID, commentID: commentID, chatSessionID: chatSessionID)
                    attachmentIDs.append(a.id)
                    insert(AttachmentUpload.markdown(for: a))
                } catch {
                    onError(error)
                }
            }
        }
    }

    func reset() { attachmentIDs.removeAll() }
}
