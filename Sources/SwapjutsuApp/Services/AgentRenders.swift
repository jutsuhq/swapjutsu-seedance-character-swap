import Foundation
import SwapjutsuAgent

/// quote, render, finalize and job_action: Create's paid steps for an agent, through the same `JobStore` calls. The
/// spending check itself is in `JobStore.send`, so it covers every send an agent asks for, retries included; here are
/// the request ids, and the same preconditions Create's buttons have.
///
/// Wan 2.2 Animate (`model: wan22Animate`) goes through the same check. Its estimate is $0, it runs on the person's own
/// ComfyUI, so it fits any `maxCost` and any budget, $0 included, and adds nothing to the day's agent spending.
extension AgentCommands {
    func quote(_ command: QuoteCommand) throws(AgentError) -> AgentResponse {
        let job = try job(command.clip)
        let model = GenerationModel(command.model)
        try Self.offers(model, command.quality)
        guard let seconds = job.duration, seconds > 0 else { throw .notPrepared(job) }
        let price = model.price(seconds: seconds, quality: RenderQuality(command.quality))
        return AgentResponse(
            quote: AgentQuote(
                clip: command.clip, quality: command.quality, seconds: seconds, low: price.lowerBound,
                high: price.upperBound, budget: budget, model: AgentModel(model)))
    }

    func render(_ command: RenderCommand) throws(AgentError) -> AgentResponse {
        try Self.check(command.requestID, maxCost: command.maxCost)
        // Seedance's requests keep the parameters they always had, so their request ids still match.
        let parameters = Self.canonical(
            RenderParameters(
                clip: command.clip, quality: command.quality, maxCost: command.maxCost,
                model: AgentModel(GenerationModel(command.model))))
        if let earlier = try repeatedRender(command.requestID, parameters) { return earlier }
        let model = GenerationModel(command.model)
        try Self.offers(model, command.quality)
        let job = try job(command.clip)
        guard job.stage == .prepared, job.manifest != nil else { throw .notPrepared(job) }
        if model == .wan22Animate {
            guard OwnComfy.offersWan else {
                throw .invalid(
                    "Wan 2.2 Animate needs the person's own ComfyUI with a passed Check; they set it up in "
                        + "Settings › Own ComfyUI.")
            }
            if let reason = JobStore.whyNotAnimatable(job) { throw .invalid(reason) }
        }
        if let limit = model.maxSeconds, let seconds = job.duration, seconds > limit + 0.01 {
            throw .invalid("\(model.title) edits clips of up to \(Int(limit)) s; this one is \(Int(seconds.rounded(.up))) s.")
        }
        let missing = job.missingCharacters
        guard missing == 0 else {
            throw .invalid(
                "\(missing) replaced \(missing == 1 ? "person has" : "people have") no character image yet; "
                    + "set_characters first.")
        }
        guard !job.missingBackground else {
            throw .invalid("The background is replaced and the clip has no image of the new place; add it in the app.")
        }
        try Self.notRendering(job)
        let origin = Self.origin(command.client, command.requestID, command.maxCost, parameters)
        guard let render = jobs.render(job, quality: RenderQuality(command.quality), model: model, origin: origin)
        else { throw .notPrepared(job) }
        return AgentResponse(renders: [renderInfo(render.id, of: job)].compactMap(\.self))
    }

    func finalize(_ command: FinalizeCommand) throws(AgentError) -> AgentResponse {
        try Self.check(command.requestID, maxCost: command.maxCost)
        let parameters = Self.canonical(FinalizeParameters(render: command.render, maxCost: command.maxCost))
        if let earlier = try repeatedRender(command.requestID, parameters) { return earlier }
        let (job, draft) = try findRender(command.render)
        if let reason = Self.whyNotFinalizable(draft, of: job) {
            throw AgentError(
                .notFinalizable, message: reason, retryable: draft.stage.isActive,
                next: draft.stage.isActive ? "Wait for the draft to finish." : "Render a final of the clip instead.")
        }
        if let final = job.final(of: draft) {
            throw AgentError(
                .notFinalizable,
                message:
                    "\(job.name(of: draft)) already has a final, \(final.id.uuidString) (\(final.stage.rawValue)).",
                retryable: false, next: "Follow that final with clips.")
        }
        try Self.notRendering(job)
        let origin = Self.origin(command.client, command.requestID, command.maxCost, parameters)
        guard let final = jobs.finalize(draft, of: job, origin: origin) else {
            throw AgentError(
                .notFinalizable, message: "\(job.name(of: draft)) can't be finalized.", retryable: false,
                next: "Render a final of the clip instead.")
        }
        return AgentResponse(renders: [renderInfo(final.id, of: job)].compactMap(\.self))
    }

