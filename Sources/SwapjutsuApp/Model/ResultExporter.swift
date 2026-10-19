import Foundation

/// Copies a result out of the app, as Library's Export does. The destination is replaced only once a whole copy of
/// the result sits beside it, so a failed copy leaves what was there, and the result itself is never the destination.
enum ResultExporter {
    enum Failure: LocalizedError {
        case sameFile

        var errorDescription: String? {
            "That is the result itself. Choose another name or folder to export it to."
        }
    }

    /// Off the main actor: a final runs to hundreds of megabytes.
    @concurrent
    static func export(_ result: URL, to target: URL) async throws {
        if isSameFile(result, target) { throw Failure.sameFile }
        let manager = FileManager.default
        // A folder on the destination's volume, so the replace is a rename. The sandbox may not allow one beside a
        // picked file on another volume; the app's own temporary folder then holds the copy and the replace copies.
        let folder =
            (try? manager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target.deletingLastPathComponent(),
                create: true))
            ?? manager.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let copy = folder.appending(path: target.lastPathComponent)
        try manager.copyItem(at: result, to: copy)
        if manager.fileExists(atPath: target.path) {
            _ = try manager.replaceItemAt(target, withItemAt: copy)
        } else {
            try manager.moveItem(at: copy, to: target)
        }
    }

    /// The same path once links are resolved, or the same file under another name (a case-insensitive disk, a hard
    /// link).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let path = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().path }
        if path(a) == path(b) { return true }
        let identifier = { (url: URL) in
            (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        guard let first = identifier(a), let second = identifier(b) else { return false }
        return first.isEqual(second)
    }
}
