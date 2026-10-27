import Foundation

/// The commands an agent can send the app, shared by the app (`AgentServer`) and the `swapjutsu` binary. One JSON
/// object per line each way over a Unix socket: a request, then its response, in order.
///
/// ```
/// → {"version":1,"id":"1","command":"show","screen":"jobs"}
/// ← {"id":"1","shown":"jobs"}
/// ```
public enum AgentProtocol {
    /// Raised only for a change an older peer would misread; new commands and new optional fields don't need it.
    public static let version = 1
    /// A request line longer than this is refused rather than buffered: no command needs more. An upload's bytes
    /// follow its line and don't count (`AgentInbox.maxFileSize`).
    public static let maxLineLength = 64 * 1024
}

/// The pages `show` can open, by the names the sidebar uses.
public enum AgentScreen: String, Codable, Sendable, CaseIterable {
    case create, jobs, library, settings
}

public enum AgentCommand: Equatable, Sendable {
    /// What the app is and can do now; safe to send at any time.
    case capabilities
    /// Opens a page, a clip or a result and brings the window forward.
    case show(AgentShow)
    /// Starts prep of one clip per range; answers at once with the clips.
    case prepare(PrepareCommand)
    /// One clip or all, after waiting for prep if asked.
    case clips(ClipsCommand)
    case setCharacters(SetCharactersCommand)
    case prepareAgain(PrepareAgainCommand)
    /// A click or mask fixing who is replaced on one frame; re-tracks that shot, free.
    case correctTarget(CorrectTargetCommand)
    /// A file for the inbox, its bytes after the line; the binary sends it, an agent never does.
    case upload(UploadCommand)
    /// What a render of a clip would cost; free.
    case quote(QuoteCommand)
    /// A paid render of a prepared clip, sent only within `maxCost` and the day's agent budget.
    case render(RenderCommand)
    /// A paid 1080p final of a finished draft, under the same limits.
    case finalize(FinalizeCommand)
    case jobAction(JobActionCommand)
    /// Finished drafts and finals, newest first, a page at a time.
    case librarySearch(LibrarySearchCommand)
    /// A finished render beside its clip and control.mp4 at the same moments, as a contact sheet; free.
    case frames(FramesCommand)

