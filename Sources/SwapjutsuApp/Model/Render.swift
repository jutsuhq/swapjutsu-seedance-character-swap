import Foundation

/// What Seedance renders: a cheap 480p draft that can be finalized later with the same motion, or a final straight
/// from the clip. Wan 2.2 Animate renders finals only, at 480p or 720p (`GenerationModel.qualities`).
enum RenderQuality: String, CaseIterable, Codable, Sendable {
    case draft
    /// Wan 2.2 Animate's 480p; Create never offers it for Seedance, whose 480p is the draft.
    case final480
    case final720
    case final1080

    var isDraft: Bool { self == .draft }

    /// The resolution the Seedance node is asked for.
    var resolution: String {
        switch self {
        case .draft, .final480: "480p"
        case .final720: "720p"
        case .final1080: "1080p"
        }
    }

    /// The short side of the frame Seedance renders, in pixels.
    var shortSide: Int {
        switch self {
        case .draft, .final480: 480
        case .final720: 720
        case .final1080: 1080
        }
    }

    var title: String {
        switch self {
        case .draft: "Draft 480p"
        case .final480: "Final 480p"
        case .final720: "Final 720p"
        case .final1080: "Final 1080p"
        }
    }
}

/// One render of a prepared clip, by Seedance or Wan 2.2 Animate. A clip keeps every render it had, so drafts and
/// finals sit side by side in Library and a draft can be finalized days later.
struct Render: Identifiable, Codable, Sendable {
    enum Stage: String, Codable, Sendable {
        /// An agent's render over its `maxCost` or the day's agent budget: made but not sent, until the person sends
        /// it (or an agent's retry finds it within the limits). `detail` says why.
        case waiting
        /// Uploading the inputs and submitting; a quit here leaves the submit's outcome unknown.
        case uploading
        /// Comfy is rendering `providerJobID`.
        case generating
        case downloading, exporting, done, failed, canceled
        /// The submit may or may not have reached Comfy; nothing resubmits until the person decides.
        case unknown

        var isActive: Bool { [.uploading, .generating, .downloading, .exporting].contains(self) }
        /// Stopped short of a result; Jobs lists these until they are resumed or dismissed.
        var isStopped: Bool { [.failed, .canceled, .unknown].contains(self) }
    }

    /// Seedance keeps a draft renderable for 7 days after it was created.
    static let draftLifetime: TimeInterval = 7 * 24 * 3600

    let id: UUID
    let created: Date
    let quality: RenderQuality
    /// The draft this final was rendered from; `nil` for a render of the clip itself.
    let parent: UUID?
    /// The person's wishes at the time, after the service prompt.
    let prompt: String
    var stage = Stage.uploading
    /// The latest progress line, or why it stopped.
    var detail = ""
    /// The provider's request, kept from the moment it exists until it finished or failed for good.
    var providerJobID: String?
    /// A draft's Seedance task, which the Draft to Final node renders at 1080p.
    var draftTaskID: String?
    /// File names inside the job folder: the raw download, and the video with the original soundtrack.
    var generated: String?
    var result: String?
    var finished: Date?
    /// The agent that asked for it, when one did.
    var origin: RenderOrigin?
    /// The generator, when it isn't the clip's own (`JobSpec.model`); nil in renders saved before there was a choice.
    var model: GenerationModel?
    /// What went to the generator, kept at the send; nil in renders sent before it was kept, which read the clip as
    /// it is now.
    var snapshot: RenderInputSnapshot?

    init(
        quality: RenderQuality, parent: UUID? = nil, prompt: String, id: UUID = UUID(), created: Date = Date(),
        origin: RenderOrigin? = nil, model: GenerationModel? = nil
    ) {
        self.id = id
        self.created = created
        self.quality = quality
        self.parent = parent
        self.prompt = prompt
        self.origin = origin
        self.model = model
    }

    /// Whether the Draft to Final node still accepts this draft.
    func canFinalize(at date: Date = Date()) -> Bool {
        quality.isDraft && stage == .done && draftTaskID != nil
            && date < finalizableUntil
    }

    /// Whether it may leave the list: a result, or a render whose request no longer runs. One stopped with its
    /// request kept (a cancel Seedance can't do, a failed poll) may still finish and be charged, so it stays in sight
    /// until it is resumed.
    var canDismiss: Bool { stage == .done || (!stage.isActive && providerJobID == nil) }

    /// Counted from the submit, which is a little before Seedance created the task, so the app never offers a
    /// finalize Seedance would refuse.
    var finalizableUntil: Date { created.addingTimeInterval(Self.draftLifetime) }
}

/// Which agent asked for a render (`render` or `finalize`), when, with which request, and the most it let it cost. A
/// repeated request finds its render by `requestID` and must come with the same `parameters`.
struct RenderOrigin: Codable, Equatable, Sendable {
    /// The MCP client's name.
    var client: String
    var requestID: String
    var started: Date
    /// USD, checked against the estimate's upper bound before every send an agent asks for.
    var maxCost: Double
    /// The request as the agent gave it, as canonical JSON.
    var parameters: String
    /// When the agent budget let a send through. Each counts against that day's budget by the render's upper bound,
    /// from the moment it is let through, so renders on their way count too. A person's send isn't listed.
    var sends: [Date] = []

    /// "Claude Code · 17 Oct, 14:02 · up to $2.00".
    var label: String {
        "\(client) · \(started.formatted(.dateTime.day().month().hour().minute())) · up to \(SeedancePrice.dollars(maxCost))"
    }
}
