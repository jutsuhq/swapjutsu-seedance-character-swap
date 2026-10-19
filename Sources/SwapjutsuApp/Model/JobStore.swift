import Foundation
import Observation
import SwapjutsuDescribe
import SwapjutsuPrep
import os

private let logger = Logger(subsystem: "com.jutsustudio.swapjutsu", category: "Jobs")

/// Runs prep for a spec into a folder; the real one is `Pipeline`, tests pass a stand-in.
typealias Preparer = @Sendable (JobSpec, URL, @escaping @Sendable (String) -> Void) async throws -> Manifest

/// Describes a clip's characters, place and moves for the prompt; nil when no model could. The real one is a
/// `Describer` over `VisionModels.models()`, tests pass a stand-in.
enum Preparers {
    /// The real prep, with the depth and tracking models fetched first when the app has none yet, and the model
    /// instances `DepthModel` and `TrackingModel` keep loaded (or are loading) rather than fresh ones per run. The
    /// tracking models download while the people pass runs; when they cannot be fetched or loaded the prep keeps
    /// Vision's masks and says why in the manifest.
    @MainActor
    static func pipeline(_ depth: DepthModel, tracking: TrackingModel) -> Preparer {
        { spec, output, log in
            let trackingFolder = Task { try await tracking.ensure(log: log) }
            let model = try await depth.ensure(log: log)
            var stages = PrepStages.standard(tuning: spec.options.tuning) { try await depth.model(for: model) }
            let context = stages.context
            stages.tracking = {
                EdgeTAMTracker(models: try await tracking.model(for: try await trackingFolder.value), context: context)
            }
            return try await Pipeline(options: spec.options, stages: stages, log: log)
                .run(video: spec.source, output: output)
        }
    }
}

/// Runs prep one clip at a time on the Mac, then Seedance renders of prepared clips: drafts, finals, and finals of
/// drafts.
///
/// A job's state lives in its folder (`job.json`) and is saved at every step. Once a provider request exists its ID
/// is kept until the request finished or failed on the provider's side, so a lost connection, a failed download or
/// a failed export resumes that request instead of paying for a new one.
@MainActor
@Observable
final class JobStore {
    private(set) var jobs: [Job] = []
    /// Prep, a description or the reading of a prompt holds the memory a model takes (`JobWork`'s slot).
    var isBusy: Bool { work.isBusy }
    /// Clips whose description was asked for on the clip, waiting for their turn.
    var pendingDescriptions: [UUID] = []
    /// Prepared clips whose edited prompt waits for a model's reading, after the descriptions.
    var pendingWishes: [UUID] = []
    /// How long a prepared clip's characters, place or prompt stay unchanged before a model reads them again, so a
    /// burst of edits (an agent's set_characters, typing) is read once.
    let describeDelay: Duration
    /// The waits of `describeDelay` by clip, for a description and for a prompt's reading.
    var describeWaits: [UUID: Task<Void, Never>] = [:]
    var wishWaits: [UUID: Task<Void, Never>] = [:]
    /// The describer to use now, nil when Settings has it off.
    let describer: @MainActor () -> Describing?
    /// Prep and description tasks by clip, render tasks by render, and the heavy work slot.
    let work = JobWork()
    private let root: URL
    let providers: ProviderFactory
    let preparer: Preparer
    let pollInterval: Duration
    let maxPolls: Int
    /// How long a sent request whose ID couldn't be written waits before the save is tried again.
    let saveRetryInterval: Duration
    /// Renders whose sent request isn't on disk yet: quitting now would lose it.
    private(set) var unsaved: Set<UUID> = []
    /// Settings › Agents › daily agent budget in USD, read before every send an agent asks for.
    let agentBudget: @MainActor () -> Double
    /// What agents' sends took of each day's budget, kept whatever happens to the renders.
    let agentLedger: AgentLedger

    /// `providers` and `preparer` are injected so tests run without a key, the network or the depth model.
    /// `restoresJobs: false` (the smoke-test launch) leaves the jobs on disk alone: none is loaded, saved, resumed
    /// or prepared.
    init(
        root: URL = AppPaths.jobs, providers: @escaping ProviderFactory,
        preparer: @escaping Preparer,
        pollInterval: Duration = .seconds(10), maxPolls: Int = 360, saveRetryInterval: Duration = .seconds(5),
        restoresJobs: Bool = true,
        agentBudget: @escaping @MainActor () -> Double = { 0 }, agentLedger: URL? = nil,
        describer: @escaping @MainActor () -> Describing? = { nil }, describeDelay: Duration = .seconds(2)
    ) {
        self.describer = describer
        self.describeDelay = describeDelay
        self.root = root
        self.providers = providers
        self.preparer = preparer
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
        self.saveRetryInterval = saveRetryInterval
        self.agentBudget = agentBudget
        self.agentLedger = AgentLedger(
            file: restoresJobs ? agentLedger ?? root.appending(path: "agent-spend.json") : nil)
        work.onFree = { [weak self] in self?.pump() }
        if restoresJobs { restore() }
    }

