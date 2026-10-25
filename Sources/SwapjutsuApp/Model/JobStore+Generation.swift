import AVFoundation
import ComfyKit
import Foundation
import SwapjutsuPrep

/// A render's paid request: built, submitted once, polled, downloaded and exported. Its ID stays until the provider
/// finished, failed or confirmed a cancel, so every other stop resumes the same request.
extension JobStore {
    /// `model`: the render's generator when the send began; Create's picker may change while this reads and uploads.
    private func request(
        for render: Render, of job: Job, model: GenerationModel
    ) async throws -> GenerationRequest {
        // Sent before: the same inputs again, not the clip as it is now.
        if render.parent == nil, let snapshot = render.snapshot {
            return try resend(snapshot, render, of: job, model: model)
        }
        if model == .wan22Animate { return try await animateRequest(for: render, of: job) }
        if let parent = render.parent {
            guard let draftTaskID = job.render(parent)?.draftTaskID else {
                throw GenerationError.rejected("The draft this final comes from is gone.")
            }
            return .finalize(draftTaskID: draftTaskID)
        }
        guard let manifest = job.manifest else { throw GenerationError.rejected("The clip isn't prepared.") }
        await readWish(render.prompt, of: job)
        let (references, removeBackground, layout) = (job.spec.references, job.spec.removeBackground, job.layout)
        guard job.missingCharacters == 0 else {
            let missing = job.missingCharacters
            throw GenerationError.rejected(
                "\(missing) of the \(manifest.targets.count) people replaced \(missing == 1 ? "has" : "have") no "
                    + "character image; add one per person.")
        }
        // The prompt binds the grey to @Image<characters + 1>; without the image Seedance would invent a place.
        let background = job.replacesBackground ? job.spec.background : nil
        if job.replacesBackground, background == nil {
            throw GenerationError.rejected(
                "The background is replaced but there is no image of the new place; add one.")
        }
        // Vision's cutout and face close-ups take a moment per image; they run off the main actor.
        let uploads = try await Task.detached {
            try JobFiles.uploads(references, removeBackground: removeBackground, background: background, layout: layout)
        }.value
        return .edit(
            control: job.control, images: uploads.images,
            prompt: job.effectivePrompt(with: render.prompt, uploads: uploads), quality: render.quality)
    }

