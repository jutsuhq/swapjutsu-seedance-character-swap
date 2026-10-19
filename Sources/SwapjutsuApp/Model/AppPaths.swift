import Foundation
import SwapjutsuAgent
import UniformTypeIdentifiers

/// Where the app keeps things.
enum AppPaths {
    static let depthModelKey = "depthModelPath"

    /// Downloaded examples, reused when picked again.
    static var samples: URL {
        URL.applicationSupportDirectory.appending(path: "Swapjutsu/Samples")
    }

    /// Every job writes into its own folder under ~/Movies/Swapjutsu. A Debug build takes `SWAPJUTSU_JOBS` instead,
    /// for screenshots and smoke runs that must not touch the real jobs; a Release build ignores it, so nothing that
    /// starts the app can point it at other jobs and another agent ledger.
    static var jobs: URL {
        #if DEBUG
            if let path = ProcessInfo.processInfo.environment["SWAPJUTSU_JOBS"] { return URL(filePath: path) }
        #endif
        return URL.moviesDirectory.appending(path: "Swapjutsu")
    }

    /// What agents spent each day, in Application Support next to the models rather than among the jobs in Movies,
    /// which agents are given paths into.
    static var agentLedger: URL {
        #if DEBUG
            if ProcessInfo.processInfo.environment["SWAPJUTSU_JOBS"] != nil {
                return jobs.appending(path: "agent-spend.json")
            }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Swapjutsu/agent-spend.json")
    }

    /// The app group Info.plist names (project.yml): `<TEAM_ID>.<prefix>.swapjutsu`, `.<prefix>.swapjutsu` for a
    /// bundle signed without a team, nil for the bare `swift run` executable.
    static var appGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: AgentSocket.appGroupKey) as? String
    }

    /// The agent socket. The app bundle names its app group in Info.plist (project.yml), whose container both the
    /// sandboxed app and the unsandboxed `swapjutsu` binary can open. The bare `swift run` executable has no sandbox
    /// and no group, so it listens in Application Support. nil for a bundle signed without a team (ad-hoc): its group
    /// is `.<prefix>.swapjutsu`, and the sandbox won't create a group container that doesn't start with a team ID.
    /// The unbundled executable takes `SWAPJUTSU_AGENT_SOCKET` (the variable the swapjutsu binary reads too), so a
    /// second development copy can run next to the first without taking over its socket.
    static var agentSocket: URL? {
        guard let group = appGroup else {
            if let path = ProcessInfo.processInfo.environment[AgentSocket.variable], !path.isEmpty {
                return URL(filePath: path)
            }
            return URL.applicationSupportDirectory.appending(path: "Swapjutsu/\(AgentSocket.fileName)")
        }
        return group.hasPrefix(".") ? nil : AgentSocket.url(appGroup: group)
    }

    /// Where the app writes the files an agent hands over (`AgentInbox`), next to the socket.
    static var agentInbox: URL? { agentSocket.map(AgentInbox.url(socket:)) }

    /// `<stamp> <title> <id>`: readable, and unique even for two jobs of the same clip in the same second.
    static func newJobFolder(named title: String, id: UUID, in root: URL = jobs) -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(48)
        return root.appending(path: "\(stamp) \(safe) \(id.uuidString.prefix(8))")
    }

    /// Bytes the files under `folder` take on disk; 0 when it doesn't exist. Walks the tree, so call it off the
    /// main actor.
    static func size(of folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The gallery cache: downloads `link` to `<folder>/<name>.<ext>` once and reuses that file on the next pick.
    /// Only for public examples, whose links name a fixed file; job artifacts go through `fetch`.
    static func cached(_ link: URL, into folder: URL, name: String) async throws -> URL {
        let ext = link.pathExtension.isEmpty ? "bin" : link.pathExtension
        let file = folder.appending(path: "\(name).\(ext)")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        let (temporary, response) = try await URLSession.shared.download(from: link)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }

    /// A job artifact: always downloaded fresh to `base` plus the extension of the type the server sent (a signed
    /// link names no file), replacing any earlier file. A `file:` link is copied.
    static func fetch(_ link: URL, to base: URL) async throws -> URL {
        let temporary: URL, type: String?
        if link.isFileURL {
            temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: link, to: temporary)
            type = UTType(filenameExtension: link.pathExtension)?.preferredMIMEType
        } else {
            let (file, response) = try await URLSession.shared.download(from: link)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            temporary = file
            type = response.mimeType
        }
        let ext =
            type.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (link.pathExtension.isEmpty ? "mp4" : link.pathExtension)
        let file = base.appendingPathExtension(ext)
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        return file
    }
}
