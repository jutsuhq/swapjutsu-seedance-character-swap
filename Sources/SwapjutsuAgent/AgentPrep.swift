import Foundation

// The free half of the work: prepare clips, read what prep found, set the characters. Files never travel as an
// agent's own paths: the swapjutsu binary sends their bytes into the app's inbox first (`upload`, `AgentInbox`), and a
// command names both the copy (`file`), which the app adopts, and the path the agent gave, which is only recorded.
//
// An option left out means "as it is" (Settings › Prep, or what the clip has), which false can't say.
// swiftlint:disable discouraged_optional_boolean

/// Who prep replaces: the main person, everyone, or people by the ids prep gave them (`AgentPerson.id`, from 1).
/// On the wire `"main"`, `"all"` or `[1, 3]`.
public enum AgentTarget: Codable, Equatable, Hashable, Sendable {
    case main, all
    case people([Int])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let ids = try? container.decode([Int].self) {
            self = .people(ids)
            return
        }
        switch try container.decode(String.self) {
        case "main": self = .main
        case "all": self = .all
        default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "main, all or person ids")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .main: try container.encode("main")
        case .all: try container.encode("all")
        case .people(let ids): try container.encode(ids)
        }
    }
}

/// A part of the video in seconds; each range becomes its own clip.
public struct AgentRange: Codable, Equatable, Hashable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct PrepareCommand: Codable, Equatable, Sendable {
    /// Chosen by the agent: the same id returns the same clips, across relaunches; with other parameters it is
    /// refused (`request_conflict`). Letters, digits, `.`, `_` and `-`, up to 64.
    public var requestID: String
    /// The video as the agent named it. Recorded to compare a repeated request; the app never opens it.
    public var video: String
    /// The copy in the inbox, which the app adopts like a dropped file.
    public var file: String
    /// nil: the whole video, or its first 30 s.
    public var ranges: [AgentRange]?
    /// nil: Settings › Prep.
    public var target: AgentTarget?
    public var faceGuide: Bool?
    /// nil: colored depth, or the clip's.
    public var control: AgentControl?
    /// The MCP client that asked (`clientInfo.name` from initialize), shown on the clip.
    public var client: String?

    public init(
        requestID: String, video: String, file: String, ranges: [AgentRange]? = nil, target: AgentTarget? = nil,
        faceGuide: Bool? = nil, control: AgentControl? = nil, client: String? = nil
    ) {
        self.requestID = requestID
        self.video = video
        self.file = file
        self.ranges = ranges
        self.target = target
        self.faceGuide = faceGuide
        self.control = control
        self.client = client
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId", video, file, ranges, target, faceGuide, control, client
    }
}

public struct ClipsCommand: Codable, Equatable, Sendable {
    /// nil: every clip.
    public var clip: String?
    /// Waits until the clip's prep (every clip's, without one) stops, for at most this long (up to 60 s). Running
    /// out of time cancels nothing.
    public var waitSeconds: Double?

    public init(clip: String? = nil, waitSeconds: Double? = nil) {
        self.clip = clip
        self.waitSeconds = waitSeconds
    }

    public static let maxWait: Double = 60
}

public struct SetCharactersCommand: Codable, Equatable, Sendable {
    /// One image for one replaced person.
    public struct Character: Codable, Equatable, Sendable {
        public var person: Int
        /// The image as the agent named it, for messages.
        public var image: String
        /// Its copy in the inbox.
        public var file: String
        /// Another view of the person's character (a side or full-body shot of the same look), not a new character.
        public var view: Bool?

        public init(person: Int, image: String, file: String, view: Bool? = nil) {
            self.person = person
            self.image = image
            self.file = file
            self.view = view
        }
    }

    public var clip: String
    public var characters: [Character]?
    public var removeBackground: Bool?
    public var prompt: String?

    public init(
        clip: String, characters: [Character]? = nil, removeBackground: Bool? = nil, prompt: String? = nil
    ) {
        self.clip = clip
        self.characters = characters
        self.removeBackground = removeBackground
        self.prompt = prompt
    }
}

/// What paints the replaced people in control.mp4: colored depth (`depth`), depth with their real hands from the
/// footage (`hybrid-hands`), or the real person but for the head, which stays colored depth (`hybrid-body`). The
/// footage gives Seedance the exact hands and pose; the prompt says it is motion only.
public enum AgentControl: String, Codable, CaseIterable, Sendable {
    case depth
    case hybridHands = "hybrid-hands"
    case hybridBody = "hybrid-body"
}

public struct PrepareAgainCommand: Codable, Equatable, Sendable {
    public var clip: String
    /// nil: keep the clip's.
    public var target: AgentTarget?
    public var faceGuide: Bool?
    /// nil: keep the clip's.
    public var control: AgentControl?

    public init(clip: String, target: AgentTarget? = nil, faceGuide: Bool? = nil, control: AgentControl? = nil) {
        self.clip = clip
        self.target = target
        self.faceGuide = faceGuide
        self.control = control
    }
}

// swiftlint:enable discouraged_optional_boolean

/// Corrects who a prepared clip replaces on one frame (#58): a click on the person (`x`, `y`, pixels of control.mp4
/// from the top left) or a mask (`file`, the inbox copy of the agent's `mask`, white = the person). The app re-tracks
/// that shot both ways from it and shows the frame before and after; `prepare_again` then applies it to the control
/// video, as do later preps of the clip.
public struct CorrectTargetCommand: Codable, Equatable, Sendable {
    public var clip: String
    /// A replaced person's id; nil: the first.
    public var person: Int?
    public var frame: Int
    public var x: Double?
    public var y: Double?
    /// The agent's path, recorded only, and the app's copy of it.
    public var mask: String?
    public var file: String?