    /// A render sent before goes again with what it sent: its prompt and images, on the prep it was made from.
    private func resend(
        _ snapshot: RenderInputSnapshot, _ render: Render, of job: Job, model: GenerationModel
    ) throws -> GenerationRequest {
        guard snapshot.prepRevision == job.prepRevision else {
            throw GenerationError.rejected(
                "The clip was prepared again after this render was sent, so its control video changed. Render it "
                    + "again from Create.")
        }
        let images = snapshot.images.map(job.file(at:))
        guard images.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw GenerationError.rejected("An image this render sent is gone from the clip's folder. Render it again.")
        }
        if model == .wan22Animate, let character = images.first {
            return .animate(
                source: job.prepared, mask: job.mask, character: character, prompt: snapshot.prompt,
                quality: render.quality)
        }
        return .edit(control: job.control, images: images, prompt: snapshot.prompt, quality: render.quality)
    }

    /// What `request` sends, kept on the render. A final of a draft keeps the draft's inputs, which Seedance reuses.
    private func snapshot(
        of request: GenerationRequest, _ render: Render, of job: Job, backend: RenderBackend
    ) -> RenderInputSnapshot? {
        let (images, prompt): ([URL], String)
        switch request {
        case .edit(_, let sent, let text, _): (images, prompt) = (sent, text)
        case .animate(_, _, let character, let text, _): (images, prompt) = ([character], text)
        case .finalize:
            var parent = job.render(render.parent)?.snapshot
            parent?.backend = backend
            return parent
        }
        return RenderInputSnapshot(
            prompt: prompt, images: images.map(job.storedPath), references: job.spec.references.map(job.storedPath),
            prepRevision: job.prepRevision, backend: backend)
    }

    /// Keeps on the render what `request` sends and where (unless it was sent before and keeps its own), and returns
    /// the provider for that backend.
    private func keepInputs(
        of request: GenerationRequest, _ render: Render, of job: Job, model: GenerationModel
    ) throws -> any GenerationProvider {
        let backend = render.snapshot?.backend ?? .current(model)
        let provider = try providers(backend)
        let snapshot = render.snapshot ?? snapshot(of: request, render, of: job, backend: backend)
        job.update(render.id) { $0.snapshot = snapshot }
        return provider
    }

    /// The backend a render went to; for one sent before that was kept, the generator as Settings has it now.
    func backend(of render: Render, in job: Job) -> RenderBackend {
        render.snapshot?.backend ?? RenderBackend(model: job.model(of: render))
    }

    /// Wan 2.2 Animate's inputs: the prepared source (the background it keeps), prep's mask of the one replaced person,
    /// and that person's character, cut out when the clip says so.
    private func animateRequest(for render: Render, of job: Job) async throws -> GenerationRequest {
        if let reason = Self.whyNotAnimatable(job) { throw GenerationError.rejected(reason) }
        guard let index = job.layout.characters.first, job.spec.references.indices.contains(index) else {
            throw GenerationError.rejected("The replaced person has no character image; add one.")
        }
        let (reference, removeBackground) = (job.spec.references[index], job.spec.removeBackground)
        let character = try await Task.detached {
            try JobFiles.character(reference, removeBackground: removeBackground)
        }.value
        return .animate(
            source: job.prepared, mask: job.mask, character: character, prompt: render.prompt, quality: render.quality)
    }

    /// Why Wan 2.2 Animate can't render this clip, nil when it can. It replaces one person with one character and keeps
    /// the clip's own background, and prep's `mask.mp4` covers every replaced person at once, so it takes a clip
    /// prepared with one target and the background kept.
    static func whyNotAnimatable(_ job: Job) -> String? {
        guard let manifest = job.manifest else { return "The clip isn't prepared." }
        if manifest.targets.count > 1 {
            return "Wan 2.2 Animate replaces one person per render and this clip replaces \(manifest.targets.count). "
                + "Prepare it again with one person, or render it with Seedance."
        }
        if manifest.targets.isEmpty { return "Prep found no one to replace in this clip." }
        if job.replacesBackground {
            return "Wan 2.2 Animate keeps the clip's own background. Prepare it again with the background kept, or "
                + "render it with Seedance."
        }
        if job.missingCharacters > 0 { return "Add a character image for the replaced person first." }
        return nil
    }

    static func sendingDetail(_ model: GenerationModel, finalizing: Bool) -> String {
        if model == .wan22Animate { return "Sending the clip, its mask and the character to your ComfyUI" }
        return finalizing ? "Sending the draft's task" : "Uploading control.mp4 and the characters"
    }

    /// Where to look before sending again a request that may have arrived.
    static func checkFirst(_ model: GenerationModel) -> String {
        model == .wan22Animate
            ? "It may be in your ComfyUI's queue; check there before rendering again."
            : "It may have started on Comfy; check your history before rendering again."
    }

    /// Only `send` calls this. `reserved`: an agent's send, counted against the budget; it is given back unless the
    /// provider took the request or can't say whether it did (`outcomeUnknown`). Any other failure, before the paid
    /// request (no key, a missing character, an upload) or of it (no connection, a refusal), charged nothing.
    func submit(_ id: UUID, of job: Job, reserved: Bool) async {
        guard let render = job.render(id) else { return }
        let model = job.model(of: render)
        var mayBeCharged = false
        defer {
            if reserved, !mayBeCharged {
                job.update(id) { _ = $0.origin?.sends.popLast() }
                agentLedger.removeLast(of: id)
                save(job)
            }
        }
        do {
            let request = try await request(for: render, of: job, model: model)
            let provider = try keepInputs(of: request, render, of: job, model: model)
            job.update(id) {
                $0.stage = .uploading
                $0.detail = Self.sendingDetail(model, finalizing: render.parent != nil)
            }
            // Nothing is sent unless the job is on disk first: the paid request's ID is only safe in a record that
            // can be written.
            do {
                try persist(job)
            } catch {
                set(
                    id, of: job, .failed,
                    "Nothing was sent: job.json couldn't be saved (\(error.localizedDescription)).")
                return
            }
            let requestID = try await provider.submit(request)
            mayBeCharged = true
            job.update(id) {
                $0.providerJobID = requestID
                $0.generated = nil
                $0.stage = .generating
                $0.detail = "Request \(requestID)"
            }
            await saveSentRequest(requestID, id, of: job)
        } catch GenerationError.rejected(let reason) {
            set(id, of: job, .failed, reason)
            return
        } catch GenerationError.outcomeUnknown(let reason) {
            mayBeCharged = true
            set(id, of: job, .unknown, "\(reason) \(Self.checkFirst(model))")
            return
        } catch let error where error is CancellationError || (error as? URLError)?.code == .cancelled {
            // `sendOnce` makes a cancel during the paid request `outcomeUnknown`: this one came before it (an
            // upload), so nothing was charged and the reservation goes back.
            set(id, of: job, .canceled, "Canceled before the request was sent")
            return
        } catch {
            set(id, of: job, .failed, error.localizedDescription)
            return
        }
        await resume(id, of: job)
    }

    /// The ID of a request just paid for must reach disk. Until it does the render says so, with the ID, and the save
    /// is tried again; a canceled wait stops trying and the cancel path takes over.
    private func saveSentRequest(_ requestID: String, _ id: UUID, of job: Job) async {
        while true {
            do {
                try persist(job)
                return
            } catch {
                markUnsaved(id)
                job.update(id) {
                    $0.detail =
                        "Request \(requestID) was sent but couldn't be saved (\(error.localizedDescription)). "
                        + "Keep Swapjutsu open; saving again."
                }
                do { try await Task.sleep(for: saveRetryInterval) } catch { return }
            }
        }
    }

    /// Picks the request up where it stopped: polls, downloads once, exports. Errors keep the request.
    func resume(_ id: UUID, of job: Job) async {
        guard let sent = job.render(id), let requestID = sent.providerJobID else { return }
        let model = job.model(of: sent)
        do {
            let provider = try providers(backend(of: sent, in: job))
            if job.render(id)?.generated == nil {
                set(id, of: job, .generating, "Request \(requestID)")
                let output = try await poll(requestID, provider: provider)
                // Only a draft's task renders a final; the direct route names every task.
                job.update(id) { if $0.quality.isDraft { $0.draftTaskID = output.draftTaskID ?? $0.draftTaskID } }
                set(id, of: job, .downloading, "Downloading the render")
                let file = try await AppPaths.fetch(
                    output.video, to: job.output.appending(path: Self.downloadName(for: requestID, model: model)))
                job.update(id) { $0.generated = file.lastPathComponent }
                save(job)
            }
            guard let render = job.render(id), let generated = job.generatedURL(of: render) else { return }
            set(id, of: job, .exporting, "Putting the original soundtrack back")
            let name = "\(render.quality.rawValue)-\(render.id.uuidString.prefix(8)).mp4"
            // The control video's length, which Seedance doesn't keep (see `muxAudio`).
            let length = try? await AVURLAsset(url: job.control).load(.duration)
            try await muxAudio(
                video: generated, audioSource: job.source, output: job.output.appending(path: name), length: length)
            job.update(id) {
                $0.result = name
                $0.finished = Date()
            }
            set(id, of: job, .done, "")
        } catch GenerationError.rejected(let reason) {
            // The provider finished the request without a result: it is spent, a retry is a new generation.
            job.update(id) { $0.providerJobID = nil }
            set(id, of: job, .failed, reason)
        } catch ComfyError.notFound(let message) {
            // The provider no longer knows the request (expired, or never kept): polling it again can't help, so
            // Retry is a new generation instead of a resume that fails the same way forever.
            job.update(id) { $0.providerJobID = nil }
            set(
                id, of: job, .failed,
                "Comfy no longer has request \(requestID) (\(message)). Retry sends it again, at the full price.")
        } catch {
            if Task.isCancelled || error is CancellationError {
                if job.render(id)?.stage == .generating {
                    await stop(requestID, id, of: job)
                } else {
                    set(id, of: job, .canceled, "Canceled")
                }
            } else {
                set(
                    id, of: job, .failed,
                    "\(error.localizedDescription) Retry resumes request \(requestID) at no extra cost.")
            }
        }
    }

    /// Cancels a generating request on the provider. Its ID goes only once the provider confirmed the cancel; a
    /// provider that can't cancel, or a cancel that failed, leaves the paid request running and its ID kept, so
    /// Resume polls that request instead of paying for a new one.
    private func stop(_ requestID: String, _ id: UUID, of job: Job) async {
        set(id, of: job, .canceled, "Canceling request \(requestID)")
        let backend = job.render(id).map { self.backend(of: $0, in: job) } ?? RenderBackend(model: job.model)
        // The wait was canceled; the cancel call itself runs in its own task so it still reaches the provider.
        let outcome = await Task { try await self.providers(backend).cancel(requestID) }.result
        let charged = "it may still finish and be charged. Resume picks it up at no extra cost."
        switch outcome {
        case .success(true):
            job.update(id) { $0.providerJobID = nil }
            set(id, of: job, .canceled, "Canceled")
        case .success(false):
            set(
                id, of: job, .canceled,
                "Stopped waiting. Seedance can't stop request \(requestID) once it started: \(charged)")
        case .failure(let error):
            set(
                id, of: job, .canceled,
                "Couldn't cancel request \(requestID) (\(error.localizedDescription)): \(charged)")
        }
    }

    /// "seedance-cgt-…", "wan3-<task id>", "wan-<prompt id>": the route's prefix would repeat the name, and its ":"
    /// shows as "/" in Finder. Renders downloaded before keep their old name in `generated`.
    static func downloadName(for requestID: String, model: GenerationModel = .seedance25) -> String {
        let id =
            PartnerWan.owns(requestID) ? String(requestID.dropFirst(PartnerWan.prefix.count))
            : PartnerSeedance.taskID(of: requestID)
        let safe = id.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "-" }
        let name =
            switch model {
            case .seedance25: "seedance-"
            case .wan30: "wan3-"
            case .wan22Animate: "wan-"
            }
        return name + String(safe)
    }

    private func poll(_ id: String, provider: any GenerationProvider) async throws -> GenerationOutput {
        for _ in 0..<maxPolls {
            switch try await provider.status(of: id) {
            case .completed(let output): return output
            case .failed(let reason): throw GenerationError.rejected(reason)
            case .pending: try await Task.sleep(for: pollInterval)
            }
        }
        throw URLError(.timedOut)
    }
}
