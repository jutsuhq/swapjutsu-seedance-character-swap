import Darwin
import Foundation

/// One connection to the app's socket: requests are sent and answered one at a time. Blocking, for a command-line
/// process and tests; not for the main thread of an app.
public final class AgentClient {
    public enum Failure: Error, Equatable {
        /// No app is listening: not running, or Allow agents is off.
        case notListening(errno: Int32)
        case closed
        /// Longer than `AgentSocket.maxPathLength`.
        case pathTooLong
        /// The file to upload ended before the size it was sent with.
        case fileChanged
    }

    private let socket: Int32
    private var buffer = AgentLineBuffer()
    private var lines: [Data] = []

    public init(socket path: URL) throws {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        self.socket = socket
        guard let connected = AgentSocket.withAddress(path, { connect(socket, $0, $1) }) else {
            close(socket)
            throw Failure.pathTooLong
        }
        guard connected == 0 else {
            let error = errno
            close(socket)
            throw Failure.notListening(errno: error)
        }
        // A closed peer is an error from write, not a SIGPIPE that ends the process.
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(socket) }

    public func send(_ request: AgentRequest) throws -> AgentResponse {
        try send(line: AgentWire.line(request))
    }

    /// Sends `file`'s bytes, `command.size` of them, after the request's line, and returns the app's answer. The app
    /// may refuse before reading them and close the connection; its answer is read all the same.
    public func upload(_ command: UploadCommand, from file: URL, id: String? = nil) throws -> AgentResponse {
        try write(AgentWire.line(AgentRequest(.upload(command), id: id)))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sent: Int64 = 0
        do {
            while sent < command.size {
                let chunk = try handle.read(upToCount: Int(min(Self.uploadChunk, command.size - sent))) ?? Data()
                // The app would wait for the rest forever; closing the connection tells it the upload failed.
                guard !chunk.isEmpty else { throw Failure.fileChanged }
                try write(chunk)
                sent += Int64(chunk.count)
            }
        } catch Failure.closed {
            // Refused early: the answer says why.
        }
        return try AgentWire.decoder.decode(AgentResponse.self, from: readLine())
    }

    static let uploadChunk: Int64 = 1 << 20

    /// A line as given, newline included: for tests of what the app does with malformed input.
    public func send(line: Data) throws -> AgentResponse {
        try write(line)
        return try AgentWire.decoder.decode(AgentResponse.self, from: readLine())
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(socket, base + offset, raw.count - offset)
                guard written > 0 else { throw Failure.closed }
                offset += written
            }
        }
    }

    private func readLine() throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while lines.isEmpty {
            let count = read(socket, &chunk, chunk.count)
            guard count > 0 else { throw Failure.closed }
            // Only requests are capped (`maxLineLength`): the app's answers to `clips` and `library_search` grow
            // with the clips.
            buffer.push(Data(chunk[..<count]))
            while let line = buffer.nextLine() { lines.append(line) }
        }
        return lines.removeFirst()
    }
}
