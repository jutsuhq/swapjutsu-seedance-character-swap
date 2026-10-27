import Foundation

// The paid half: quote, render, finalize and job_action. The app checks every paid send an agent asks for, retries
// included, against the render's `maxCost` and what is left of the day's agent budget (Settings › Agents), by the
// upper bound of the price estimate. A render over either limit is still made, but waits in Jobs for the person, who
// alone can send it.

/// What Seedance renders: a 480p draft (finalizable at 1080p within 7 days), or a final straight from the clip.
public enum AgentQuality: String, Codable, Sendable, CaseIterable {
    /// Seedance renders `draft`, `final720`, `final1080`; Wan 3.0 `final480`, `final720`, `final1080`; Wan 2.2
    /// Animate `final480`, `final720`.
    case draft, final480, final720, final1080
}

/// The generator a render uses: Seedance 2.5 or Wan 3.0 (paid, on Comfy), or Wan 2.2 Animate on the person's own
/// ComfyUI (free).
public enum AgentModel: String, Codable, Sendable, CaseIterable {
    case seedance25
    case wan30
    case wan22Animate
}

public struct QuoteCommand: Codable, Equatable, Sendable {
    public var clip: String
    public var quality: AgentQuality
    /// Seedance 2.5 when left out.
    public var model: AgentModel?

    public init(clip: String, quality: AgentQuality, model: AgentModel? = nil) {
        self.clip = clip
        self.quality = quality
        self.model = model
    }
}

public struct RenderCommand: Codable, Equatable, Sendable {
    public var clip: String
    public var quality: AgentQuality
    /// The same id returns the same render, across relaunches; with other parameters it is refused
    /// (`request_conflict`). The rules of `AgentInbox.isValidName`.
    public var requestID: String
    /// In USD: the most the agent lets this render cost, compared with the estimate's upper bound.
    public var maxCost: Double
    /// The MCP client that asked, shown on the render.
    public var client: String?
    /// Seedance 2.5 when left out. Wan 2.2 Animate runs on the person's own ComfyUI and costs $0, so it always fits
    /// `maxCost` and the agent budget.
    public var model: AgentModel?

    public init(
        clip: String, quality: AgentQuality, requestID: String, maxCost: Double, client: String? = nil,
        model: AgentModel? = nil
    ) {
        self.clip = clip
        self.quality = quality
        self.requestID = requestID
        self.maxCost = maxCost
        self.client = client
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case clip, quality, requestID = "requestId", maxCost, client, model
    }
}

/// A 1080p final of a finished draft, from its Seedance task: possible for 7 days after the draft was sent.
public struct FinalizeCommand: Codable, Equatable, Sendable {
    /// The draft's render id.
    public var render: String
    public var requestID: String
    public var maxCost: Double
    public var client: String?

    public init(render: String, requestID: String, maxCost: Double, client: String? = nil) {
        self.render = render
        self.requestID = requestID
        self.maxCost = maxCost
        self.client = client
    }

    private enum CodingKeys: String, CodingKey {
        case render, requestID = "requestId", maxCost, client
    }
}

public enum AgentJobAction: String, Codable, Sendable, CaseIterable {
    /// Stops a render or a clip's prep. A rendering request is canceled on the provider where it can be; a direct
    /// Seedance task can't be, so it runs on and keeps its request for a free retry.
    case cancel
    /// A stopped render: resumes its provider request at no cost when it has one, else sends it again, checked like a
    /// new one. A stopped clip: prepares it again.
    case retry
}

public struct JobActionCommand: Codable, Equatable, Sendable {
    /// A render id, or a clip id. Not `id`, which the request line already has.
    public var job: String
    public var action: AgentJobAction

    public init(job: String, action: AgentJobAction) {
        self.job = job
        self.action = action
    }
}

