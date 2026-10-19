import Foundation

/// What agents ask of the job store: their requests, and the limits on their spending that `JobStore.send` checks
/// before every send an agent asks for.
extension JobStore {
    /// The clips an agent's `prepare` request made, in the order of its ranges.
    func jobs(forRequest requestID: String) -> [Job] {
        jobs.filter { $0.origin?.requestID == requestID }.sorted { ($0.origin?.index ?? 0) < ($1.origin?.index ?? 0) }
    }

    /// Who asked for a send: the person's own click goes as asked, an agent's is checked against its limits first.
    enum Sender { case person, agent }

    /// Why an agent may not send this render now; nil when it may.
    func agentHold(_ id: UUID, of job: Job, now: Date = Date()) -> String? {
        guard let render = job.render(id) else { return "The render is gone." }
        guard let origin = render.origin else { return "You started this render; only you can send it again." }
        guard let price = price(of: render, in: job) else { return "The clip's length, and so the price, is unknown." }
        let cost = Self.cents(price.upperBound)
        let estimate = "Estimated up to \(SeedancePrice.dollars(price.upperBound))"
        if cost > Self.cents(origin.maxCost) {
            return "\(estimate), over the \(SeedancePrice.dollars(origin.maxCost)) the agent allowed (max_cost). "
                + "Send it yourself to render it."
        }
        let budget = Self.cents(agentBudget())
        let remaining = budget - Self.cents(agentSpent(on: now))
        // A free render (Wan 2.2 Animate on the person's own ComfyUI) spends nothing, so it fits even a day already
        // over the budget.
        guard cost > max(0, remaining) else { return nil }
        if budget <= 0 {
            return "\(estimate). Agents can't spend until you set a daily agent budget in Settings › Agents. "
                + "Send it yourself to render it."
        }
        return "\(estimate), over the \(SeedancePrice.dollars(Double(max(0, remaining)) / 100)) left of today's "
            + "\(SeedancePrice.dollars(Double(budget) / 100)) agent budget (Settings › Agents). Send it yourself to "
            + "render it."
    }

    /// What agents' sends on `day` take of the budget: each send the guard let through, by its render's upper bound
    /// then; a render sent again counts again. From the ledger, so a dismissed render or a removed clip still counts.
    func agentSpent(on day: Date = Date()) -> Double {
        Double(agentLedger.cents(on: day)) / 100
    }

    /// Lets an agent's send through: the ledger keeps its amount on disk first, then the render lists it. Throws when
    /// the ledger can't be written, with nothing recorded; the send must not go.
    func recordAgentSend(_ id: UUID, of job: Job, at now: Date = Date()) throws {
        guard let render = job.render(id) else { return }
        let cents = price(of: render, in: job).map { Self.cents($0.upperBound) } ?? 0
        try agentLedger.add(AgentLedger.Send(render: id, sent: now, cents: cents))
        job.update(id) { $0.origin?.sends.append(now) }
    }

    /// Reads the ledger and adds the sends the renders list that it lacks; the first time, it starts from those
    /// sends. Either way nothing spent today is lost.
    func restoreAgentLedger() {
        var sends: [AgentLedger.Send] = []
        for job in jobs {
            for render in job.renders {
                guard let origin = render.origin, let price = price(of: render, in: job) else { continue }
                let cents = Self.cents(price.upperBound)
                sends += origin.sends.map { AgentLedger.Send(render: render.id, sent: $0, cents: cents) }
            }
        }
        if agentLedger.load() { agentLedger.reconcile(sends) } else { agentLedger.seed(sends) }
    }

    /// The estimate to the cent for a render of this clip; a final of a draft renders the clip's length at 1080p, and
    /// a Wan 2.2 Animate render is $0.
    func price(of render: Render, in job: Job) -> ClosedRange<Double>? {
        guard let seconds = job.duration, seconds > 0 else { return nil }
        return job.model(of: render).price(seconds: seconds, quality: render.quality)
    }

    /// Whole cents, so sums and comparisons don't drift by a fraction of one. Any Double converts: one past
    /// ±`Int.max / 2` (or not a number) is that bound, which still leaves room to add and subtract.
    static func cents(_ dollars: Double) -> Int {
        let cents = (dollars * 100).rounded()
        let bound = Double(Int.max / 2)
        guard cents.isFinite else { return cents < 0 ? -Int.max / 2 : Int.max / 2 }
        return cents >= bound ? Int.max / 2 : cents <= -bound ? -Int.max / 2 : Int(cents)
    }
}
