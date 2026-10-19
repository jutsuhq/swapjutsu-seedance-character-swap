import Foundation
import SwapjutsuAgent
import SwapjutsuPrep
import UniformTypeIdentifiers

/// prepare, clips, set_characters, prepare_again and correct_target: Create's free steps for an agent. The ranges go through a
/// `Draft` and its checks, the files through the inbox and `JobFiles` like a drop, and the characters through
/// `JobStore.addReferences` with the limits the person gets.
extension AgentCommands {
    func prepare(_ command: PrepareCommand) async throws(AgentError) -> AgentResponse {
        guard AgentInbox.isValidName(command.requestID) else {
            throw .invalid("requestId takes 1–64 letters, digits, '.', '_' or '-', not starting with '.'")
        }
        let parameters = Self.parameters(of: command)
        if let clips = try repeated(command.requestID, parameters) { return clips }
        let (target, people) = try Self.target(command.target)
        sweepInbox()
        let file = try adoptable(command.file, as: .movie, named: command.video)

        let draft = Draft()
        draft.setSource(file)
        await draft.settle()
        guard let duration = draft.duration, duration > 0 else {
            throw .fileRefused("\(command.video) is not a video Swapjutsu can read.")
        }
        if let ranges = command.ranges {
            let ranges = ranges.map { ClipRange(start: $0.start, end: $0.end) }
            if let problem = Draft.problem(with: ranges, duration: duration) { throw .invalid(problem) }
            draft.ranges = ranges
        } else if draft.ranges.isEmpty {
            throw .fileRefused(draft.failure ?? "\(command.video) is too short for Seedance (4–30 s).")
        }
        if let target { draft.target = target }
        if let faceGuide = command.faceGuide { draft.faceGuide = faceGuide }
        if let control = command.control { draft.control = ControlMode(control) }

        // Another call with this id may have queued its clips while the length was read.
        if let clips = try repeated(command.requestID, parameters) { return clips }
        // Whole seconds, as job.json and the wire keep it.
        let started = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let queued = draft.specs.enumerated().map { index, spec in
            var spec = spec
            spec.targetIDs = people
            return jobs.enqueue(
                spec,
                origin: JobOrigin(
                    client: command.client ?? "An agent", requestID: command.requestID, started: started, index: index,
                    parameters: parameters))
        }
        return AgentResponse(clips: queued.map(clip))
    }

    func clips(_ command: ClipsCommand) async throws(AgentError) -> AgentResponse {
        let wait = command.waitSeconds ?? 0
        guard wait.isFinite, (0...ClipsCommand.maxWait).contains(wait) else {
            throw .invalid("waitSeconds is 0–\(Int(ClipsCommand.maxWait)).")
        }
        let selected = try command.clip.map { (id) throws(AgentError) in [try job(id)] } ?? jobs.jobs
        // Polled rather than observed: the wait ends on its own, and stopping it touches nothing.
        let deadline = ContinuousClock.now + .seconds(wait)
        while selected.contains(where: \.stage.isActive), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let current = selected.filter { jobs.job($0.id) != nil }
        let renders = current.flatMap { job in job.renders.compactMap { renderInfo($0.id, of: job) } }
        return AgentResponse(clips: current.map(clip), renders: renders)
    }

