import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// The socket is open only while Allow agents is on, and every command checks the setting again, so a client that
/// connected while it was on is refused once it is off. Each test listens on a socket of its own, with its own
/// defaults; the client runs off the main actor, where the server answers.
@MainActor
struct AgentServerTests {
    @Test func listensOnlyWhileAllowed() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let server = scratch.server()
        server.update()
        #expect(!server.isListening)
        #expect(throws: AgentClient.Failure.self) { try AgentClient(socket: scratch.socket) }

        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        try await scratch.listen(server)
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.socket.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let response = try await scratch.send([AgentRequest(.capabilities, id: "1")])
        let capabilities = try #require(response.first?.capabilities)
        #expect(response.first?.id == "1")
        #expect(capabilities.appVersion == "9.9.9")
        #expect(!capabilities.hasComfyKey && capabilities.protocolVersion == AgentProtocol.version)
        #expect(capabilities.depthModel == scratch.depth.phase.agentState)

        scratch.defaults.set(false, forKey: AgentServer.allowKey)
        server.update()
        #expect(!server.isListening)
        #expect(!FileManager.default.fileExists(atPath: scratch.socket.path))
        #expect(throws: AgentClient.Failure.self) { try AgentClient(socket: scratch.socket) }
    }

    @Test func aConnectionOpenedBeforeTurningOffIsRefused() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let server = scratch.server()
        try await scratch.listen(server)
        let (name, socket) = (scratch.name, scratch.socket)
        let (before, after) = try await offThePool {
            let client = try AgentClient(socket: socket)
            let before = try client.send(AgentRequest(.show(.screen(.jobs)), id: "a"))
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    UserDefaults(suiteName: name)?.set(false, forKey: AgentServer.allowKey)
                    server.update()
                }
            }
            return (before, try client.send(AgentRequest(.capabilities, id: "b")))
        }
        #expect(before.shown == .jobs)
        #expect(after == AgentResponse(id: "b", error: .agentsOff))
        #expect(scratch.navigation.screen == .jobs)
    }

    /// Only requests are capped at `maxLineLength`: an answer longer than that, as `clips` gives with many clips,
    /// still reaches the client whole instead of passing for agents being off.
    @Test func anAnswerLongerThanAnyRequestStillArrives() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let long = String(repeating: "x", count: AgentProtocol.maxLineLength * 3)
        let server = AgentServer(socket: scratch.socket, defaults: scratch.defaults, domain: scratch.name) { _ in
            AgentResponse(error: AgentError(.badRequest, message: long, retryable: false))
        }
        try await scratch.listen(server)
        let answer = try await scratch.send([AgentRequest(.capabilities, id: "a")])
        #expect(answer.first?.error?.message == long)
    }

    /// Whatever launches the app can pass `-allowAgents YES`, an agent included, so in a bundled app only the
    /// person's saved setting turns agents on; the launch argument works for the unbundled executable alone.
    @Test func aLaunchArgumentDoesNotAllowAgentsInTheApp() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let arguments = UserDefaults.argumentDomain
        let saved = scratch.defaults.volatileDomain(forName: arguments)
        scratch.defaults.setVolatileDomain(saved.merging([AgentServer.allowKey: true]) { $1 }, forName: arguments)
        defer { scratch.defaults.setVolatileDomain(saved, forName: arguments) }
        #expect(scratch.defaults.bool(forKey: AgentServer.allowKey))

        let app = scratch.server()
        #expect(!app.isAllowed)
        app.update()
        #expect(!app.isListening)
        #expect(await app.response(to: try AgentWire.line(AgentRequest(.capabilities))).error == .agentsOff)
        #expect(scratch.server(bundled: false).isAllowed)

        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        #expect(app.isAllowed)
    }

    @Test func malformedLinesAreAnsweredAndTheConnectionStays() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let server = scratch.server()
        try await scratch.listen(server)
        let socket = scratch.socket
        let (bad, good) = try await offThePool {
            let client = try AgentClient(socket: socket)
            return (
                try client.send(line: Data("{\"version\":1,\"id\":\"x\",\"command\":\"delete\"}\n".utf8)),
                try client.send(AgentRequest(.show(.screen(.library))))
            )
        }
        #expect(bad.id == "x" && bad.error?.code == .unknownCommand)
        #expect(good.shown == .library)
        withExtendedLifetime(server) {}
    }

    /// The binary may not write the group container, so it sends a file's bytes and the app writes them into its
    /// inbox: the answer names the copy, a retry replaces it, and the connection takes the next request after them.
    @Test func anUploadLandsInTheInboxAndTheConnectionGoesOn() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let server = scratch.server()
        try await scratch.listen(server)
        // Newlines and more than one receive's worth, so the bytes are never read as lines.
        let bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let source = scratch.folder.appending(path: "source.mov")
        try bytes.write(to: source)
        let command = UploadCommand(folder: "r1", name: "My clip.mov", size: Int64(bytes.count))
        let socket = scratch.socket
        let (first, again, next) = try await offThePool {
            let client = try AgentClient(socket: socket)
            return (
                try client.upload(command, from: source, id: "u"), try client.upload(command, from: source),
                try client.send(AgentRequest(.show(.screen(.library)), id: "n"))
            )
        }
        let stored = scratch.folder.appending(path: "inbox/r1/My clip.mov")
        #expect(first == AgentResponse(id: "u", uploaded: stored.path(percentEncoded: false)))
        #expect(again.uploaded == first.uploaded)
        #expect(next.shown == .library && next.id == "n")
        #expect(try Data(contentsOf: stored) == bytes)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: stored.deletingLastPathComponent().path) == [
                "My clip.mov"
            ])
    }

    /// Refused before the bytes are read, then closed: what would follow can't be told from a request.
    @Test(arguments: [
        (#"{"version":1,"id":"1","command":"upload","folder":"../up","name":"a.mov","size":1}"#, "bad_request"),
        (#"{"version":1,"id":"1","command":"upload","folder":"r","name":".hidden","size":1}"#, "bad_request"),
        (#"{"version":1,"id":"1","command":"upload","folder":"r","name":"a.mov","size":4294967297}"#, "file_refused"),
    ])
    func aBadUploadIsRefusedAndTheConnectionCloses(line: String, code: String) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let server = scratch.server()
        try await scratch.listen(server)
        let socket = scratch.socket
        let (refused, after) = try await offThePool {
            let client = try AgentClient(socket: socket)
            let refused = try client.send(line: Data((line + "\nx").utf8))
            return (refused, Result { try client.send(AgentRequest(.capabilities)) })
        }
        #expect(refused.id == "1" && refused.error?.code.rawValue == code)
        #expect(throws: AgentClient.Failure.closed) { try after.get() }
        #expect(!FileManager.default.fileExists(atPath: scratch.folder.appending(path: "inbox").path))
    }

    @Test func noUploadWhileAgentsAreOff() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let server = scratch.server()
        try await scratch.listen(server)
        let socket = scratch.socket
        let source = scratch.folder.appending(path: "a.mov")
        try Data("video".utf8).write(to: source)
        let (name, upload) = (scratch.name, UploadCommand(folder: "r", name: "a.mov", size: 5))
        let refused = try await offThePool {
            let client = try AgentClient(socket: socket)
            DispatchQueue.main.sync { _ = UserDefaults(suiteName: name)?.set(false, forKey: AgentServer.allowKey) }
            return try client.upload(upload, from: source)
        }
        #expect(refused.error == .agentsOff)
        #expect(!FileManager.default.fileExists(atPath: scratch.folder.appending(path: "inbox").path))
        withExtendedLifetime(server) {}
    }

    /// The group container's socket outgrows a `sockaddr_un` (103 bytes) at a user name of 24 characters; the app
    /// sizes the address to the path, so a long home still listens and connects. Past `AgentSocket.maxPathLength` it
    /// can't, and Settings › Agents says why.
    @Test func listensAtALongHomesPathAndSaysWhyNotPastTheLimit() async throws {
        let home = "Users/" + String(repeating: "n", count: 40)
        let scratch = try Scratch(nested: "\(home)/Library/Group Containers/ABCDE12345.com.jutsustudio.swapjutsu")
        defer { scratch.remove() }
        #expect(scratch.socket.path(percentEncoded: false).utf8.count > 104)
        scratch.defaults.set(true, forKey: AgentServer.allowKey)
        let server = scratch.server()
        try await scratch.listen(server)
        let response = try await scratch.send([AgentRequest(.capabilities, id: "1")])
        #expect(response.first?.capabilities?.appVersion == "9.9.9")

        let tooLong = try Scratch(nested: String(repeating: "x", count: AgentSocket.maxPathLength))
        defer { tooLong.remove() }
        tooLong.defaults.set(true, forKey: AgentServer.allowKey)
        let refused = tooLong.server()
        refused.update()
        #expect(!refused.isListening)
        #expect(
            refused.failure?.contains("more than the \(AgentSocket.maxPathLength)") == true, "\(refused.failure ?? "")")
        #expect(throws: AgentClient.Failure.pathTooLong) { try AgentClient(socket: tooLong.socket) }
    }

    /// Defaults of their own and a socket in a folder of their own, `nested` below it if given.
    @MainActor
    private struct Scratch {
        let name = "AgentServerTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let base: URL
        let folder: URL
        let navigation = Navigation()
        let depth = DepthModel(load: { _ in throw CancellationError() })

        init(nested: String? = nil) throws {
            defaults = try #require(UserDefaults(suiteName: name))
            base = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString.prefix(8))")
            let base = base
            folder = nested.map { base.appending(path: $0) } ?? base
        }

        var socket: URL { folder.appending(path: AgentSocket.fileName) }

        /// As a bundled app, with the suite as its persistent domain; `bundled: false` is the `swift run` executable.
        func server(bundled: Bool = true) -> AgentServer {
            let commands = AgentCommands(
                // A Keychain item nothing writes: no key, and the real one is never read.
                credentials: Credentials(
                    comfy: ComfyKeyStore(secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.agents"))),
                depth: depth, navigation: navigation,
                jobs: JobStore(
                    root: folder, providers: { _ in throw GenerationError.noKey },
                    preparer: { _, _, _ in
                        throw CancellationError()
                    }, restoresJobs: false), inbox: nil, appVersion: "9.9.9", bringForward: {})
            return AgentServer(socket: socket, defaults: defaults, domain: bundled ? name : nil, handle: commands.run)
        }

        func listen(_ server: AgentServer) async throws {
            server.update()
            for _ in 0..<200 where !server.isListening { try await Task.sleep(for: .milliseconds(10)) }
            try #require(server.isListening, "\(server.failure ?? "not listening")")
        }

        func send(_ requests: [AgentRequest]) async throws -> [AgentResponse] {
            let socket = socket
            return try await offThePool {
                let client = try AgentClient(socket: socket)
                return try requests.map { try client.send($0) }
            }
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: base)
        }
    }
}

/// Runs the blocking client on a GCD thread. On the cooperative pool it can take every thread, as these tests do at
/// once on a three-core runner, and the server it waits for has none left to answer on.
func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}