    public var name: String {
        switch self {
        case .capabilities: "capabilities"
        case .show: "show"
        case .prepare: "prepare"
        case .clips: "clips"
        case .setCharacters: "set_characters"
        case .prepareAgain: "prepare_again"
        case .correctTarget: "correct_target"
        case .upload: "upload"
        case .quote: "quote"
        case .render: "render"
        case .finalize: "finalize"
        case .jobAction: "job_action"
        case .librarySearch: "library_search"
        case .frames: "frames"
        }
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var version: Int
    /// Echoed in the response, so a client can match them up.
    public var id: String?
    public var command: AgentCommand

    public init(_ command: AgentCommand, id: String? = nil, version: Int = AgentProtocol.version) {
        self.version = version
        self.id = id
        self.command = command
    }

    // Flat, with `command` naming the rest of the keys: what a person types into `nc -U` too.
    private enum CodingKeys: String, CodingKey {
        case version, id, command
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .command)
        switch name {
        case "capabilities": command = .capabilities
        // The commands' own fields sit next to version, id and command.
        case "show": command = .show(try AgentShow(from: decoder))
        case "prepare": command = .prepare(try PrepareCommand(from: decoder))
        case "clips": command = .clips(try ClipsCommand(from: decoder))
        case "set_characters": command = .setCharacters(try SetCharactersCommand(from: decoder))
        case "prepare_again": command = .prepareAgain(try PrepareAgainCommand(from: decoder))
        case "correct_target": command = .correctTarget(try CorrectTargetCommand(from: decoder))
        case "upload": command = .upload(try UploadCommand(from: decoder))
        case "quote": command = .quote(try QuoteCommand(from: decoder))
        case "render": command = .render(try RenderCommand(from: decoder))
        case "finalize": command = .finalize(try FinalizeCommand(from: decoder))
        case "job_action": command = .jobAction(try JobActionCommand(from: decoder))
        case "library_search": command = .librarySearch(try LibrarySearchCommand(from: decoder))
        case "frames": command = .frames(try FramesCommand(from: decoder))
        default: throw AgentError.unknownCommand(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(command.name, forKey: .command)
        switch command {
        case .capabilities: break
        case .show(let target): try target.encode(to: encoder)
        case .prepare(let fields): try fields.encode(to: encoder)
        case .clips(let fields): try fields.encode(to: encoder)
        case .setCharacters(let fields): try fields.encode(to: encoder)
        case .prepareAgain(let fields): try fields.encode(to: encoder)
        case .correctTarget(let fields): try fields.encode(to: encoder)
        case .upload(let fields): try fields.encode(to: encoder)
        case .quote(let fields): try fields.encode(to: encoder)
        case .render(let fields): try fields.encode(to: encoder)
        case .finalize(let fields): try fields.encode(to: encoder)
        case .jobAction(let fields): try fields.encode(to: encoder)
        case .librarySearch(let fields): try fields.encode(to: encoder)
        case .frames(let fields): try fields.encode(to: encoder)
        }
    }
}

/// Exactly one of the result fields or `error` is set.
public struct AgentResponse: Codable, Equatable, Sendable {
    public var id: String?
    public var capabilities: AgentCapabilities?
    /// show: the sidebar page now open.
    public var shown: AgentScreen?
    /// prepare, clips, set_characters, prepare_again and correct_target; show of a clip.
    public var clips: [AgentClip]?
    /// upload: where the app put the file.
    public var uploaded: String?
    public var quote: AgentQuote?
    /// render, finalize and job_action: the render; clips: every render of the clips; show of a result.
    public var renders: [AgentRender]?
    public var library: AgentLibraryPage?
    public var frames: AgentFrames?
    public var error: AgentError?

    public init(
        id: String? = nil, capabilities: AgentCapabilities? = nil, shown: AgentScreen? = nil,
        clips: [AgentClip]? = nil, uploaded: String? = nil, quote: AgentQuote? = nil, renders: [AgentRender]? = nil,
        library: AgentLibraryPage? = nil, frames: AgentFrames? = nil, error: AgentError? = nil
    ) {
        self.id = id
        self.capabilities = capabilities
        self.shown = shown
        self.clips = clips
        self.uploaded = uploaded
        self.quote = quote
        self.renders = renders
        self.library = library
        self.frames = frames
        self.error = error
    }
}

public struct AgentCapabilities: Codable, Equatable, Sendable {
    public enum ModelState: String, Codable, Sendable {
        case missing, fetching, optimizing, ready
    }

    public var protocolVersion: Int
    public var appVersion: String
    /// Whether a Comfy API key is saved, so renders can run. The key itself never leaves the app.
    public var hasComfyKey: Bool
    /// The depth model prep needs; `missing` is fetched by the first prep.
    public var depthModel: ModelState
    /// Whether the person's own ComfyUI is set up and passed its Check (Settings › Own ComfyUI), so `render` takes
    /// model `wan22Animate`.
    public var hasOwnComfyUI: Bool?  // swiftlint:disable:this discouraged_optional_boolean
    /// The `swapjutsu` helper's own version, added by the helper (`noteHelper`); the app leaves it out.
    public var helperVersion: String?
    /// Added by a helper older than the app: what the agent should do about it.
    public var helperNote: String?

    public init(
        appVersion: String, hasComfyKey: Bool, depthModel: ModelState,
        hasOwnComfyUI: Bool? = nil,  // swiftlint:disable:this discouraged_optional_boolean
        protocolVersion: Int = AgentProtocol.version
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.hasComfyKey = hasComfyKey
        self.depthModel = depthModel
        self.hasOwnComfyUI = hasOwnComfyUI
    }

    /// The helper `version` that relays this answer. An MCP client keeps the helper process it started, so after the
    /// app is updated it can run an older helper, with that version's tools, until it reconnects.
    public mutating func noteHelper(_ version: String) {
        helperVersion = version
        helperNote =
            Self.isOlder(version, than: appVersion)
            ? "This swapjutsu helper is \(version), older than Swapjutsu \(appVersion): the MCP client still runs the "
                + "helper it started before the app was updated, with that version's tools. Reconnect the swapjutsu "
                + "MCP server (/mcp in Claude Code, or restart the client) to get this version's tools."
            : nil
    }

    /// Whether release `helper` is older than release `app`, compared as numbers (0.2.10 after 0.2.9); a development
    /// build or a version that isn't a number is never called older.
    static func isOlder(_ helper: String, than app: String) -> Bool {
        let isRelease = { (version: String) in version.first?.isNumber == true }
        guard isRelease(helper), isRelease(app) else { return false }
        return helper.compare(app, options: .numeric) == .orderedAscending
    }
}

/// A refused or failed command. `code` is stable for clients to branch on, `message` is for the person, `next` says
/// what to do instead, and `retryable` whether sending the same request again later can succeed.
public struct AgentError: Error, Codable, Equatable, Sendable {
    /// A string, not an enum, so a client still decodes a code added after it was built.
    public struct Code: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let agentsOff = Code(rawValue: "agents_off")
        public static let unsupportedVersion = Code(rawValue: "unsupported_version")
        public static let unknownCommand = Code(rawValue: "unknown_command")
        public static let badRequest = Code(rawValue: "bad_request")
    }

    public var code: Code
    public var message: String
    public var retryable: Bool
    public var next: String?

    public init(_ code: Code, message: String, retryable: Bool, next: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.next = next
    }

    /// Retryable: the person can turn it on, and the same request then works.
    public static let agentsOff = AgentError(
        .agentsOff, message: "Agents are turned off in Swapjutsu.", retryable: true,
        next: "Ask the person to turn on Settings › Agents › Allow agents in Swapjutsu, then send the request "
            + "again.")

    public static func unsupportedVersion(_ version: Int) -> AgentError {
        AgentError(
            .unsupportedVersion,
            message: "Protocol version \(version) is not supported; this app speaks \(AgentProtocol.version).",
            retryable: false, next: "Use the swapjutsu binary inside this Swapjutsu.app.")
    }

    public static func unknownCommand(_ name: String) -> AgentError {
        AgentError(
            .unknownCommand, message: "Unknown command '\(name)'.", retryable: false,
            next: "Send capabilities to see what this app supports.")
    }

    public static func badRequest(_ reason: String) -> AgentError {
        AgentError(
            .badRequest, message: "Malformed request: \(reason)", retryable: false,
            next: "Send one JSON object per line with version, command and the command's fields.")
    }
}