    /// Cancel or retry a render, or a clip's prep. Never deletes. An agent's retry of a render that has a provider
    /// request resumes it for free; without one it is a new send, checked like one, and refused when only the person
    /// can decide: the submit may have reached Comfy (`unknown`), or the person started the render. A cancel, too,
    /// is only for renders an agent started.
    func jobAction(_ command: JobActionCommand) throws(AgentError) -> AgentResponse {
        guard let found = try? findRender(command.job) else { return try prepAction(command) }
        let (job, render) = found
        switch command.action {
        case .cancel:
            guard render.stage.isActive || render.stage == .waiting else {
                throw .invalid("\(job.name(of: render)) is \(render.stage.rawValue); there is nothing to cancel.")
            }
            if render.origin == nil { throw .needsPerson("The person started \(job.name(of: render)).") }
            jobs.cancel(render, of: job)
        case .retry:
            guard render.stage.isStopped || render.stage == .waiting else {
                throw .invalid("\(job.name(of: render)) is \(render.stage.rawValue); only a stopped render is retried.")
            }
            if render.providerJobID == nil {
                if render.stage == .unknown {
                    throw .needsPerson(
                        "The app doesn't know whether \(job.name(of: render)) reached Comfy; sending it again may pay "
                            + "twice.")
                }
                if render.origin == nil { throw .needsPerson("The person started \(job.name(of: render)).") }
                if let final = job.otherFinal(than: render) {
                    throw AgentError(
                        .notFinalizable,
                        message: "The draft already has a final, \(final.id.uuidString) (\(final.stage.rawValue)).",
                        retryable: false, next: "Follow that final with clips.")
                }
                try Self.notRendering(job)
            }
            jobs.retry(render, of: job, by: .agent)
        }
        return AgentResponse(renders: [renderInfo(render.id, of: job)].compactMap(\.self))
    }

    private func prepAction(_ command: JobActionCommand) throws(AgentError) -> AgentResponse {
        let job: Job
        do {
            job = try self.job(command.job)
        } catch {
            throw AgentError(
                .noSuchClip, message: "There is no render or clip \(command.job).", retryable: false,
                next: "Call clips to list the clips and their renders.")
        }
        switch command.action {
        case .cancel:
            guard job.stage.isActive else { throw .invalid("\(job.title) isn't being prepared.") }
            jobs.cancel(job)
        case .retry:
            guard job.stage == .failed || job.stage == .canceled else {
                throw .invalid("\(job.title) is \(job.stage.rawValue); only a failed or canceled prep is retried.")
            }
            jobs.prepareAgain(job)
        }
        return AgentResponse(clips: [clip(job)])
    }

    // MARK: Helpers

    var budget: AgentBudget { AgentBudget(daily: jobs.agentBudget(), spentToday: jobs.agentSpent()) }

    /// What an agent reads about a render.
    func renderInfo(_ id: UUID, of job: Job) -> AgentRender? {
        guard let render = job.render(id) else { return nil }
        let price = jobs.price(of: render, in: job)
        let finalizable = render.quality.isDraft && render.stage == .done && render.draftTaskID != nil
        return AgentRender(
            id: render.id.uuidString, clip: job.id.uuidString, quality: AgentQuality(render.quality),
            stage: render.stage.rawValue, detail: render.detail, low: price?.lowerBound ?? 0,
            high: price?.upperBound ?? 0, draft: render.parent?.uuidString,
            result: job.resultURL(of: render).map { $0.path(percentEncoded: false) },
            finalizableUntil: finalizable ? render.finalizableUntil : nil,
            origin: render.origin.map {
                AgentRenderOrigin(client: $0.client, requestID: $0.requestID, started: $0.started, maxCost: $0.maxCost)
            }, model: AgentModel(job.model(of: render)))
    }

    /// The render an earlier request with this id made, or nil when there was none. The same id with other parameters,
    /// or one a `prepare` already used, is refused.
    private func repeatedRender(_ requestID: String, _ parameters: String) throws(AgentError) -> AgentResponse? {
        if !jobs.jobs(forRequest: requestID).isEmpty { throw .requestConflict(requestID) }
        for job in jobs.jobs {
            guard let earlier = job.renders(forRequest: requestID).first else { continue }
            guard earlier.origin?.parameters == parameters else { throw .requestConflict(requestID) }
            return AgentResponse(renders: [renderInfo(earlier.id, of: job)].compactMap(\.self))
        }
        return nil
    }