    /// Prep and renders on their way, and agents' renders waiting for the person, for the Jobs badge.
    var activeCount: Int {
        jobs.reduce(0) {
            $0 + ($1.stage.isActive ? 1 : 0) + $1.renders.filter { $0.stage.isActive || $0.stage == .waiting }.count
        }
    }

    /// Prepared clips never rendered, for the Create badge.
    var readyCount: Int { jobs.filter(\.isReady).count }

    func job(_ id: UUID?) -> Job? { jobs.first { $0.id == id } }

    @discardableResult
    func enqueue(_ spec: JobSpec, origin: JobOrigin? = nil) -> Job {
        let id = UUID()
        let job = Job(spec: spec, output: AppPaths.newJobFolder(named: spec.title, id: id, in: root), id: id)
        job.origin = origin
        jobs.insert(job, at: 0)
        save(job)
        pump()
        return job
    }

    /// Forgets the clip and its renders, and stops its description; the files stay on disk. It leaves the list
    /// before its record goes, so work that ends later can't write the record back (`persist`).
    func remove(_ job: Job) {
        guard !job.isActive, !job.hasLiveRequest else { return }
        cancelDescription(of: job)
        jobs.removeAll { $0.id == job.id }
        try? FileManager.default.removeItem(at: job.recordURL)
    }

    /// Takes a render off the lists (Library, Jobs); its files stay in the job folder.
    func remove(_ render: Render, of job: Job) {
        guard render.canDismiss else { return }
        job.renders.removeAll { $0.id == render.id }
        save(job)
    }

    func setPrompt(_ prompt: String, of job: Job) {
        job.edit { $0.prompt = prompt }
        save(job)
        readWishSoon(job)
    }

