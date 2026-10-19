import Foundation

// Library: the finished renders, and the pages `show` opens.

/// What `show` opens: a sidebar page, a clip in Create, or a result's page in Library. On the wire exactly one of
/// `screen`, `clip` or `result` next to the command.
public enum AgentShow: Codable, Equatable, Sendable {
    case screen(AgentScreen)
    /// A clip id: the clip in Create.
    case clip(String)
    /// A render id: a finished render's page in Library; one that isn't finished opens on its clip in Create.
    case result(String)

    private enum CodingKeys: String, CodingKey {
        case screen, clip, result
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let screen = try container.decodeIfPresent(AgentScreen.self, forKey: .screen)
        let clip = try container.decodeIfPresent(String.self, forKey: .clip)
        let result = try container.decodeIfPresent(String.self, forKey: .result)
        switch (screen, clip, result) {
        case (let screen?, nil, nil): self = .screen(screen)
        case (nil, let clip?, nil): self = .clip(clip)
        case (nil, nil, let result?): self = .result(result)
        default: throw AgentError.badRequest("show takes one of screen, clip or result")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .screen(let screen): try container.encode(screen, forKey: .screen)
        case .clip(let clip): try container.encode(clip, forKey: .clip)
        case .result(let result): try container.encode(result, forKey: .result)
        }
    }
}

/// Finished drafts and finals, newest first, a page at a time.
public struct LibrarySearchCommand: Codable, Equatable, Sendable {
    /// Words that must all appear in the clip's title, the version's name ("Draft 2") or the prompt, in any case.
    public var text: String?
    public var quality: AgentQuality?
    /// Results per page: 1–50, 20 when left out.
    public var limit: Int?
    /// `nextCursor` of the page before.
    public var cursor: String?

    public init(text: String? = nil, quality: AgentQuality? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.text = text
        self.quality = quality
        self.limit = limit
        self.cursor = cursor
    }

    public static let defaultLimit = 20
    public static let maxLimit = 50
}

public struct AgentLibraryPage: Codable, Equatable, Sendable {
    public var results: [AgentLibraryItem]
    /// How many results match, on every page together.
    public var total: Int
    /// The `cursor` for the next page; nil on the last one.
    public var nextCursor: String?

    public init(results: [AgentLibraryItem], total: Int, nextCursor: String?) {
        self.results = results
        self.total = total
        self.nextCursor = nextCursor
    }
}

/// A finished render as Library shows it. `file` is in the jobs folder (`~/Movies/Swapjutsu`), readable outside the
/// sandbox.
public struct AgentLibraryItem: Codable, Equatable, Sendable {
    /// The render id, for `show`, `finalize` and `job_action`.
    public var render: String
    public var clip: String
    /// The clip's title.
    public var title: String
    /// "Draft 2", "Final 1080p": the version's name among the clip's renders.
    public var name: String
    public var quality: AgentQuality
    /// The finished video, with the clip's own soundtrack.
    public var file: String
    /// When the render was sent, and when it finished.
    public var created: Date
    public var finished: Date?
    /// The clip's length in seconds.
    public var duration: Double?
    /// The person's or the agent's wishes, cut to `promptLength` characters.
    public var prompt: String
    public var promptTruncated: Bool
    /// For a final of a draft: the draft's render id.
    public var draft: String?
    /// A draft finalize still takes, until then.
    public var finalizableUntil: Date?
    /// The agent that asked for it, when one did.
    public var client: String?

    public init(
        render: String, clip: String, title: String, name: String, quality: AgentQuality, file: String,
        created: Date, finished: Date?, duration: Double?, prompt: String, draft: String?, finalizableUntil: Date?,
        client: String?
    ) {
        self.render = render
        self.clip = clip
        self.title = title
        self.name = name
        self.quality = quality
        self.file = file
        self.created = created
        self.finished = finished
        self.duration = duration
        promptTruncated = prompt.count > Self.promptLength
        self.prompt = promptTruncated ? String(prompt.prefix(Self.promptLength - 1)) + "…" : prompt
        self.draft = draft
        self.finalizableUntil = finalizableUntil
        self.client = client
    }

    /// Long enough to tell results apart; the whole prompt is on the result's page.
    public static let promptLength = 200
}
