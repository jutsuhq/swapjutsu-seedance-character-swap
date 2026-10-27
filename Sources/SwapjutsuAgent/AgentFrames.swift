import Foundation

/// Still frames of a finished render beside the same moment of its clip and of control.mp4, so an agent can check a
/// swap without grabbing frames itself. Free, and nothing is sent anywhere.
public struct FramesCommand: Codable, Equatable, Sendable {
    /// Times when `seconds` is left out: spread evenly over the clip.
    public static let defaultCount = 4
    public static let maxCount = 12

    /// A finished render's id.
    public var render: String
    /// Seconds into the clip, each within its length; at most `maxCount`.
    public var seconds: [Double]?
    /// How many times to spread evenly when `seconds` is left out, 1 to `maxCount`.
    public var count: Int?

    public init(render: String, seconds: [Double]? = nil, count: Int? = nil) {
        self.render = render
        self.seconds = seconds
        self.count = count
    }
}

/// What `frames` wrote: a folder of its own per call, with one contact sheet and the frames it is made of.
public struct AgentFrames: Codable, Equatable, Sendable {
    /// The sheet's columns, left to right: the clip as it was, control.mp4 (what the generator read), the render.
    public static let columns = ["source", "control", "render"]

    public var render: String
    public var folder: String
    /// One row per time, with the columns in `columns` order.
    public var sheet: String
    public var columns = Self.columns
    public var frames: [AgentFrame]

    public init(render: String, folder: String, sheet: String, frames: [AgentFrame]) {
        self.render = render
        self.folder = folder
        self.sheet = sheet
        self.frames = frames
    }
}

/// One row of the sheet: the three files at one moment of the clip.
public struct AgentFrame: Codable, Equatable, Sendable {
    public var seconds: Double
    public var source: String
    public var control: String
    public var render: String

    public init(seconds: Double, source: String, control: String, render: String) {
        self.seconds = seconds
        self.source = source
        self.control = control
        self.render = render
    }
}
