import AVFoundation
import ComfyKit
import Foundation

/// Wan 3.0 edit straight through `api.comfy.org`, as ComfyUI's `Wan3ReferenceToVideoApi` runs it, paid from the same
/// prepaid Comfy credits as Seedance. It reads the same control video and characters, renders as long as the clip
/// and has no draft. Request IDs carry a `wan3:` prefix.
struct PartnerWan: GenerationProvider {
    static let prefix = "wan3:"

    let client: PartnerSeedanceClient

    static func owns(_ requestID: String) -> Bool { requestID.hasPrefix(prefix) }

    func submit(_ request: GenerationRequest) async throws -> String {
        guard case .edit(let control, let imageFiles, let prompt, let quality) = request else {
            throw GenerationError.rejected(
                "Wan 3.0 renders an edit of the clip, not a draft's final or Wan 2.2's inputs.")
        }
        let seconds = try await AVURLAsset(url: control).load(.duration).seconds
        guard seconds <= WanPrice.maxSeconds + 0.01 else {
            throw GenerationError.rejected("Wan 3.0 edits clips of up to 15 s.")
        }
        // The Seedance node's prompt when the person wrote none, so both read the same instructions.
        let text = try SeedanceWorkflow.referenceInputs(prompt: prompt, quality: quality).prompt
        var images: [String] = []
        for image in imageFiles { images.append(try await client.uploadWanImage(image)) }
        let video = try await client.uploadWanVideo(control)
        let body = try WanTaskRequest.reference(
            prompt: text, images: images, videos: [video], resolution: quality.resolution.uppercased(),
            seconds: WanPrice.outputSeconds(seconds))
        let id = try await ComfySeedance.sendOnce {
            do {
                return try await client.createWanTask(body)
            } catch ComfyError.idempotencyKeyReuse(let message) {
                throw GenerationError.outcomeUnknown(message)
            }
        }
        return Self.prefix + id
    }

    /// The node's poll: `PENDING` and `RUNNING` wait, `SUCCEEDED` carries the video link, `FAILED`, `CANCELED` and
    /// `UNKNOWN` carry Wan's code.
    func status(of requestID: String) async throws -> GenerationStatus {
        let task = try await client.wanTask(String(requestID.dropFirst(Self.owns(requestID) ? Self.prefix.count : 0)))
        if task.isFailed {
            let reason = [task.output?.code, task.output?.message].compactMap { $0 }.joined(separator: ": ")
            guard reason.isEmpty else { return .failed(reason) }
            return .failed("Wan 3.0 ended the task as \(task.output?.taskStatus ?? "failed").")
        }
        guard task.isSucceeded else { return .pending }
        guard let link = task.output?.videoURL.flatMap(URL.init(string:)) else {
            throw ComfyError.malformedResponse("Wan 3.0 returned no video link.")
        }
        return .completed(GenerationOutput(video: link))
    }

    /// The node has no cancel call: a Wan task runs to its end and is billed. Stopping only stops the wait.
    func cancel(_ requestID: String) async throws -> Bool { false }
}
