import Foundation
import Observation
import SwapjutsuAgent
import os

private let logger = Logger(subsystem: "com.jutsustudio.swapjutsu", category: "Agents")

/// The app's end of the agent socket (`SwapjutsuAgent`). It listens only while Settings › Agents › Allow agents is
/// on, and reads the setting again for every command, so a connection opened before it was turned off is refused
/// too. Turning it off stops the listener and removes the socket file; open connections stay, refusing every command,
/// so a client is told why instead of seeing the connection drop. Nothing an agent started is cancelled.
@MainActor
@Observable
final class AgentServer {
    typealias Handler = @MainActor (AgentCommand) async throws(AgentError) -> AgentResponse

    static let allowKey = AgentPreferences.allowKey

    /// nil when the app has no place both sides can reach (see `AppPaths.agentSocket`).
    let socket: URL?
    private(set) var isListening = false
    private(set) var failure: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let domain: String?
    @ObservationIgnored private let handle: Handler
    @ObservationIgnored private var listener: AgentListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: AgentConnection] = [:]
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    /// `domain` is the app's own defaults domain, its bundle ID; nil only for the unbundled executable.
    init(
        socket: URL?, defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier,
        handle: @escaping Handler
    ) {
        self.socket = socket
        self.defaults = defaults
        self.domain = domain
        self.handle = handle
    }

    /// Only what the person saved in Settings counts (`AgentPreferences`).
    var isAllowed: Bool { AgentPreferences(defaults: defaults, domain: domain).isAllowed }

    /// Starts or stops with the setting from now on. The smoke test never calls it.
    func run() {
        update()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func update() {
        if isAllowed { start() } else { stop() }
    }

    private func start() {
        guard listener == nil, let socket else { return }
        guard AgentSocket.fits(socket) else { return fail(AgentError.socketPathTooLong(socket).message) }
        let path = socket.path(percentEncoded: false)
        do {
            try FileManager.default.createDirectory(
                at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            listener = try AgentListener(path: socket) { [weak self] connection in
                guard let self else { return connection.cancel() }
                self.accept(connection)
            }
        } catch {
            return fail("Can't listen for agents: \(error.localizedDescription)")
        }
        // Only this user can connect, whatever the folder around it allows.
        chmod(path, 0o600)
        isListening = true
        failure = nil
        logger.info("Listening for agents")
    }

    private func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        isListening = false
        if let socket { unlink(socket.path(percentEncoded: false)) }
    }

    private func fail(_ message: String) {
        failure = message
        logger.error("Agent socket failed: \(message, privacy: .public)")
    }

    private func accept(_ connection: AgentConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        Task {
            await serve(connection)
            connections[id] = nil
        }
    }

    /// Answers each line in order, and reads on only once it is answered. An upload's bytes follow its line and are
    /// read by `receiveUpload`; a refused upload closes the connection, since its bytes can't be told from the next
    /// request.
    private func serve(_ connection: AgentConnection) async {
        var buffer = AgentLineBuffer()
        while true {
            guard let line = buffer.nextLine() else {
                guard !buffer.isOverlong, let data = await connection.receive() else { return connection.cancel() }
                buffer.push(data)
                continue
            }
            let (id, request) = AgentWire.request(from: line)
            guard case .success(let parsed) = request, case .upload(let upload) = parsed.command else {
                Self.send(await response(to: line), on: connection)
                continue
            }
            switch await receiveUpload(upload, buffer: &buffer, from: connection) {
            case .stored(let path): Self.send(AgentResponse(id: id, uploaded: path), on: connection)
            case .refused(let error):
                return Self.send(AgentResponse(id: id, error: error), on: connection, thenClose: true)
            case .dropped: return connection.cancel()
            }
        }
    }

    static func send(_ response: AgentResponse, on connection: AgentConnection, thenClose: Bool = false) {
        guard let data = try? AgentWire.line(response) else { return }
        connection.send(data, thenClose: thenClose)
    }

    func response(to line: Data) async -> AgentResponse {
        let (id, request) = AgentWire.request(from: line)
        do throws(AgentError) {
            guard isAllowed else { throw .agentsOff }
            var response = try await handle(try request.get().command)
            response.id = id
            return response
        } catch {
            return AgentResponse(id: id, error: error)
        }
    }
}