    public init(
        clip: String, person: Int? = nil, frame: Int, x: Double? = nil, y: Double? = nil, mask: String? = nil,
        file: String? = nil
    ) {
        (self.clip, self.person, self.frame, self.x, self.y, self.mask, self.file) =
            (clip, person, frame, x, y, mask, file)
    }
}

/// A clip as an agent sees it. Paths are in the jobs folder (`~/Movies/Swapjutsu`), readable outside the sandbox.
public struct AgentClip: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var folder: String
    /// `waiting`, `preparing`, `prepared`, `failed` or `canceled`.
    public var stage: String
    /// Prep's latest line while it runs, its first warning once done, or why it stopped.
    public var progress: String
    public var range: AgentRange?
    public var target: AgentTarget
    public var faceGuide: Bool
    /// What paints the targets in control.mp4 (`AgentControl`).
    public var controlMode: AgentControl
    public var removeBackground: Bool
    public var prompt: String
    /// `@Image1…` in order. Who each replaces is in `people` (`character`, `views`); the rest replace no one.
    public var characters: [String]
    /// Replaced people without an image yet.
    public var missingCharacters: Int
    /// Once prepared.
    public var people: [AgentPerson]?
    public var warnings: [String]?
    public var control: String?
    public var review: String?
    public var renders: Int
    public var origin: AgentOrigin?
    /// The target fix on its way or done (`correct_target`); nil without one.
    public var fix: String?

    public init(
        id: String, title: String, folder: String, stage: String, progress: String, range: AgentRange?,
        target: AgentTarget, faceGuide: Bool, controlMode: AgentControl = .depth, removeBackground: Bool,
        prompt: String, characters: [String], missingCharacters: Int, people: [AgentPerson]?, warnings: [String]?,
        control: String?, review: String?, renders: Int, origin: AgentOrigin?, fix: String? = nil
    ) {
        self.fix = fix
        self.id = id
        self.title = title
        self.folder = folder
        self.stage = stage
        self.progress = progress
        self.range = range
        self.target = target
        self.faceGuide = faceGuide
        self.controlMode = controlMode
        self.removeBackground = removeBackground
        self.prompt = prompt
        self.characters = characters
        self.missingCharacters = missingCharacters
        self.people = people
        self.warnings = warnings
        self.control = control
        self.review = review
        self.renders = renders
        self.origin = origin
    }
}

/// Someone prep found.
public struct AgentPerson: Codable, Equatable, Sendable {
    /// For `target` and `set_characters`.
    public var id: Int
    /// Their face, cropped from the clip.
    public var crop: String?
    /// Share of all the people's area on screen.
    public var screenShare: Double
    public var isTarget: Bool
    /// The image that replaces them, for a target.
    public var character: String?
    /// More views of that character; nil without any.
    public var views: [String]?

    public init(
        id: Int, crop: String?, screenShare: Double, isTarget: Bool, character: String?, views: [String]? = nil
    ) {
        self.id = id
        self.crop = crop
        self.screenShare = screenShare
        self.isTarget = isTarget
        self.character = character
        self.views = views
    }
}

/// Which agent started a clip, when, and with which request.
public struct AgentOrigin: Codable, Equatable, Sendable {
    public var client: String
    public var requestID: String
    public var started: Date

    public init(client: String, requestID: String, started: Date) {
        self.client = client
        self.requestID = requestID
        self.started = started
    }

    private enum CodingKeys: String, CodingKey {
        case client, requestID = "requestId", started
    }
}

/// One file's bytes for the inbox, sent raw right after the request's line: exactly `size` of them. The app writes them
/// to `inbox/<folder>/<name>`, replacing an earlier copy in one step, and answers with the path (`uploaded`). A
/// refusal (agents off, a bad name, too big) can come before the bytes are read; the app then closes the connection.
public struct UploadCommand: Codable, Equatable, Sendable {
    public var folder: String
    public var name: String
    public var size: Int64

    public init(folder: String, name: String, size: Int64) {
        self.folder = folder
        self.name = name
        self.size = size
    }
}

/// Where the files an agent hands over wait for the app to adopt them: `inbox/<folder>/` next to the socket, inside
/// the app group's container for the sandboxed app. Only the app writes there. macOS keeps other apps' processes out
/// of a group container (App Data protection), the unsandboxed swapjutsu binary included, so the binary sends the
/// bytes over the socket (`UploadCommand`) rather than copying the file in.
public enum AgentInbox {
    public static let folderName = "inbox"
    /// The largest file an agent can hand over: 4 GiB, a long 4K source video. Each one is a full copy while it waits.
    public static let maxFileSize: Int64 = 4 << 30

    public static func url(socket: URL) -> URL {
        socket.deletingLastPathComponent().appending(path: folderName)
    }

    /// A request id, also an inbox folder's name: no path separators, no leading dot.
    public static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.count) && !name.hasPrefix(".") && name.allSatisfy(nameCharacters.contains)
    }

    /// A file's name in an inbox folder: any one path component up to 255 bytes that isn't hidden.
    public static func isValidFileName(_ name: String) -> Bool {
        (1...255).contains(name.utf8.count) && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    private static let nameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
}

extension AgentError.Code {
    /// The same request id came with other parameters.
    public static let requestConflict = Self(rawValue: "request_conflict")
    public static let noSuchClip = Self(rawValue: "no_such_clip")
    /// The clip isn't prepared yet: wait with `clips`.
    public static let notPrepared = Self(rawValue: "not_prepared")
    /// Prep or a render is on its way.
    public static let busy = Self(rawValue: "busy")
    /// A video or image the app can't use, with why.
    public static let fileRefused = Self(rawValue: "file_refused")
}
