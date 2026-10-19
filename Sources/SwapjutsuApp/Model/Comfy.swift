import ComfyKit
import Foundation

/// The bundled workflows (`Resources/Workflows/*.api.json`) with this job's assets and prompt filled in. Extra
/// characters get a `LoadImage` node each (11, 12, …), wired to `@Image2…`.
enum SeedanceWorkflow {
    // `.process` flattens Resources/, so the files sit at the bundle root.
    static let template = Bundle.module.url(forResource: "seedance-character-swap.api", withExtension: "json")
    static let finalTemplate = Bundle.module.url(forResource: "seedance-draft-to-final.api", withExtension: "json")

    /// The node that saves a draft's `draft_task_id` as a text output.
    static let draftTaskNode = "5"

    static func make(control: Asset, images: [Asset], prompt: String, quality: RenderQuality) throws -> Workflow {
        var workflow = try load(template)
        guard let loader = workflow.nodes["2"], workflow.nodes["3"] != nil else {
            throw ComfyError.invalidWorkflow("The bundled Seedance workflow has no loader or Seedance node.")
        }
        workflow[input: "file", of: "1"] = Workflow.reference(to: control)
        workflow.nodes["2"] = nil
        for (index, image) in images.enumerated() {
            let node = index == 0 ? "2" : "\(10 + index)"
            workflow.nodes[node] = loader
            workflow[input: "image", of: node] = Workflow.reference(to: image)
            workflow[input: "model.reference_images.image_\(index + 1)", of: "3"] = Workflow.link(node)
        }
        workflow[input: "model", of: "3"] = quality.isDraft ? "Seedance 2.5 Draft" : "Seedance 2.5"
        workflow[input: "model.resolution", of: "3"] = .string(quality.resolution)
        // Only the Draft model has a draft_task_id; the node refuses a final with that output linked.
        if !quality.isDraft { workflow.nodes[draftTaskNode] = nil }
        if !prompt.isEmpty { workflow[input: "model.prompt", of: "3"] = .string(prompt) }
        return workflow
    }

    /// The Draft to Final node: Seedance reuses the draft's prompt, references, duration and audio setting.
    static func finalize(draftTaskID: String) throws -> Workflow {
        var workflow = try load(finalTemplate)
        guard workflow.nodes["1"] != nil else {
            throw ComfyError.invalidWorkflow("The bundled Draft to Final workflow has no Seedance node.")
        }
        workflow[input: "draft_task_id", of: "1"] = .string(draftTaskID)
        return workflow
    }

    static func load(_ url: URL?) throws -> Workflow {
        guard let url else { throw ComfyError.invalidWorkflow("A bundled Seedance workflow is missing.") }
        return try Workflow(apiFormat: Data(contentsOf: url))
    }
}

/// Seedance 2.5 edit as a workflow on Comfy Cloud; the same Comfy API key pays for the partner node.
struct ComfySeedance: GenerationProvider {
    let client: ComfyClient

    func submit(_ request: GenerationRequest) async throws -> String {
        let workflow: Workflow
        switch request {
        case .edit(let controlFile, let imageFiles, let prompt, let quality):
            let control = try await client.upload(controlFile)
            var images: [Asset] = []
            for image in imageFiles { images.append(try await client.upload(image)) }
            workflow = try SeedanceWorkflow.make(control: control, images: images, prompt: prompt, quality: quality)
        case .finalize(let draftTaskID):
            workflow = try SeedanceWorkflow.finalize(draftTaskID: draftTaskID)
        case .animate: throw GenerationError.rejected("Seedance renders an edit or a draft's final, not Wan's inputs.")
        }
        return try await Self.sendOnce { try await client.submit(workflow, partnerAPIKey: client.apiKey).id }
    }

    /// The paid request itself, after the inputs are uploaded. A submit that failed after it may have reached Comfy
    /// becomes `.outcomeUnknown`, so nothing pays twice. A cancel before it starts sent nothing; one while it runs
    /// doesn't say whether the request arrived.
    static func sendOnce(_ submit: () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        do {
            return try await submit()
        } catch let error as ComfyError {
            switch error {
            // A 5xx or an unreadable 2xx: the job may exist, and the same key can't be used again.
            case .rejected(let status, _, _) where status >= 500:
                throw GenerationError.outcomeUnknown(error.localizedDescription)
            // The server still had the request in flight when the client stopped waiting for it.
            case .rejected(409, ComfyError.inFlight, _): throw GenerationError.outcomeUnknown(error.localizedDescription)
            case .malformedResponse: throw GenerationError.outcomeUnknown(error.localizedDescription)
            default: throw error
            }
        } catch is CancellationError {
            throw GenerationError.outcomeUnknown(canceledWhileSending)
        } catch let error as URLError where error.code == .cancelled {
            throw GenerationError.outcomeUnknown(canceledWhileSending)
        } catch let error as URLError where !ComfyClient.neverDelivered(error) {
            throw GenerationError.outcomeUnknown(error.localizedDescription)
        }
    }

    static let canceledWhileSending = "Canceled while the request was being sent, so it may have arrived."

    /// Comfy Cloud's cancel endpoint answering 2xx is its confirmation.
    func cancel(_ requestID: String) async throws -> Bool {
        try await client.cancel(requestID)
        return true
    }

    /// A finished job's video, re-minted as a signed link that downloads without the key, and a draft's task ID.
    func status(of requestID: String) async throws -> GenerationStatus {
        let job = try await client.job(requestID)
        guard job.status.isTerminal else { return .pending }
        guard job.status == .succeeded else {
            return .failed(Self.explain(job.error?.message ?? "The job \(job.status.rawValue)."))
        }
        guard let video = job.outputs.first(where: { $0.contentType.hasPrefix("video/") }) else {
            return .failed("The workflow finished without a video.")
        }
        // The render exists; a missing link is worth asking for again, not a reason to pay for a new one.
        guard let link = try await client.asset(video.id).url else {
            throw ComfyError.malformedResponse("Comfy returned no download link for the video.")
        }
        return .completed(GenerationOutput(video: link, draftTaskID: try await draftTaskID(in: job)))
    }

    /// The text the draft's Save Text node wrote. A draft without one still has its video; it just can't be
    /// finalized.
    private func draftTaskID(in job: ComfyKit.Job) async throws -> String? {
        guard let output = job.outputs.first(where: { $0.nodeId == SeedanceWorkflow.draftTaskNode }),
            let link = try await client.asset(output.id).url
        else { return nil }
        let (data, response) = try await URLSession.shared.data(from: link)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// Seedance's own error codes arrive inside the node's message.
    static func explain(_ message: String) -> String {
        if message.contains("TaskTypeConstraint") || message.contains("4 to 30 seconds") {
            return "Seedance edits clips of 4–30 s only."
        }
        if message.contains("TaskTypeMismatch") {
            return "Seedance didn't read the prompt as an edit; use replace/change wording."
        }
        if message.contains("OutputAudioSensitiveContentDetected")
            || message.contains("audio track this model generated")
        {
            return "Seedance rejected the audio it generated (possible copyright match). Try again."
        }
        return message
    }
}
