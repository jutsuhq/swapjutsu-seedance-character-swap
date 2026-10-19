import Foundation
import SwapjutsuDescribe
import SwapjutsuPrep
import os

private let logger = Logger(subsystem: "com.jutsustudio.swapjutsu", category: "Jobs")

typealias Describing = @Sendable (DescribeInput, @escaping @Sendable (String) -> Void) async -> SceneDescription?

enum Describers {
    /// The models Settings chose, read when a description starts; nil when the prompt writer is off.
    @MainActor
    static func live(_ models: VisionModels, isOn: Bool = true) -> @MainActor () -> Describing? {
        {
            let chain = isOn ? models.models() : []
            guard !chain.isEmpty else { return nil }
            return { input, log in await Describer(models: chain).describe(input, log: log) }
        }
    }
}

/// What prep's detached work hands back: the inputs copied into the job folder, the manifest and the description
/// written before prep.
struct Prepared: Sendable {
    let spec: JobSpec
    let manifest: Manifest
    let description: SceneDescription?
}

extension JobStore {
    /// Describes the clip again from its current characters, place and source, replacing its description, once
    /// prep and earlier descriptions are done.
    func describe(_ job: Job) {
        guard describer() != nil else { return }
        if let wait = describeWaits.removeValue(forKey: job.id) {
            wait.cancel()
        } else if job.isDescribing {
            return
        }
        job.isDescribing = true
        pendingDescriptions.append(job.id)
        pump()
    }

    /// The person's own edit; nil goes back to the prompt without a description. Neither is replaced on its own.
    func setDescription(_ description: SceneDescription?, of job: Job) {
        job.edit {
            $0.description = description
            $0.describedFrom = nil
            $0.describedByPerson = true
        }
        save(job)
    }

    /// The images a description of the clip reads: each replaced person's character in order, and the new place
    /// when the background is replaced.
    func descriptionImages(of job: Job) -> (characters: [URL], location: URL?) {
        let references = job.spec.references
        let characters =
            job.manifest == nil ? references : job.cast.compactMap(\.character).map { references[$0] }
        return (characters, job.replacesBackground ? job.spec.background : nil)
    }

    /// The images' file names, the place's marked: what `JobSpec.describedFrom` records.
    nonisolated static func describedInputs(_ characters: [URL], _ location: URL?) -> [String] {
        characters.map(\.lastPathComponent) + (location.map { ["place " + $0.lastPathComponent] } ?? [])
    }

