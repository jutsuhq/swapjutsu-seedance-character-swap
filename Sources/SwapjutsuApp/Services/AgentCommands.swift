import AppKit
import SwapjutsuAgent

/// What each agent command does in the app. Agents get the same view of the app a person has, minus anything
/// secret: whether a key is set, never the key. They do what a person can do for free (prep, characters, the
/// prompt) through the same paths Create takes. Renders spend only within the limits the person set (`JobStore.send`);
/// nothing deletes.
@MainActor
struct AgentCommands {
    let credentials: Credentials
    let depth: DepthModel
    let navigation: Navigation
    let jobs: JobStore
    /// Clips' target fixes, shared with the Prep step.
    var fixes = TargetFixes(retracker: Retrackers.unavailable)
    /// Where agents' files wait, sent in by the swapjutsu binary (`AppPaths.agentInbox`); nil without a socket.
    var inbox: URL? = AppPaths.agentInbox
    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    var bringForward: @MainActor () -> Void = Self.bringWindowForward

    func run(_ command: AgentCommand) async throws(AgentError) -> AgentResponse {
        switch command {
        case .capabilities:
            return AgentResponse(
                capabilities: AgentCapabilities(
                    appVersion: appVersion, hasComfyKey: credentials.hasComfyKey, depthModel: depth.phase.agentState,
                    hasOwnComfyUI: OwnComfy.offersWan))
        case .show(let target): return try show(target)
        case .prepare(let fields): return try await prepare(fields)
        case .clips(let fields): return try await clips(fields)
        case .setCharacters(let fields): return try setCharacters(fields)
        case .prepareAgain(let fields): return try prepareAgain(fields)
        case .correctTarget(let fields): return try correctTarget(fields)
        case .quote(let fields): return try quote(fields)
        case .render(let fields): return try render(fields)
        case .finalize(let fields): return try finalize(fields)
        case .jobAction(let fields): return try jobAction(fields)
        case .librarySearch(let fields): return try librarySearch(fields)
        // Its bytes follow the line, so the server reads it itself (`AgentServer.receiveUpload`).
        case .upload: throw .badRequest("upload is read by the socket, with the bytes that follow it")
        }
    }

    /// The window comes forward even when minimized. macOS may still keep another app active: since macOS 14 an app
    /// becomes active only when the active one lets it.
    static func bringWindowForward() {
        let app = NSApplication.shared
        guard let window = app.windows.first(where: \.canBecomeMain) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        app.activate()
    }
}

extension Screen {
    init(_ screen: AgentScreen) {
        switch screen {
        case .create: self = .create
        case .jobs: self = .jobs
        case .library: self = .library
        case .settings: self = .settings
        }
    }
}

extension LocalModel.Phase {
    var agentState: AgentCapabilities.ModelState {
        switch self {
        case .missing: .missing
        case .fetching: .fetching
        case .optimizing: .optimizing
        case .ready: .ready
        }
    }
}
