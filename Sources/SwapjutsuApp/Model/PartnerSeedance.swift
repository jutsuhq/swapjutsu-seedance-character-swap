import ComfyKit
import Foundation

/// Settings › Comfy: where a new Seedance render runs. Both routes take the same Comfy API key.
enum RenderRoute: String, CaseIterable, Identifiable, Sendable {
    /// Seedance through Comfy's Partner Nodes API, paid from prepaid credits.
    case direct
    /// The bundled workflow on Comfy Cloud, which needs a subscription.
    case cloud

    static let key = "comfy.route"

    /// Direct unless the person picked Cloud, for new installs and for those who never chose.
    static var current: RenderRoute {
        UserDefaults.standard.string(forKey: key).flatMap(RenderRoute.init(rawValue:)) ?? .direct
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .direct: "Direct"
        case .cloud: "Comfy Cloud"
        }
    }

    var detail: String {
        switch self {
        case .direct: "api.comfy.org, paid from prepaid credits; no subscription needed"
        case .cloud: "The bundled workflow on cloud.comfy.org; needs a Standard subscription"
        }
    }
}

extension SeedanceWorkflow {
    /// The Seedance node's widgets in the bundled workflow, so the direct route asks for what the Cloud route runs.
    static func referenceInputs(prompt: String, quality: RenderQuality) throws -> SeedanceTaskRequest.ReferenceInputs {
        let workflow = try load(template)
        guard let inputs = workflow.nodes["3"]?["inputs"]?.object else {
            throw ComfyError.invalidWorkflow("The bundled Seedance workflow has no Seedance node.")
        }
        func missing(_ key: String) -> Error {
            ComfyError.invalidWorkflow("The bundled Seedance workflow has no \(key).")
        }
        func value<T>(_ key: String, _ read: (JSONValue) -> T?) throws -> T {
            guard let found = inputs[key].flatMap(read) else { throw missing(key) }
            return found
        }
        func flag(_ key: String) throws -> Bool {
            guard case .bool(let found)? = inputs[key] else { throw missing(key) }
            return found
        }
        let text = prompt.isEmpty ? try value("model.prompt", \.string) : prompt
        // `validate_string(..., strip_whitespace=True, min_length=1)`.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GenerationError.rejected("The prompt is empty.")
        }
        return .init(
            model: quality.isDraft ? "Seedance 2.5 Draft" : "Seedance 2.5", prompt: text,
            resolution: quality.resolution, ratio: try value("model.ratio", \.string),
            duration: try value("model.duration", \.int), generateAudio: try flag("model.generate_audio"),
            taskType: try value("model.task_type", \.string), outputFormat: inputs["model.output_format"]?.string,
            seed: try value("seed", \.int), watermark: try flag("watermark"))
    }

    /// The Draft to Final node's `watermark` in the bundled workflow.
    static func finalWatermark() throws -> Bool {
        guard case .bool(let watermark)? = try load(finalTemplate)[input: "watermark", of: "1"] else { return false }
        return watermark
    }
}

extension JSONValue {
    fileprivate var int: Int? { if case .number(let value) = self, value.rounded() == value { Int(value) } else { nil } }
}

/// Seedance 2.5 edit straight through `api.comfy.org`, as ComfyUI's partner node runs it, paid from prepaid credits.
/// Request IDs carry a `seedance:` prefix, so a saved render resumes on this route whatever the setting is now.
struct PartnerSeedance: GenerationProvider {
    static let prefix = "seedance:"

    let client: PartnerSeedanceClient

    static func owns(_ requestID: String) -> Bool { requestID.hasPrefix(prefix) }

    /// Seedance's own task ID: the request ID without the route's prefix.
    static func taskID(of requestID: String) -> String {
        String(requestID.dropFirst(owns(requestID) ? prefix.count : 0))
    }

    func submit(_ request: GenerationRequest) async throws -> String {
        let body: SeedanceTaskRequest
        switch request {
        case .edit(let control, let imageFiles, let prompt, let quality):
            let inputs = try SeedanceWorkflow.referenceInputs(prompt: prompt, quality: quality)
            // The node's order: every image, then the video.
            var images: [String] = []
            for image in imageFiles { images.append(try await client.uploadReferenceImage(image)) }
            let video = try await client.uploadReferenceVideo(control)
            body = .reference(inputs, images: images, videos: [video])
        case .finalize(let draftTaskID):
            body = .draftToFinal(taskID: draftTaskID, watermark: try SeedanceWorkflow.finalWatermark())
        case .animate: throw GenerationError.rejected("Seedance renders an edit or a draft's final, not Wan's inputs.")
        }
        let id = try await ComfySeedance.sendOnce {
            do {
                return try await client.createTask(body)
            } catch ComfyError.idempotencyKeyReuse(let message) {
                // The server saw an earlier attempt of this create and can't say what became of it.
                throw GenerationError.outcomeUnknown(message)
            }
        }
        return Self.prefix + id
    }

    /// The node's poll: `queued` and `running` wait, `succeeded` carries the video link, `failed` and `cancelled`
    /// carry Seedance's code. A task's ID is also its draft's `draft_task_id`.
    func status(of requestID: String) async throws -> GenerationStatus {
        let id = Self.taskID(of: requestID)
        let task = try await client.task(id)
        if task.isFailed {
            let reason = task.error.map { "\($0.code): \($0.message)" } ?? "The task was \(task.status)."
            return .failed(ComfySeedance.explain(reason))
        }
        guard task.isSucceeded else { return .pending }
        // The render exists; a missing link is worth asking for again, not a reason to pay for a new one.
        guard let link = task.content.flatMap({ URL(string: $0.videoURL) }) else {
            throw ComfyError.malformedResponse("Seedance returned no video link.")
        }
        return .completed(GenerationOutput(video: link, draftTaskID: id))
    }

    /// The node has no cancel call: a Seedance task runs to its end and is billed. Stopping only stops the wait.
    func cancel(_ requestID: String) async throws -> Bool { false }
}

/// The provider for Seedance 2.5: new renders go the way Settings says, saved ones resume where they were sent.
struct SeedanceRoutes: GenerationProvider {
    let route: RenderRoute
    let cloud: any GenerationProvider
    let direct: any GenerationProvider

    func submit(_ request: GenerationRequest) async throws -> String {
        try await (route == .direct ? direct : cloud).submit(request)
    }

    func status(of requestID: String) async throws -> GenerationStatus {
        try await provider(for: requestID).status(of: requestID)
    }

    func cancel(_ requestID: String) async throws -> Bool {
        try await provider(for: requestID).cancel(requestID)
    }

    private func provider(for requestID: String) -> any GenerationProvider {
        PartnerSeedance.owns(requestID) ? direct : cloud
    }
}