    /// Puts character images on the clip, copied into its folder, after the last. With `person` (a replaced
    /// person's id) the first one becomes theirs (`JobSpec.assign`): their character, or with `asView` one more view
    /// of it. An image the clip already has is not copied again, only reassigned, so a drag within Create moves it.
    /// Returns why images were refused, if any were.
    @discardableResult
    func addReferences(_ urls: [URL], to job: Job, person: Int? = nil, asView: Bool = false) -> String? {
        if let url = urls.first,
            let index = job.spec.references.firstIndex(where: { $0.standardizedFileURL == url.standardizedFileURL })
        {
            assign(index, to: person, asView: asView, of: job)
            return nil
        }
        var refused: [String] = []
        var added: [URL] = []
        for url in urls {
            if let problem = Draft.imageProblem(url) {
                refused.append("\(url.lastPathComponent) \(problem)")
                continue
            }
            do {
                added.append(try JobFiles.addCharacter(url, into: job.output))
            } catch {
                refused.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let room = Draft.maxReferences - job.spec.references.count
        let targets = job.manifest?.targets
        job.edit { spec in
            // A prepared clip's images keep their people from now on, whatever is added after them.
            if let targets, spec.cast == nil { spec.cast = spec.cast(for: targets) }
            let first = spec.references.count
            spec.references += added.prefix(max(0, room))
            if let person, let targets, spec.references.count > first {
                let replaced = asView ? nil : spec.cast(for: targets).first { $0.person == person }?.character
                spec.assign(first, to: person, asView: asView, targets: targets)
                // A new file for someone replaces their image, as it always has; a drag keeps it as an extra.
                if let replaced, spec.extras(for: targets).contains(replaced) { spec.removeReference(at: replaced) }
            }
        }
        save(job)
        describeIfStale(job)
        if !refused.isEmpty { return "Seedance can't use " + refused.joined(separator: "; ") + "." }
        return added.count > room ? "Swapjutsu takes up to \(Draft.maxReferences) character images." : nil
    }

    /// Gives the clip's image at `index` to a replaced person, or with `person` nil to no one (an extra).
    func assign(_ index: Int, to person: Int?, asView: Bool = false, of job: Job) {
        guard let targets = job.manifest?.targets else { return }
        job.edit { $0.assign(index, to: person, asView: asView, targets: targets) }
        save(job)
        describeIfStale(job)
    }

    /// Takes a character off the clip; the ones after it move up a place, and every other image keeps its person.
    /// Its file stays in the folder.
    func removeReference(at index: Int, of job: Job) {
        guard job.spec.references.indices.contains(index) else { return }
        let targets = job.manifest?.targets
        job.edit { spec in
            if let targets, spec.cast == nil { spec.cast = spec.cast(for: targets) }
            spec.removeReference(at: index)
        }
        save(job)
        describeIfStale(job)
    }

    /// Puts the image of the new place on the clip, copied into its folder. Returns why it was refused, if it was.
    @discardableResult
    func setBackground(_ url: URL, of job: Job) -> String? {
        if let problem = Draft.imageProblem(url) {
            return "Seedance can't use \(url.lastPathComponent): it \(problem)."
        }
        do {
            let copy = try JobFiles.addCharacter(url, into: job.output, as: "background")
            job.edit { $0.background = copy }
        } catch {
            return "Seedance can't use \(url.lastPathComponent): \(error.localizedDescription)."
        }
        save(job)
        describeIfStale(job)
        return nil
    }

    /// Takes the place's image off the clip; its file stays in the folder.
    func removeBackground(of job: Job) {
        job.edit { $0.background = nil }
        save(job)
        describeIfStale(job)
    }

    /// The generator Create's render step uses for this clip. Renders made before keep the generator they had.
    func setModel(_ model: GenerationModel, of job: Job) {
        guard model != job.model else { return }
        let before = job.model
        for render in job.renders where render.model == nil { job.update(render.id) { $0.model = before } }
        job.edit { $0.model = model }
        save(job)
    }

    func setRemoveBackground(_ isOn: Bool, of job: Job) {
        job.edit { $0.removeBackground = isOn }
        save(job)
    }

    /// Stops prep, or a prep that hasn't started, and the clip's description.
    func cancel(_ job: Job) {
        cancelDescription(of: job)
        if job.stage == .waiting {
            setPrep(job, .canceled, "Canceled before prep")
            return
        }
        work.cancel(.prep(job.id))
    }

    /// Stops a render: the wait for it (which also asks the provider to cancel it; the request is kept unless the
    /// provider confirms), its download or its export. A render waiting for the person was never sent, so it is only
    /// marked canceled.
    func cancel(_ render: Render, of job: Job) {
        if job.render(render.id)?.stage == .waiting {
            set(render.id, of: job, .canceled, "Canceled before it was sent")
        } else {
            work.cancel(.render(render.id))
        }
    }

    /// Runs prep again, with other options if given: after it failed or was canceled, or on a prepared clip that
    /// isn't rendering. Renders already made stay.
    func prepareAgain(_ job: Job) {
        prepareAgain(job, target: job.spec.target, faceGuide: job.spec.faceGuide, people: job.spec.targetIDs)
    }

    /// `people` replaces those ids instead of `target`; none goes back to `target`.
    func prepareAgain(_ job: Job, target: PrepTarget, faceGuide: Bool, people: [Int]? = nil) {
        guard !job.isActive else { return }
        job.edit { spec in
            spec.target = target
            spec.faceGuide = faceGuide
            spec.targetIDs = people
        }
        job.manifest = nil
        // Now, not when the prep gets its slot: a retry while it waits behind another clip would send files it is
        // about to replace.
        job.startPrep()
        setPrep(job, .waiting, "")
        pump()
    }

    /// Waits until the job's prep, description and renders are over; for tests and the debug autopilot.
    func settle(_ job: Job) async {
        func keys() -> [JobWork.Key] {
            [.prep(job.id), .describe(job.id), .wish(job.id)] + job.renders.map { .render($0.id) }
        }
        while let task = keys().lazy.compactMap({ self.work.task($0) }).first {
            await task.value
        }
    }

    // MARK: Persistence

    private func restore() {
        let folders =
            (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "job.json")) else { continue }
            do {
                guard let record = try JobRecord.decode(data) else { continue }
                jobs.append(Job(record: record, output: folder))
            } catch {
                logger.error("Unreadable job in \(folder.lastPathComponent, privacy: .public): \(error)")
            }
        }
        jobs.sort { $0.created > $1.created }
        restoreAgentLedger()
        for job in jobs {
            for render in job.renders where [.generating, .downloading, .exporting].contains(render.stage) {
                work.run(.render(render.id)) { await self.resume(render.id, of: job) }
            }
            // A record saved by an older version may have changed on the way in.
            save(job)
        }
        pump()
    }

