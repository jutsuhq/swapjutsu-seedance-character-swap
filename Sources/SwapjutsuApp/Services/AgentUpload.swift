import Foundation
import SwapjutsuAgent

/// The app's end of `upload`: the swapjutsu binary may not write the app group's container (see `AgentInbox`), so it
/// sends each file's bytes over the socket and the app writes them into its inbox, where `AgentCommands` adopts them.
extension AgentServer {
    enum UploadOutcome: Equatable {
        /// The file's path in the inbox.
        case stored(String)
        /// Answered, then the connection closes: the bytes that may follow can't be told from a request.
        case refused(AgentError)
        /// The client went away before all the bytes came.
        case dropped
    }

    /// `upload.size` bytes from `buffer` and then the connection, into `inbox/<folder>/<name>` through a partial file
    /// and a rename, so a retry replaces an earlier copy in one step and nothing half-written is ever adopted.
    /// note: written on the main actor a chunk at a time (up to 1 MiB); fine for files of this size, move it off
    /// the main actor if uploads ever stall the UI.
    func receiveUpload(
        _ upload: UploadCommand, buffer: inout AgentLineBuffer, from connection: AgentConnection
    ) async -> UploadOutcome {
        let folder: URL
        switch prepareUpload(upload) {
        case .success(let url): folder = url
        case .failure(let error): return .refused(error)
        }
        let destination = folder.appending(path: upload.name)
        let partial = folder.appending(path: ".partial-\(UUID().uuidString)")
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .refused(.couldNotStore(upload.name, error))
        }
        let written = await Self.copy(upload.size, from: &buffer, connection, to: handle)
        do {
            try handle.close()
            guard let written else {
                try? FileManager.default.removeItem(at: partial)
                return .dropped
            }
            try written.get()
            guard rename(partial.path(percentEncoded: false), destination.path(percentEncoded: false)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .refused(.couldNotStore(upload.name, error))
        }
        return .stored(destination.path(percentEncoded: false))
    }

    /// Writes the next `size` bytes to `handle`: nil when the client went away first. After a failed write the rest
    /// is still read, so the answer comes once the client has sent everything.
    private static func copy(
        _ size: Int64, from buffer: inout AgentLineBuffer, _ connection: AgentConnection, to handle: FileHandle
    ) async -> Result<Void, any Error>? {
        var remaining = size
        var result = Result<Void, any Error>.success(())
        while remaining > 0 {
            var chunk = buffer.take(upTo: Int(min(remaining, 1 << 20)))
            if chunk.isEmpty {
                guard let data = await connection.receive() else { return nil }
                buffer.push(data)
                chunk = buffer.take(upTo: Int(min(remaining, 1 << 20)))
            }
            remaining -= Int64(chunk.count)
            if case .success = result { result = Result { try handle.write(contentsOf: chunk) } }
        }
        return result
    }

    /// The inbox folder the upload goes into, or why it is refused before any of its bytes are read.
    private func prepareUpload(_ upload: UploadCommand) -> Result<URL, AgentError> {
        guard isAllowed else { return .failure(.agentsOff) }
        guard let socket else { return .failure(.badRequest("this app has no inbox")) }
        guard AgentInbox.isValidName(upload.folder) else {
            return .failure(.badRequest("folder takes 1–64 letters, digits, '.', '_' or '-', not starting with '.'"))
        }
        guard AgentInbox.isValidFileName(upload.name) else {
            return .failure(.badRequest("name is one file name, not hidden"))
        }
        guard (0...AgentInbox.maxFileSize).contains(upload.size) else {
            return .failure(
                AgentError(
                    .fileRefused,
                    message: "\(upload.name) is larger than \(AgentInbox.maxFileSize >> 30) GiB, the most Swapjutsu "
                        + "takes from an agent.",
                    retryable: false, next: "Trim or compress the video, then send it again."))
        }
        return .success(AgentInbox.url(socket: socket).appending(path: upload.folder))
    }
}

extension AgentError {
    static func couldNotStore(_ name: String, _ error: any Error) -> AgentError {
        AgentError(
            .fileRefused, message: "Swapjutsu couldn't store \(name): \(error.localizedDescription)", retryable: true,
            next: "Check that the Mac has room for it, then send the request again.")
    }
}
