import Foundation
import SwapjutsuPrep
import os

private let logger = Logger(subsystem: "com.jutsustudio.swapjutsu", category: "Jobs")

extension JobStore {
    /// Prep runs off the main actor, inside one detached task; canceling the job cancels it.
    func prepare(_ job: Job) async {
        job.startPrep()
        setPrep(job, .preparing, job.spec.range == nil ? "Copying the inputs into the job folder" : "Cutting the range")
        let (spec, output, preparer) = (job.spec, job.output, preparer)
        // Before prep, in the same slot, so the model is unloaded before depth and tracking load.
        let own = spec.description?.isDescribed == true || spec.describedByPerson == true
        let describe = own ? nil : describer()
        let work = Task.detached { () async throws -> Prepared in
            let adopted = try await JobFiles.adopt(spec, into: output)
            let log: @Sendable (String) -> Void = { line in Task { @MainActor in job.detail = line } }
            var described: SceneDescription?
            if let describe {
                log("Describing the characters and the moves")
                let location = adopted.replaceBackground ? adopted.background : nil
                described = await Self.describe(
                    adopted.source, adopted.references, location, output, describe,
                    wish: Self.wish(spec.prompt, people: adopted.references.count, replacesBackground: location != nil),
                    log: log)
                try Task.checkCancellation()
            }
            let manifest = try await preparer(adopted, output, log)
            return Prepared(spec: adopted, manifest: manifest, description: described)
        }
        do {
            let prepared = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            let (adopted, manifest, described) = (prepared.spec, prepared.manifest, prepared.description)
            try Task.checkCancellation()
            // Characters, the prompt and options may have changed while prep ran; only the copies are taken over.
            let copies = Dictionary(zip(spec.references, adopted.references)) { first, _ in first }
            job.edit { current in
                current.source = adopted.source
                current.references = current.references.map { copies[$0] ?? $0 }
                if current.description?.isDescribed != true, current.describedByPerson != true, let described {
                    current.description = described
                    current.describedFrom = Self.describedInputs(
                        adopted.references, adopted.replaceBackground ? adopted.background : nil)
                }
            }
            job.takePrep(manifest)
            setPrep(job, .prepared, manifest.warnings.first ?? "")
            // The description before prep read every image; once prep knows who is replaced, it reads their
            // characters, and those added or changed while prep ran; a prompt edited while it ran is read again.
            describeIfStale(job)
            readWishSoon(job)
        } catch {
            if Task.isCancelled || error is CancellationError {
                setPrep(job, .canceled, "Prep canceled")
            } else {
                logger.error("Prep failed: \(error.localizedDescription, privacy: .public)")
                setPrep(job, .failed, error.localizedDescription)
            }
        }
    }
}