    func save(_ job: Job) {
        guard isListed(job) else { return }
        do {
            try persist(job)
        } catch {
            logger.error("Can't save \(job.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes `job.json`, throwing when it can't; the paid send depends on it (see `submit`). A removed clip stays
    /// removed: work that ends after it left the list never writes its record back.
    func persist(_ job: Job) throws {
        guard isListed(job) else { throw CancellationError() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: job.output, withIntermediateDirectories: true)
        try encoder.encode(job.record).write(to: job.recordURL, options: .atomic)
        if !unsaved.isEmpty { unsaved.subtract(job.renders.map(\.id)) }
    }

    func markUnsaved(_ id: UUID) { unsaved.insert(id) }

    private func isListed(_ job: Job) -> Bool { jobs.contains { $0 === job } }

    func setPrep(_ job: Job, _ stage: Job.Stage, _ detail: String) {
        job.stage = stage
        job.detail = detail
        save(job)
    }

    func set(_ id: UUID, of job: Job, _ stage: Render.Stage, _ detail: String) {
        job.update(id) {
            $0.stage = stage
            $0.detail = detail
        }
        save(job)
    }

    // MARK: Prep

    /// Starts the next prep, else the next description, when the heavy work slot is free; it runs again whenever
    /// the slot is given back.
    func pump() {
        guard !work.isBusy else { return }
        if let job = jobs.last(where: { $0.stage == .waiting }) {
            work.runHeavy(.prep(job.id)) { await self.prepare(job) }
        } else if let id = pendingDescriptions.first {
            pendingDescriptions.removeFirst()
            guard let job = job(id) else { return pump() }
            work.runHeavy(.describe(job.id)) {
                let described = await self.redescribe(job)
                // Canceled and asked for again meanwhile: the new request is waiting for its turn.
                if !self.pendingDescriptions.contains(job.id), self.describeWaits[job.id] == nil {
                    job.isDescribing = false
                }
                // Images or the prompt changed while the model read the old ones.
                if described {
                    self.describeIfStale(job)
                    self.readWishSoon(job)
                }
            }
        } else if let id = pendingWishes.first {
            pendingWishes.removeFirst()
            guard let job = job(id) else { return pump() }
            work.runHeavy(.wish(job.id)) { await self.readWish(job.spec.prompt, of: job, inSlot: true) }
        }
    }
}

// MARK: Renders

extension JobStore {
    /// Uploads the prepared clip and characters and submits a new render of it, to Seedance or to the person's own
    /// ComfyUI. This and `finalize` are the only calls that spend credits. With an agent's `origin` it goes only within the agent's limits (`send`),
    /// and otherwise waits for the person.
    /// `model` is the generator Create's picker or the agent chose; the clip's own when left out.
    @discardableResult
    func render(
        _ job: Job, quality: RenderQuality, model: GenerationModel? = nil, origin: RenderOrigin? = nil
    ) -> Render? {
        guard job.stage == .prepared, job.manifest != nil else { return nil }
        let render = Render(
            quality: quality, prompt: job.spec.prompt, origin: origin, model: model == job.model ? nil : model)
        job.renders.append(render)
        send(render.id, of: job, by: origin == nil ? .person : .agent)
        return render
    }

    /// Renders a draft's 1080p final from its Seedance task; nothing is uploaded and the motion stays the draft's.
    @discardableResult
    func finalize(_ draft: Render, of job: Job, origin: RenderOrigin? = nil) -> Render? {
        guard draft.canFinalize(), job.final(of: draft) == nil else { return nil }
        // Only Seedance finalizes, whichever generator the clip picks now.
        let render = Render(
            quality: .final1080, parent: draft.id, prompt: draft.prompt, origin: origin,
            model: job.model == .seedance25 ? nil : .seedance25)
        job.renders.append(render)
        send(render.id, of: job, by: origin == nil ? .person : .agent)
        return render
    }

    /// The next step for a stopped render: resume its request at no cost, or submit it again. An agent's retry is
    /// checked again like a new send. A render waiting for the person goes with the person's send, or with an agent's
    /// retry once it fits the agent's limits.
    func retry(_ render: Render, of job: Job, by sender: Sender) {
        guard let render = job.render(render.id), render.stage.isStopped || render.stage == .waiting,
            !work.isRunning(.render(render.id))
        else { return }
        if render.providerJobID != nil {
            work.run(.render(render.id)) { await self.resume(render.id, of: job) }
        } else if job.otherFinal(than: render) == nil {
            send(render.id, of: job, by: sender)
        }
    }

    /// The one way into a paid submit. An agent's send goes only when the estimate's upper bound fits both the
    /// render's `maxCost` and what is left of today's agent budget, counting every agent send already let through
    /// today, on its way or done; otherwise the render waits for the person with the reason. The check and the
    /// reservation happen together on the main actor, so two sends can't both take the last of the budget. The
    /// reservation is on disk before anything is sent; when the ledger can't be written, nothing is.
    private func send(_ id: UUID, of job: Job, by sender: Sender) {
        if sender == .agent {
            if let reason = agentHold(id, of: job) {
                set(id, of: job, .waiting, reason)
                return
            }
            do {
                try recordAgentSend(id, of: job)
            } catch {
                set(
                    id, of: job, .failed,
                    "Nothing was sent: the agent spend ledger couldn't be saved (\(error.localizedDescription)).")
                return
            }
        }
        set(id, of: job, .uploading, "")
        work.run(.render(id)) { await self.submit(id, of: job, reserved: sender == .agent) }
    }
}
