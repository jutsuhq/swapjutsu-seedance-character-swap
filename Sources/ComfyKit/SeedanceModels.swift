import Foundation

// The request and response shapes of ComfyUI's Seedance partner nodes, as `comfy_api_nodes/apis/bytedance.py` defines
// them at ComfyUI 5cc4b870094c89090db54bd8d12649dcaf89f2ba (ComfyUI 0.41.0). The node serializes its pydantic models
// with `exclude_none=True`, so a field it leaves as `None` is absent here too.

/// `Seedance2TaskCreationRequest`: the body of `POST /proxy/byteplus/api/v3/contents/generations/tasks`.
public struct SeedanceTaskRequest: Sendable, Encodable, Equatable {
    /// One `content` entry: `TaskTextContent`, `TaskImageContent`, `TaskVideoContent` or `TaskDraftTaskContent`.
    public enum Content: Sendable, Encodable, Equatable {
        case text(String)
        case referenceImage(url: String)
        case referenceVideo(url: String)
        case draftTask(id: String)

        var json: JSONValue {
            switch self {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .referenceImage(let url):
                ["type": "image_url", "image_url": ["url": .string(url)], "role": "reference_image"]
            case .referenceVideo(let url):
                ["type": "video_url", "video_url": ["url": .string(url)], "role": "reference_video"]
            case .draftTask(let id): ["type": "draft_task", "draft_task": ["id": .string(id)]]
            }
        }

        public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
    }

    /// `SEEDANCE_MODELS["Seedance 2.5"]`, which is also the Draft model's ID.
    public static let seedance25 = "dreamina-seedance-2-5-260628"

    public var content: [Content]
    /// Every other field by its wire name (`model`, `generate_audio`, `resolution`, …); a field the node leaves as
    /// `None` is not in here.
    public var fields: [String: JSONValue]

    public init(content: [Content], fields: [String: JSONValue]) {
        self.content = content
        self.fields = fields
    }

    public func encode(to encoder: Encoder) throws {
        var object = fields
        object["content"] = .array(content.map(\.json))
        try JSONValue.object(object).encode(to: encoder)
    }

    /// The `ByteDance2ReferenceNodeV2` widgets, as an API-format workflow names them (`model.prompt` and so on).
    public struct ReferenceInputs: Sendable, Equatable {
        /// "Seedance 2.5" or "Seedance 2.5 Draft".
        public var model: String
        public var prompt: String
        public var resolution: String
        public var ratio: String
        public var duration: Int
        public var generateAudio: Bool
        public var taskType: String
        public var outputFormat: String?
        public var seed: Int
        public var watermark: Bool

        public init(
            model: String, prompt: String, resolution: String, ratio: String, duration: Int, generateAudio: Bool,
            taskType: String, outputFormat: String?, seed: Int, watermark: Bool
        ) {
            self.model = model
            self.prompt = prompt
            self.resolution = resolution
            self.ratio = ratio
            self.duration = duration
            self.generateAudio = generateAudio
            self.taskType = taskType
            self.outputFormat = outputFormat
            self.seed = seed
            self.watermark = watermark
        }
    }

    /// What `ByteDance2ReferenceNodeV2.execute` sends: the prompt, then the images, then the videos, through
    /// `_seedance2_build_request`. An edit takes its ratio and length from the video (`adaptive`, `-1`).
    public static func reference(_ inputs: ReferenceInputs, images: [String], videos: [String]) -> Self {
        var ratio = inputs.ratio
        var duration = inputs.duration
        if inputs.taskType == "edit" {
            (ratio, duration) = ("adaptive", -1)
        } else if inputs.taskType == "extend" {
            ratio = "adaptive"
        }
        var fields: [String: JSONValue] = [
            "model": .string(seedance25), "generate_audio": .bool(inputs.generateAudio),
            "resolution": .string(inputs.resolution), "ratio": .string(ratio), "duration": .number(Double(duration)),
            "seed": .number(Double(inputs.seed)), "watermark": .bool(inputs.watermark),
        ]
        if let format = inputs.outputFormat { fields["output_format"] = .string(format) }
        if inputs.taskType != "auto" { fields["omni_reference_task_type"] = .string(inputs.taskType) }
        if inputs.model == "Seedance 2.5 Draft" { fields["draft"] = true }
        return Self(
            content: [.text(inputs.prompt)] + images.map { .referenceImage(url: $0) }
                + videos.map { .referenceVideo(url: $0) },
            fields: fields)
    }

    /// What `ByteDance2DraftToFinalVideoNode.execute` sends: the draft's task, at 1080p.
    public static func draftToFinal(taskID: String, watermark: Bool) -> Self {
        Self(
            content: [.draftTask(id: taskID.trimmingCharacters(in: .whitespaces))],
            fields: ["model": .string(seedance25), "resolution": "1080p", "watermark": .bool(watermark)])
    }
}

/// `TaskStatusResponse`, from `GET /proxy/byteplus-seedance2/api/v3/contents/generations/tasks/{id}`.
public struct SeedanceTask: Sendable, Decodable, Equatable {
    public struct Failure: Sendable, Decodable, Equatable {
        public let code: String
        public let message: String
    }

    public let id: String
    public let model: String?
    /// `queued`, `running`, `cancelled`, `succeeded` or `failed`.
    public let status: String
    public let error: Failure?
    public let content: SeedanceTaskResult?

    /// `poll_op`'s default sets, which the Seedance poll uses; anything else is still in progress.
    public var isSucceeded: Bool { Self.completed.contains(status.lowercased()) }
    public var isFailed: Bool { Self.failed.contains(status.lowercased()) }

    static let completed: Set = ["succeeded", "succeed", "success", "completed", "finished", "done", "complete"]
    static let failed: Set = ["cancelled", "canceled", "canceling", "fail", "failed", "error"]
}

/// `TaskStatusResult`: where a finished task's video is.
public struct SeedanceTaskResult: Sendable, Decodable, Equatable {
    public let videoURL: String
    enum CodingKeys: String, CodingKey { case videoURL = "video_url" }
}

/// `SeedanceVirtualLibraryCreateAssetRequest`.
struct LibraryAssetRequest: Encodable {
    let url: String
    let hash: String
    /// Left out for an image: the server defaults to `Image`.
    let assetType: String?
    enum CodingKeys: String, CodingKey {
        case url, hash
        case assetType = "asset_type"
    }
}

/// `GetAssetResponse`, from `GET /proxy/seedance/assets/{id}`.
public struct SeedanceAsset: Sendable, Decodable, Equatable {
    public let id: String
    public let assetType: String?
    public let status: String
    public let error: SeedanceTask.Failure?

    enum CodingKeys: String, CodingKey {
        case id, status, error
        case assetType = "asset_type"
    }
}

/// `UploadResponse` of `POST /customers/storage`.
struct StorageUpload: Decodable {
    let downloadURL: String
    let uploadURL: String
    enum CodingKeys: String, CodingKey {
        case downloadURL = "download_url"
        case uploadURL = "upload_url"
    }
}

/// `SeedanceCreateAssetResponse`.
struct CreatedAsset: Decodable {
    let assetID: String
    enum CodingKeys: String, CodingKey { case assetID = "asset_id" }
}

/// `TaskCreationResponse`.
struct CreatedTask: Decodable {
    let id: String
}