/// What a render of a clip would cost: an estimate, from Comfy's bill for drafts and its price badge for finals.
public struct AgentQuote: Codable, Equatable, Sendable {
    public var clip: String
    public var quality: AgentQuality
    public var seconds: Double
    /// USD, rounded down and up to the cent. `high` is what `maxCost` and the budget are checked against.
    public var low: Double
    public var high: Double
    public var currency = "USD"
    public var isEstimate = true
    public var budget: AgentBudget
    /// Set for Wan 2.2 Animate, whose quote is $0: it runs on the person's own ComfyUI.
    public var model: AgentModel?

    public init(
        clip: String, quality: AgentQuality, seconds: Double, low: Double, high: Double, budget: AgentBudget,
        model: AgentModel? = nil
    ) {
        self.clip = clip
        self.quality = quality
        self.seconds = seconds
        self.low = low
        self.high = high
        self.budget = budget
        self.model = model
    }
}

/// Settings › Agents › daily agent budget, and how much of today's is taken by agent renders sent or on their way,
/// each by the upper bound of its estimate.
public struct AgentBudget: Codable, Equatable, Sendable {
    public var daily: Double
    public var spentToday: Double
    public var remaining: Double

    public init(daily: Double, spentToday: Double) {
        self.daily = daily
        self.spentToday = spentToday
        // In whole cents, so $0.15 − $0.10 is $0.05 and not a hair under.
        remaining = max(0, (daily * 100).rounded() - (spentToday * 100).rounded()) / 100
    }
}

/// A render as an agent sees it.
public struct AgentRender: Codable, Equatable, Sendable {
    public var id: String
    public var clip: String
    public var quality: AgentQuality
    /// `waiting` (for the person, see `detail`), `uploading`, `generating`, `downloading`, `exporting`, `done`,
    /// `failed`, `canceled`, or `unknown` (the send may have reached Comfy; only the person decides what next).
    public var stage: String
    /// The latest line, or why it stopped or waits.
    public var detail: String
    /// The estimate, USD.
    public var low: Double
    public var high: Double
    /// For a final of a draft: the draft's render id.
    public var draft: String?
    /// The finished video, with the clip's own soundtrack.
    public var result: String?
    /// A finished draft: until when finalize takes it.
    public var finalizableUntil: Date?
    public var origin: AgentRenderOrigin?
    /// Set for a Wan 2.2 Animate render; Seedance's leave it out.
    public var model: AgentModel?
    /// A finished render: how to check it.
    public var next: String?

    public init(
        id: String, clip: String, quality: AgentQuality, stage: String, detail: String, low: Double, high: Double,
        draft: String?, result: String?, finalizableUntil: Date?, origin: AgentRenderOrigin?, model: AgentModel? = nil,
        next: String? = nil
    ) {
        self.model = model
        self.next = next
        self.id = id
        self.clip = clip
        self.quality = quality
        self.stage = stage
        self.detail = detail
        self.low = low
        self.high = high
        self.draft = draft
        self.result = result
        self.finalizableUntil = finalizableUntil
        self.origin = origin
    }
}

/// Which agent asked for a render, when, with which request, and the most it allowed it to cost.
public struct AgentRenderOrigin: Codable, Equatable, Sendable {
    public var client: String
    public var requestID: String
    public var started: Date
    public var maxCost: Double

    public init(client: String, requestID: String, started: Date, maxCost: Double) {
        self.client = client
        self.requestID = requestID
        self.started = started
        self.maxCost = maxCost
    }

    private enum CodingKeys: String, CodingKey {
        case client, requestID = "requestId", started, maxCost
    }
}

extension AgentError.Code {
    /// Only the person can do this: send a render whose submit may have reached Comfy, or send again one they started.
    public static let needsPerson = Self(rawValue: "needs_person")
    /// The draft can't be finalized: not a finished draft, no Seedance task, past its 7 days, or already finalized.
    public static let notFinalizable = Self(rawValue: "not_finalizable")
}