    func setCharacters(_ command: SetCharactersCommand) throws(AgentError) -> AgentResponse {
        let job = try job(command.clip)
        let placed = try placements(of: command.characters ?? [], on: job)
        sweepInbox()
        // The clip keeps copies (`JobFiles.addCharacter`), so the inbox folder goes once they are made.
        defer {
            for folder in Set(placed.map { $0.file.deletingLastPathComponent() }) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        for (character, file) in placed {
            if let refusal = jobs.addReferences(
                [file], to: job, person: character.person, asView: character.view == true)
            {
                throw .fileRefused(refusal)
            }
        }
        if let removeBackground = command.removeBackground { jobs.setRemoveBackground(removeBackground, of: job) }
        if let prompt = command.prompt { jobs.setPrompt(prompt, of: job) }
        return AgentResponse(clips: [clip(job)])
    }

    /// Each image with its file, every image checked before anything changes, so a refused one leaves the clip as
    /// it was. Characters go before views, so a person's view lands after the character given with it.
    private func placements(
        of characters: [SetCharactersCommand.Character], on job: Job
    ) throws(AgentError) -> [(character: SetCharactersCommand.Character, file: URL)] {
        guard !characters.isEmpty else { return [] }
        guard let manifest = job.manifest, job.stage == .prepared else { throw .notPrepared(job) }
        let targets = manifest.targets
        var placed: [(character: SetCharactersCommand.Character, file: URL)] = []
        for character in characters {
            guard targets.contains(character.person) else {
                throw .invalid(
                    "Person \(character.person) isn't replaced in this clip; the replaced people are "
                        + "\(targets.map(String.init).joined(separator: ", ")). Use prepare_again to change who.")
            }
            guard
                character.view == true
                    || !placed.contains(where: { $0.character.person == character.person && $0.character.view != true })
            else {
                throw .invalid(
                    "Person \(character.person) is given more than one character; mark further looks of the same "
                        + "character with view.")
            }
            let file = try adoptable(character.file, as: .image, named: character.image)
            if let problem = Draft.imageProblem(file) {
                throw .fileRefused("Seedance can't use \(character.image): it \(problem).")
            }
            placed.append((character, file))
        }
        return placed.filter { $0.character.view != true } + placed.filter { $0.character.view == true }
    }

    func prepareAgain(_ command: PrepareAgainCommand) throws(AgentError) -> AgentResponse {
        let job = try job(command.clip)
        guard !job.isActive else {
            throw AgentError(
                .busy, message: "\(job.title) is \(job.isRendering ? "rendering" : "being prepared").", retryable: true,
                next: job.isRendering ? "Wait for its render." : "Wait with clips until its prep stops.")
        }
        var (target, people) = (job.spec.target, job.spec.targetIDs)
        if let given = command.target {
            let resolved = try Self.target(given)
            (target, people) = (resolved.target ?? .main, resolved.people)
        }
        if let people, let identities = job.manifest?.identities.map(\.id) {
            let unknown = people.filter { !identities.contains($0) }
            guard unknown.isEmpty else {
                throw .invalid(
                    "This clip has no person \(unknown.map(String.init).joined(separator: ", ")); prep found "
                        + "\(identities.map(String.init).joined(separator: ", ")).")
            }
        }
        if let control = command.control { job.edit { $0.control = ControlMode(control) } }
        jobs.prepareAgain(job, target: target, faceGuide: command.faceGuide ?? job.spec.faceGuide, people: people)
        return AgentResponse(clips: [clip(job)])
    }

    func correctTarget(_ command: CorrectTargetCommand) throws(AgentError) -> AgentResponse {
        let job = try job(command.clip)
        guard job.stage == .prepared, let manifest = job.manifest else { throw .notPrepared(job) }
        let fix = fixes.fix(for: job)
        guard !fix.isRetracking else {
            throw AgentError(
                .busy, message: "\(job.title) is re-tracking a shot.", retryable: true,
                next: "Wait with clips until its fix says re-tracked.")
        }
        let person = command.person ?? manifest.targets.first ?? 1
        guard manifest.targets.contains(person) else {
            throw .invalid(
                "Person \(person) isn't replaced in this clip; it replaces "
                    + "\(manifest.targets.map(String.init).joined(separator: ", ")).")
        }
        guard (0..<manifest.frames).contains(command.frame) else {
            throw .invalid("frame is 0–\(manifest.frames - 1).")
        }
        fix.select(frame: command.frame, person: person)
        switch (command.x, command.y, command.file) {
        case (let x?, let y?, nil):
            guard (0..<Double(manifest.width)).contains(x), (0..<Double(manifest.height)).contains(y) else {
                throw .invalid("x is 0–\(manifest.width - 1) and y 0–\(manifest.height - 1), pixels of control.mp4.")
            }
            fix.click(CGPoint(x: x / Double(manifest.width), y: y / Double(manifest.height)))
        case (nil, nil, let file?):
            let url = try adoptable(file, as: .image, named: command.mask ?? "the mask")
            let bytes: [UInt8]
            do { bytes = try TargetCorrections.maskBytes(url, width: manifest.width, height: manifest.height) } catch {
                throw .fileRefused("\(command.mask ?? "The mask") isn't an image Swapjutsu can read.")
            }
            guard bytes.contains(where: { $0 > 127 }) else { throw .fileRefused("The mask is empty: no white.") }
            fix.setMask(bytes)
        default:
            throw .invalid("Give either x and y (a click) or mask.")
        }
        fix.isOpen = true
        navigation.open(job.id)
        bringForward()
        Task { await fix.retrack() }
        return AgentResponse(clips: [clip(job)])
    }

    // MARK: Helpers

    /// The clips an earlier request with this id made, or nil when there were none; the same id with other
    /// parameters is refused.
    private func repeated(_ requestID: String, _ parameters: String) throws(AgentError) -> AgentResponse? {
        // A render or finalize request with this id is another request.
        if jobs.jobs.contains(where: { !$0.renders(forRequest: requestID).isEmpty }) {
            throw .requestConflict(requestID)
        }
        let earlier = jobs.jobs(forRequest: requestID)
        guard !earlier.isEmpty else { return nil }
        guard earlier.allSatisfy({ $0.origin?.parameters == parameters }) else { throw .requestConflict(requestID) }
        return AgentResponse(clips: earlier.map(clip))
    }

    /// The parameters as the agent gave them (left out stays left out), as canonical JSON.
    private static func parameters(of command: PrepareCommand) -> String {
        struct Parameters: Encodable {
            var video: String
            var ranges: [AgentRange]?
            var target: AgentTarget?
            var faceGuide: Bool?  // swiftlint:disable:this discouraged_optional_boolean
            var control: AgentControl?
        }
        let given = Parameters(
            video: command.video, ranges: command.ranges, target: command.target, faceGuide: command.faceGuide,
            control: command.control)
        return (try? AgentWire.line(given)).map { String(decoding: $0.dropLast(), as: UTF8.self) } ?? ""
    }

    /// Create's target and, for person ids, those ids; nil target: Settings › Prep.
    private static func target(_ target: AgentTarget?) throws(AgentError) -> (target: PrepTarget?, people: [Int]?) {
        switch target {
        case nil: return (nil, nil)
        case .main: return (.main, nil)
        case .all: return (.all, nil)
        case .people(let ids):
            guard !ids.isEmpty, ids.allSatisfy({ $0 >= 1 }) else {
                throw .invalid("Target person ids start at 1; give at least one.")
            }
            return (.main, Array(Set(ids)).sorted())
        }
    }

    func job(_ id: String) throws(AgentError) -> Job {
        guard let job = UUID(uuidString: id).flatMap(jobs.job) else {
            throw AgentError(
                .noSuchClip, message: "There is no clip \(id).", retryable: false,
                next: "Call clips without a clip id to list them.")
        }
        return job
    }

    /// A file the swapjutsu binary sent into the inbox (`upload`), of the right kind. The app opens nothing outside it:
    /// a sandboxed app couldn't, and the unbundled one keeps to the same rule.
    private func adoptable(_ path: String, as type: UTType, named name: String) throws(AgentError) -> URL {
        let file = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let inbox = inbox?.standardizedFileURL.resolvingSymlinksInPath(),
            file.pathComponents.count > inbox.pathComponents.count,
            file.pathComponents.starts(with: inbox.pathComponents)
        else {
            throw .invalid("Files reach Swapjutsu through the swapjutsu binary, which sends them into its inbox.")
        }
        guard FileManager.default.isReadableFile(atPath: file.path(percentEncoded: false)) else {
            throw .fileRefused("\(name) didn't arrive in Swapjutsu's inbox.")
        }
        guard UTType(filenameExtension: file.pathExtension)?.conforms(to: type) == true else {
            throw .fileRefused("\(name) is not \(type == .movie ? "a video" : "an image").")
        }
        return file
    }

    /// Removes inbox folders no clip still reads from: an upload leaves one per call, and a clip's video stays
    /// there until its prep copies it into the clip's folder. Only folders an hour old, so one an upload is still
    /// filling for a command on its way is left alone.
    /// note: runs on prepare and set_characters only, so a folder can outlive its use until the next of those.
    func sweepInbox(now: Date = Date()) {
        guard let inbox,
            let folders = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let sources = jobs.jobs.map { $0.source.standardizedFileURL.resolvingSymlinksInPath().pathComponents }
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > 3600 else { continue }
            let components = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            if sources.contains(where: { $0.starts(with: components) }) { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// What an agent reads about a clip; paths are absolute.
    func clip(_ job: Job) -> AgentClip {
        let references = job.spec.references
        let manifest = job.manifest
        let cast = job.cast
        let people = manifest.map { manifest in
            manifest.identities.map { identity in
                let binding = cast.first { $0.person == identity.id }
                let views = binding?.views.map { Self.path(references[$0]) } ?? []
                return AgentPerson(
                    id: identity.id, crop: identity.thumbnail.map { Self.path(job.output.appending(path: $0)) },
                    screenShare: (identity.screenShare * 1000).rounded() / 1000, isTarget: identity.isTarget,
                    character: binding?.character.map { Self.path(references[$0]) }, views: views.isEmpty ? nil : views)
            }
        }
        let warnings = manifest.map { $0.warnings + job.fitWarnings.sorted { $0.key < $1.key }.map(\.value) }
        let exists = { (url: URL) in
            manifest != nil && FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
        return AgentClip(
            id: job.id.uuidString, title: job.title, folder: Self.path(job.output), stage: job.stage.rawValue,
            progress: job.detail.trimmingCharacters(in: .whitespaces),
            range: job.spec.range.map { AgentRange(start: $0.start, end: $0.end) },
            target: job.spec.targetIDs.map(AgentTarget.people) ?? (job.spec.target == .all ? .all : .main),
            faceGuide: job.spec.faceGuide, controlMode: AgentControl(job.spec.control),
            removeBackground: job.spec.removeBackground, prompt: job.spec.prompt,
            characters: references.map(Self.path), missingCharacters: job.missingCharacters, people: people,
            warnings: warnings, control: exists(job.control) ? Self.path(job.control) : nil,
            review: exists(job.review) ? Self.path(job.review) : nil, renders: job.renders.count,
            origin: job.origin.map { AgentOrigin(client: $0.client, requestID: $0.requestID, started: $0.started) },
            fix: fixes.existing(for: job)?.summary)
    }

    private static func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}

extension AgentError {
    /// A request the app understood but won't carry out as given.
    static func invalid(_ message: String) -> AgentError {
        AgentError(.badRequest, message: message, retryable: false, next: "Change the request as the message says.")
    }

    static func fileRefused(_ message: String) -> AgentError {
        AgentError(.fileRefused, message: message, retryable: false, next: "Pass another file.")
    }

    @MainActor
    static func notPrepared(_ job: Job) -> AgentError {
        AgentError(
            .notPrepared, message: "\(job.title) isn't prepared (\(job.stage.rawValue)).",
            retryable: job.stage.isActive,
            next: job.stage.isActive
                ? "Wait with clips (wait_seconds) until its stage is prepared, then send this again."
                : "Prepare it again with prepare_again.")
    }
}

extension ControlMode {
    /// An agent's control as prep's; nil for colored depth, as a job keeps it.
    init?(_ agent: AgentControl) {
        guard agent != .depth, let mode = ControlMode(rawValue: agent.rawValue) else { return nil }
        self = mode
    }
}

extension AgentControl {
    init(_ mode: ControlMode?) { self = mode.flatMap { AgentControl(rawValue: $0.rawValue) } ?? .depth }
}
