import Foundation

/// A render's inputs as they were sent, kept on the render (`Render.snapshot`) so that a later change to the clip, or
/// to Settings, reaches new renders only. Library shows a result with these images, a resubmit sends them again, and
/// a resumed Wan render asks the ComfyUI it was sent to. The videos aren't copied: a render made from an earlier prep
/// says so through `prepRevision`.
struct RenderInputSnapshot: Codable, Equatable, Sendable {
    /// The prompt the generator got: for Seedance the service prompt with the wishes folded in, for Wan the wishes.
    var prompt: String
    /// The images uploaded, in `@Image` order (Wan: its one character), by path inside the job folder (`storedPath`).
    /// Nothing overwrites them there: every character gets a name of its own (`JobFiles.addCharacter`), and its
    /// cutout and face close-up are made from it once.
    var images: [String]
    /// The clip's character images then, in `JobSpec.references` order, as Library shows them.
    var references: [String]
    /// The prep the render was made from (`Job.prepRevision`).
    var prepRevision: Int
    var backend: RenderBackend
}

extension Job {
    /// `url` by its path inside the job folder, so a moved folder still finds it; whole when it is outside.
    func storedPath(_ url: URL) -> String {
        let folder = output.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > folder.count, Array(parts.prefix(folder.count)) == folder else { return url.path }
        return parts.dropFirst(folder.count).joined(separator: "/")
    }

    /// The file a `storedPath` names.
    func file(at path: String) -> URL { path.hasPrefix("/") ? URL(filePath: path) : output.appending(path: path) }

    /// The character images `render` was sent with; the clip's own for a render sent before they were kept.
    func references(of render: Render) -> [URL] {
        render.snapshot.map { $0.references.map(file(at:)) } ?? spec.references
    }

    /// Whether the clip's prep is still the one `render` was made from, so its control video is this render's.
    func isCurrentPrep(of render: Render) -> Bool { render.snapshot.map { $0.prepRevision == prepRevision } ?? true }
}