    func findRender(_ id: String) throws(AgentError) -> (Job, Render) {
        if let id = UUID(uuidString: id) {
            for job in jobs.jobs {
                if let render = job.render(id) { return (job, render) }
            }
        }
        throw AgentError(
            .noSuchClip, message: "There is no render \(id).", retryable: false,
            next: "Call clips to list the clips and their renders.")
    }

    private static func whyNotFinalizable(_ draft: Render, of job: Job) -> String? {
        let name = job.name(of: draft)
        if !draft.quality.isDraft { return "\(name) is a final; only a draft is finalized." }
        if draft.stage != .done { return "\(name) is \(draft.stage.rawValue); only a finished draft is finalized." }
        if draft.draftTaskID == nil { return "Comfy didn't return \(name)'s task, so it can't be finalized." }
        if !draft.canFinalize() {
            return "Seedance keeps drafts for 7 days; \(name) expired on "
                + "\(draft.finalizableUntil.formatted(.iso8601))."
        }
        return nil
    }

    /// The qualities Create offers for the model.
    private static func offers(_ model: GenerationModel, _ quality: AgentQuality) throws(AgentError) {
        guard !model.qualities.contains(RenderQuality(quality)) else { return }
        let names = model.qualities.map { AgentQuality($0).rawValue }.joined(separator: ", ")
        throw .invalid("\(model.title) renders \(names), not \(quality.rawValue).")
    }

    /// One render at a time per clip, as in Create.
    private static func notRendering(_ job: Job) throws(AgentError) {
        guard job.isRendering else { return }
        throw AgentError(
            .busy, message: "\(job.title) is already rendering.", retryable: true,
            next: "Wait for its render (clips shows it), then send this again.")
    }

    private static func check(_ requestID: String, maxCost: Double) throws(AgentError) {
        guard AgentInbox.isValidName(requestID) else {
            throw .invalid("requestId takes 1–64 letters, digits, '.', '_' or '-', not starting with '.'")
        }
        guard maxCost.isFinite, (0...AgentPreferences.maxDollars).contains(maxCost) else {
            throw .invalid("maxCost is a price in USD, from 0 to \(SeedancePrice.dollars(AgentPreferences.maxDollars)).")
        }
    }

    private static func origin(
        _ client: String?, _ requestID: String, _ maxCost: Double, _ parameters: String
    )
        -> RenderOrigin
    {
        // Whole seconds, as job.json and the wire keep it.
        let started = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return RenderOrigin(
            client: client ?? "An agent", requestID: requestID, started: started, maxCost: maxCost,
            parameters: parameters)
    }

    private static func canonical(_ parameters: some Encodable) -> String {
        (try? AgentWire.line(parameters)).map { String(decoding: $0.dropLast(), as: UTF8.self) } ?? ""
    }
}

/// What makes two `render` requests the same.
private struct RenderParameters: Encodable {
    var command = "render"
    var clip: String
    var quality: AgentQuality
    var maxCost: Double
    /// Left out for Seedance.
    var model: AgentModel?
}

private struct FinalizeParameters: Encodable {
    var command = "finalize"
    var render: String
    var maxCost: Double
}

extension RenderQuality {
    init(_ quality: AgentQuality) {
        switch quality {
        case .draft: self = .draft
        case .final480: self = .final480
        case .final720: self = .final720
        case .final1080: self = .final1080
        }
    }
}

extension GenerationModel {
    /// Seedance 2.5 unless the agent asked for another generator.
    init(_ model: AgentModel?) {
        switch model {
        case nil, .seedance25: self = .seedance25
        case .wan30: self = .wan30
        case .wan22Animate: self = .wan22Animate
        }
    }
}

extension AgentModel {
    /// Nil for Seedance 2.5, the default, so Seedance's requests keep the parameters and answers they always had.
    init?(_ model: GenerationModel) {
        switch model {
        case .seedance25: return nil
        case .wan30: self = .wan30
        case .wan22Animate: self = .wan22Animate
        }
    }
}

extension AgentQuality {
    init(_ quality: RenderQuality) {
        switch quality {
        case .draft: self = .draft
        case .final480: self = .final480
        case .final720: self = .final720
        case .final1080: self = .final1080
        }
    }
}

extension AgentError {
    static func requestConflict(_ requestID: String) -> AgentError {
        AgentError(
            .requestConflict, message: "Request \(requestID) was already made with other parameters.",
            retryable: false, next: "Use a new request_id for a new request, or repeat the first one exactly.")
    }

    static func needsPerson(_ reason: String) -> AgentError {
        AgentError(
            .needsPerson, message: reason, retryable: false,
            next: "Ask the person to decide in Swapjutsu › Jobs.")
    }
}
