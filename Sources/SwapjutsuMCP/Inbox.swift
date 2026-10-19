import Foundation
import SwapjutsuAgent

/// The binary's half of the file handoff. The sandboxed app may not open an agent's paths, and macOS keeps this
/// binary out of the app group's container (App Data protection: a write there fails with EPERM, without a prompt),
/// so the binary sends each file's bytes over the socket (`upload`) and the app writes them into `inbox/<folder>/`
/// itself. The command then names that copy, which the app adopts into the job folder.
public struct Inbox: Sendable {
    /// Relative paths are the agent's, from where it started this binary.
    let workingDirectory: URL

    public init(workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    /// The file at `path` and the upload that hands it over: into `folder`, named `name` plus the file's extension,
    /// or by its own name without `name`.
    public func upload(
        _ path: String, name: String?, folder: String
    ) throws(AgentError) -> (source: URL, command: UploadCommand) {
        let source = Self.resolve(path, from: workingDirectory)
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            throw AgentError(
                .fileRefused, message: "There is no file at \(path).", retryable: false,
                next: "Pass the absolute path of a file on this Mac.")
        }
        guard Int64(size) <= AgentInbox.maxFileSize else {
            throw AgentError(
                .fileRefused,
                message: "\(path) is larger than \(AgentInbox.maxFileSize >> 30) GiB, the most Swapjutsu takes from an "
                    + "agent.",
                retryable: false, next: "Trim or compress the video, then send it again.")
        }
        let base = name.map { source.pathExtension.isEmpty ? $0 : "\($0).\(source.pathExtension)" }
        return (source, UploadCommand(folder: folder, name: base ?? source.lastPathComponent, size: Int64(size)))
    }

    static func resolve(_ path: String, from directory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(filePath: expanded) : directory.appending(path: expanded)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

extension AppConnection {
    /// Sends the file at `path` into the app's inbox (see `Inbox.upload`) and returns where the app put it.
    @MainActor
    public func stage(_ path: String, name: String?, folder: String) async throws(AgentError) -> URL {
        let (source, command) = try Inbox().upload(path, name: name, folder: folder)
        let response = await exchange { try AgentClient(socket: $0).upload(command, from: source) }
        if let error = response.error { throw error }
        guard let uploaded = response.uploaded else {
            throw AgentError(
                .fileRefused, message: "Swapjutsu didn't take \(path).", retryable: true,
                next: "Update Swapjutsu so the app and this binary match, then send the request again.")
        }
        return URL(filePath: uploaded)
    }
}