    /// Describes a prepared clip again when its characters or place are not the ones its model-made description
    /// read: images added, swapped or taken off after prep, by the person or an agent. It waits `describeDelay`
    /// after the last change, so a burst of them is described once, and the clip shows as describing meanwhile.
    /// The person's own description stays, and so does one saved before the inputs were recorded.
    func describeIfStale(_ job: Job) {
        guard isStale(job), describer() != nil else { return }
        // Already queued or running: the queued one reads the clip as it is then, the running one checks again.
        if job.isDescribing, describeWaits[job.id] == nil { return }
        job.isDescribing = true
        describeWaits[job.id]?.cancel()
        describeWaits[job.id] = Task { [delay = describeDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.describeWaits[job.id] = nil
            guard self.isStale(job) else {
                job.isDescribing = false
                return
            }
            self.pendingDescriptions.append(job.id)
            self.pump()
        }
    }

    /// Whether the clip's characters or place are not the ones its model-made description read, or its several
    /// performers' moves were read only together.
    func isStale(_ job: Job) -> Bool {
        guard job.manifest != nil else { return false }
        let (characters, location) = descriptionImages(of: job)
        guard !characters.isEmpty, job.spec.describedByPerson != true else { return false }
        switch job.spec.describedFrom {
        case nil: return job.spec.description?.isDescribed != true || movesTogether(job)
        case let from?: return from != Self.describedInputs(characters, location) || movesTogether(job)
        }
    }

    /// Reads a prepared clip's edited prompt again `describeDelay` after the last edit, behind prep and the
    /// descriptions, so the prompt it sends folds the new words into its parts instead of taking them whole. A
    /// description waiting for its turn reads the prompt itself.
    func readWishSoon(_ job: Job) {
        guard job.manifest != nil, describer() != nil else { return }
        wishWaits[job.id]?.cancel()
        wishWaits[job.id] = Task { [delay = describeDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.wishWaits[job.id] = nil
            // A description waiting or running reads the prompt, and checks it again when it is done.
            guard self.isUnread(job), !job.isDescribing, !self.pendingWishes.contains(job.id) else { return }
            self.pendingWishes.append(job.id)
            self.pump()
        }
    }

    /// The clip's prompt is not the text its description's reading is of.
    func isUnread(_ job: Job) -> Bool {
        let text = job.spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && job.spec.description?.request?.text != text
    }

    /// Stops the clip's description and the reading of its prompt, running, queued or waiting out `describeDelay`.
    func cancelDescription(of job: Job) {
        describeWaits.removeValue(forKey: job.id)?.cancel()
        wishWaits.removeValue(forKey: job.id)?.cancel()
        pendingDescriptions.removeAll { $0 == job.id }
        pendingWishes.removeAll { $0 == job.id }
        work.cancel(.describe(job.id))
        work.cancel(.wish(job.id))
        job.isDescribing = false
    }

    /// Where each replaced performer stands, when prep told several apart and the description has one per
    /// character: each then gets their own moves and gaze.
    static func performers(of job: Job, characters: Int) -> [String] {
        let places = job.manifest?.seedance.brief?.places ?? []
        return places.count > 1 && places.count == characters ? places : []
    }

    /// Whether the clip's several performers have moves read only together: described before prep found where
    /// each stands, so only the moves are asked again.
    func movesTogether(_ job: Job) -> Bool {
        let places = Self.performers(of: job, characters: descriptionImages(of: job).characters.count)
        guard !places.isEmpty, let motion = job.spec.description?.motion else { return false }
        return motion.performers.count != places.count
    }

    /// Whether a description came back and replaced the clip's. The model reads off the main actor, in one detached
    /// task that canceling the description cancels (as `prepare` does). Its answer is dropped when the work was
    /// canceled, the clip was removed, or the description was edited while the model read.
    @discardableResult
    func redescribe(_ job: Job) async -> Bool {
        guard let describe = describer() else { return false }
        let spec = job.spec, output = job.output, revision = job.descriptionRevision
        let (characters, location) = descriptionImages(of: job)
        let wish = Self.wish(spec.prompt, people: characters.count, replacesBackground: location != nil)
        let performers = Self.performers(of: job, characters: characters.count)
        let inputs = Self.describedInputs(characters, location)
        // The same characters and place with the moves read together: only the moves are read again, apart.
        let same = spec.describedFrom.map { $0 == inputs } ?? (spec.description?.isDescribed == true)
        let known = same && movesTogether(job) ? spec.description : nil
        let work = Task.detached {
            await Self.describe(
                spec.source, characters, location, output, describe, wish: wish, performers: performers, known: known
            ) { _ in }
        }
        let described = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard let described, !Task.isCancelled, self.job(job.id) === job, job.descriptionRevision == revision else {
            return false
        }
        job.edit {
            $0.description = described
            $0.describedFrom = Self.describedInputs(characters, location)
            $0.describedByPerson = nil
        }
        save(job)
        return true
    }

    /// Reads the person's prompt `wish` again when the description's reading is of another text (or there is
    /// none), so the prompt folds it into its parts; with the prompt writer off, or while other heavy work holds the
    /// memory a model takes, the prompt has the wish whole (`Wish.verbatim`). It holds the heavy work slot while the
    /// model reads (`inSlot`: `pump` took it for this reading), and is canceled with the render or clip that asked.
    func readWish(_ wish: String, of job: Job, inSlot: Bool = false) async {
        let text = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, job.spec.description?.request?.text != text, let describe = describer(),
            inSlot || work.take(.wish(job.id))
        else { return }
        defer { if !inSlot { work.release(.wish(job.id)) } }
        let people = max(1, job.manifest?.targets.count ?? job.spec.references.count)
        let input = DescribeInput(
            characters: [], wish: Self.wish(text, people: people, replacesBackground: job.replacesBackground))
        let reading = Task.detached { await describe(input) { _ in } }
        let read = await withTaskCancellationHandler {
            await reading.value
        } onCancel: {
            reading.cancel()
        }
        guard let request = read?.request, !Task.isCancelled, self.job(job.id) === job else { return }
        job.edit { spec in
            var description = spec.description ?? SceneDescription(source: "Prompt read")
            description.request = request
            spec.description = description
        }
        save(job)
    }

    /// The person's prompt for `people` characters, the new place after them when the background is replaced; nil
    /// when it is empty.
    nonisolated static func wish(_ text: String, people: Int, replacesBackground: Bool) -> DescribeInput.WishInput? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return .init(text: text, people: max(1, people), place: replacesBackground ? max(1, people) + 1 : nil)
    }

    /// The description of a clip, its keyframes kept in `output`/describe, with the person's prompt read when there
    /// is one; nil when nothing could be described.
    nonisolated static func describe(
        _ source: URL, _ characters: [URL], _ location: URL?, _ output: URL, _ describe: Describing,
        wish: DescribeInput.WishInput? = nil, performers: [String] = [], known: SceneDescription? = nil,
        log: @escaping @Sendable (String) -> Void
    ) async -> SceneDescription? {
        do {
            var input = try await DescribeInput.make(
                video: source, characters: characters, location: location, folder: output.appending(path: "describe"))
            input.wish = wish
            input.performers = performers
            input.known = known
            return await describe(input, log)
        } catch {
            logger.error("Describing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
