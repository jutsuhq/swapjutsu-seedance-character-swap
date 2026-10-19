import AppKit
import SwapjutsuAgent

/// How the swapjutsu binary reaches the app. It keeps no state: every command opens the socket, sends one request and
/// closes it. When nothing answers, it starts the app it is bundled in, in the background, and waits for it.
public struct AppConnection: Sendable {
    public enum Location: Equatable, Sendable {
        /// Inside Swapjutsu.app (`Contents/Helpers/swapjutsu`): the app to start and the socket in its app group's
        /// container; nil for a build signed without a team, which has no socket.
        case bundled(app: URL, bundleID: String, socket: URL?)
        /// A socket named outright: `SWAPJUTSU_AGENT_SOCKET`, or the unbundled app's when this binary isn't bundled.
        case socket(URL)

        var socket: URL? {
            switch self {
            case .bundled(_, _, let socket): socket
            case .socket(let socket): socket
            }
        }
    }

    /// Points the binary at another socket, for development.
    public static let socketVariable = AgentSocket.variable

    public let location: Location
    /// How long a starting app has to begin listening, counted from its launch.
    var launchWait: TimeInterval = 10

    public init(location: Location) {
        self.location = location
    }

    /// Where `executable` (symlinks resolved) finds the app: the override, else the bundle two levels up whose
    /// Info.plist names the app group, else the socket `swift run` listens on.
    public static func locate(executable: URL, environment: [String: String], home: URL) -> Location {
        if let path = environment[socketVariable], !path.isEmpty { return .socket(URL(filePath: path)) }
        let app = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        if app.pathExtension == "app", let bundle = Bundle(url: app), let bundleID = bundle.bundleIdentifier,
            let group = bundle.object(forInfoDictionaryKey: AgentSocket.appGroupKey) as? String
        {
            // A group without a team (`.<prefix>.swapjutsu`, an ad-hoc build) gets no container from the sandbox.
            return .bundled(app: app, bundleID: bundleID, socket: group.hasPrefix(".") ? nil : groupSocket(group, home))
        }
        return .socket(home.appending(path: "Library/Application Support/Swapjutsu/\(AgentSocket.fileName)"))
    }

    /// `~/Library/Group Containers/<group>/agent.sock`, the path `AgentSocket.url` gives the app. Spelled out rather
    /// than asked of the container manager, which needs no access here: the binary only opens this one known path, and
    /// listing that folder from outside the app is denied anyway.
    static func groupSocket(_ group: String, _ home: URL) -> URL {
        home.appending(path: "Library/Group Containers/\(group)/\(AgentSocket.fileName)")
    }

    @MainActor
    public func send(_ command: AgentCommand) async -> AgentResponse {
        let response = await exchange { try Self.request(command, $0) }
        if case .show = command, case .bundled(_, let bundleID, _) = location, response.shown != nil {
            await Self.activate(bundleID)
        }
        return response
    }

    /// One round trip through the socket, `body` making it, starting the bundled app when nothing answers. Also
    /// used for an upload, which is safe to repeat: it replaces the same file.
    @MainActor
    func exchange(_ body: (URL) throws -> AgentResponse) async -> AgentResponse {
        // The app can't listen there either, so starting it and waiting would only end in a misleading agents_off.
        if let socket = location.socket, !AgentSocket.fits(socket) {
            return AgentResponse(error: .socketPathTooLong(socket))
        }
        switch location {
        case .socket(let socket):
            return (try? body(socket)) ?? AgentResponse(error: .notListening(socket))
        case .bundled(_, _, nil):
            return AgentResponse(error: .needsTeamBuild)
        case .bundled(let app, let bundleID, let socket?):
            if let response = try? body(socket) { return response }
            return await startAndSend(body, app: app, bundleID: bundleID, socket: socket)
        }
    }

    /// The app isn't listening: it isn't running, it is still starting, or Allow agents is off. It doesn't listen at
    /// all while agents are off, so a running app that never answers within `launchWait` of its launch gets the app's
    /// own `agents_off`.
    @MainActor
    private func startAndSend(
        _ body: (URL) throws -> AgentResponse, app: URL, bundleID: String, socket: URL
    ) async -> AgentResponse {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if running == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            do {
                running = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            } catch {
                return AgentResponse(error: .notStarted(app, reason: error.localizedDescription))
            }
        }
        guard let running else { return AgentResponse(error: .notStarted(app, reason: nil)) }
        let deadline = (running.launchDate ?? .now).addingTimeInterval(launchWait)
        while true {
            if let response = try? body(socket) { return response }
            if running.isTerminated { return AgentResponse(error: .notStarted(app, reason: "it quit")) }
            if Date.now >= deadline { return AgentResponse(error: .agentsOff) }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func request(_ command: AgentCommand, _ socket: URL) throws -> AgentResponse {
        try AgentClient(socket: socket).send(AgentRequest(command, id: UUID().uuidString))
    }

    /// `show` has ordered the window front; since macOS 14 the app itself may not become active unless the active
    /// app lets it. Neither may this process: it isn't the active app, so it has no activation to yield, and
    /// `NSRunningApplication.activate()` from here leaves the agent's app in front. Opening the running app through
    /// Launch Services, as `open -b` does, brings it forward.
    @MainActor
    private static func activate(_ bundleID: String) async {
        guard let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

extension AgentError.Code {
    public static let notListening = Self(rawValue: "not_listening")
    public static let notStarted = Self(rawValue: "app_not_started")
    public static let needsTeamBuild = Self(rawValue: "needs_team_build")
}

extension AgentError {
    static func notListening(_ socket: URL) -> AgentError {
        AgentError(
            .notListening, message: "Nothing is listening at \(socket.path(percentEncoded: false)).", retryable: true,
            next: "Start the app with agents allowed (`.build/debug/Swapjutsu -allowAgents YES` for `swift run`), "
                + "or point \(AppConnection.socketVariable) at its socket.")
    }

    static func notStarted(_ app: URL, reason: String?) -> AgentError {
        AgentError(
            .notStarted,
            message: "Couldn't start \(app.path(percentEncoded: false))" + (reason.map { ": \($0)." } ?? "."),
            retryable: true, next: "Ask the person to open Swapjutsu, then send the request again.")
    }

    static let needsTeamBuild = AgentError(
        .needsTeamBuild, message: "This Swapjutsu build is signed without a team ID, so it has no agent socket.",
        retryable: false, next: "Use a release of Swapjutsu, or a build signed with DEVELOPMENT_TEAM.")
}
