import Foundation

// The request and response shapes of ComfyUI's `Wan3ReferenceToVideoApi` node, as `comfy_api_nodes/apis/wan.py` and
// `nodes_wan.py` define them on ComfyUI master of 2026-10-24.

/// `Wan3MediaItem`.
public struct WanMedia: Sendable, Encodable, Equatable {
    public let type: String
    public let url: String
}

/// `Wan3InputField`.
public struct WanInput: Sendable, Encodable, Equatable {
    public let prompt: String
    public let media: [WanMedia]
}

/// `Wan3ParametersField`.
public struct WanParameters: Sendable, Encodable, Equatable {
    public let resolution: String
    public let ratio: String
    public let duration: Int
    public let seed: Int
    public let audio: Bool
    public let promptExtend: Bool
    public let watermark: Bool

    enum CodingKeys: String, CodingKey {
        case resolution, ratio, duration, seed, audio, watermark
        case promptExtend = "prompt_extend"
    }
}

/// `Wan3TaskCreationRequest`: the body of `POST /proxy/wan/api/v1/services/aigc/video-generation/video-synthesis`.
public struct WanTaskRequest: Sendable, Encodable, Equatable {
    public static let model = "wan3.0-video"

    public let model: String
    public let input: WanInput
    public let parameters: WanParameters

    /// What the node sends for an edit: the prompt with its `@Image1`/`@Video1` tags spelled out, every image, then
    /// the videos; `adaptive` ratio, so the frame follows the video. Prompt extension is off, so Wan reads the prompt
    /// the app wrote and not its own rewrite of it.
    public static func reference(
        prompt: String, images: [String], videos: [String], resolution: String, seconds: Int, seed: Int = 42
    ) throws -> Self {
        let text = try WanPrompt.spellOutTags(prompt, images: images.count, videos: videos.count)
        return Self(
            model: model,
            input: WanInput(
                prompt: text,
                media: images.map { WanMedia(type: "reference_image", url: $0) }
                    + videos.map { WanMedia(type: "reference_video", url: $0) }),
            parameters: WanParameters(
                resolution: resolution, ratio: "adaptive", duration: seconds, seed: seed, audio: true,
                promptExtend: false, watermark: false))
    }
}

/// `TaskCreationOutputField`.
struct WanCreatedOutput: Decodable {
    let taskID: String
    enum CodingKeys: String, CodingKey { case taskID = "task_id" }
}

/// `TaskCreationResponse`: no `output` means Wan refused the task, with `code` and `message` saying why.
struct WanCreatedTask: Decodable {
    let output: WanCreatedOutput?
    let code: String?
    let message: String?
}

/// `VideoTaskStatusOutputField`.
public struct WanTaskOutput: Sendable, Decodable, Equatable {
    public let taskStatus: String
    public let videoURL: String?
    public let code: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case code, message
        case taskStatus = "task_status"
        case videoURL = "video_url"
    }
}

/// `VideoTaskStatusResponse`, from `GET /proxy/wan/api/v1/tasks/{id}`.
public struct WanTask: Sendable, Decodable, Equatable {
    public let output: WanTaskOutput?

    /// `poll_op`'s sets with Wan 3.0's additions: `PENDING` waits, `UNKNOWN` (an expired task) has failed.
    public var isSucceeded: Bool { SeedanceTask.completed.contains(status) }
    public var isFailed: Bool { SeedanceTask.failed.contains(status) || status == "unknown" }

    var status: String { output?.taskStatus.lowercased() ?? "" }
}

enum WanPrompt {
    /// `_wan3_rewrite_reference_prompt`: `@Image2` becomes `Image 2` (a bare `@Video` is 1), the way Wan's API
    /// names its references. A tag glued to a preceding letter, digit or `_` is left alone unless it directly follows
    /// another tag; one past the inputs sent is an error, as in the node.
    static func spellOutTags(_ prompt: String, images: Int, videos: Int, audios: Int = 0) throws -> String {
        let counts = ["image": images, "video": videos, "audio": audios]
        let pattern = try NSRegularExpression(
            pattern: "@(image|video|audio)([0-9]*)(?![A-Za-z0-9_])", options: .caseInsensitive)
        let text = prompt as NSString
        var result = ""
        var position = 0
        var previousEnd = -1
        for match in pattern.matches(in: prompt, range: NSRange(location: 0, length: text.length)) {
            let start = match.range.location
            if start > 0, start != previousEnd {
                let before = text.substring(with: NSRange(location: start - 1, length: 1))
                let isWordCharacter = before.unicodeScalars.allSatisfy {
                    $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
                }
                if isWordCharacter { continue }
            }
            let kind = text.substring(with: match.range(at: 1)).lowercased()
            let digits = text.substring(with: match.range(at: 2))
            let index = Int(digits) ?? 1
            let total = counts[kind] ?? 0
            guard total > 0, (1...total).contains(index) else {
                throw ComfyError.invalidWorkflow(
                    "The prompt names @\(kind.capitalized)\(index), but only \(total) reference \(kind) inputs "
                        + "are sent.")
            }
            result += text.substring(with: NSRange(location: position, length: start - position))
            result += "\(kind.capitalized) \(index)"
            position = start + match.range.length
            previousEnd = position
        }
        return result + text.substring(from: position)
    }
}
