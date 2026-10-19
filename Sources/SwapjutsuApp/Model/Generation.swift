import ComfyKit
import Foundation

/// What a generation needs. An edit takes the prepared control video as `@Video1`, the characters as `@Image1…`
/// and the prompt, as local files each provider uploads to wherever its API reads media from. A finalize takes only
/// a draft's task: Seedance reuses the draft's inputs, prompt and motion and renders it at 1080p. An animate is Wan 2.2
/// Animate's character replacement: the prepared source, the replaced person's mask from prep and one character.
enum GenerationRequest: Sendable, Equatable {
    case edit(control: URL, images: [URL], prompt: String, quality: RenderQuality)
    case finalize(draftTaskID: String)
    case animate(source: URL, mask: URL, character: URL, prompt: String, quality: RenderQuality)
}

/// A finished render: its video, and for a draft the task the Draft to Final node renders.
struct GenerationOutput: Sendable, Equatable {
    var video: URL
    var draftTaskID: String?
}

enum GenerationStatus: Sendable, Equatable {
    case pending
    case completed(GenerationOutput)
    case failed(String)
}

/// One generation backend: Seedance 2.5, straight through Comfy's Partner Nodes API or as a workflow on Comfy Cloud,
/// or Wan 2.2 Animate on the person's own ComfyUI.
protocol GenerationProvider: Sendable {
    /// Returns the request ID. Throws `GenerationError.outcomeUnknown` when the request may have been created anyway.
    func submit(_ request: GenerationRequest) async throws -> String
    func status(of requestID: String) async throws -> GenerationStatus
    /// Asks the provider to stop the request. True only when the provider confirmed it is canceled; false when it
    /// can't cancel one, so the request runs on (and is charged) and its ID must stay.
    func cancel(_ requestID: String) async throws -> Bool
}

/// Builds the provider for a render's backend when it is sent, resumed or canceled.
typealias ProviderFactory = @MainActor (RenderBackend) throws -> any GenerationProvider

/// Where a render goes: the generator and, for Wan 2.2 Animate, the person's ComfyUI and diffusion model at the send.
/// No secret: the token stays in the Keychain.
struct RenderBackend: Codable, Equatable, Sendable {
    var model: GenerationModel
    /// Nil: the server Settings names now (renders sent before the backend was kept).
    var comfyURL: URL?
    var diffusionModel: String?

    /// The generator's backend as Settings has it now, for a new send.
    @MainActor
    static func current(_ model: GenerationModel) -> RenderBackend {
        guard model == .wan22Animate else { return RenderBackend(model: model) }
        return RenderBackend(model: model, comfyURL: OwnComfy.url, diffusionModel: OwnComfy.diffusionModel)
    }
}

enum Providers {
    /// The real backends, keyed from the Keychain. Seedance is routed by Settings › Comfy at the send (a saved
    /// request ID names its route); Wan goes to the ComfyUI its render was sent to.
    static func live(_ credentials: Credentials) -> ProviderFactory {
        { backend in
            switch backend.model {
            case .seedance25:
                guard let key = credentials.comfyKey else { throw GenerationError.noKey }
                return SeedanceRoutes(
                    route: RenderRoute.current, cloud: ComfySeedance(client: ComfyClient(apiKey: key)),
                    direct: PartnerSeedance(client: PartnerSeedanceClient(apiKey: key)))
            case .wan22Animate:
                guard let url = backend.comfyURL ?? OwnComfy.url else { throw GenerationError.noOwnComfy }
                return OwnComfyWan(
                    client: ComfyUIClient(baseURL: url, token: credentials.ownComfyToken),
                    diffusionModel: backend.diffusionModel ?? OwnComfy.diffusionModel)
            }
        }
    }
}

/// The generation models the model picker offers.
enum GenerationModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case seedance25
    /// Wan 2.2 Animate 14B (Apache-2.0) in replacement mode, on a ComfyUI the person runs.
    case wan22Animate

    var id: Self { self }

    var title: String {
        switch self {
        case .seedance25: "Seedance 2.5"
        case .wan22Animate: "Wan 2.2 Animate"
        }
    }

    var detail: String {
        switch self {
        case .seedance25: "ByteDance · edit with depth control · 4–30 s · via Comfy"
        case .wan22Animate: "Alibaba Wan · open source · runs on your ComfyUI"
        }
    }

    /// Create's generator picker.
    var pickerTitle: String {
        switch self {
        case .seedance25: "Seedance 2.5 (Comfy Cloud)"
        case .wan22Animate: "Wan 2.2 Animate (your ComfyUI, open source)"
        }
    }

    /// Runs on the person's own machine: nothing is paid, and there is no draft to finalize.
    var isLocal: Bool { self == .wan22Animate }

    /// What Create offers. Wan 2.2 Animate renders 480p or 720p (sides in multiples of 16); a 1080p window of its
    /// 14B model needs far more memory, and the 4-step LoRA was distilled at 480p.
    var qualities: [RenderQuality] {
        switch self {
        case .seedance25: [.draft, .final720, .final1080]
        case .wan22Animate: [.final480, .final720]
        }
    }

    /// The estimate to the cent: Seedance's (`SeedancePrice`), nothing for a render on the person's own machine.
    func price(seconds: Double, quality: RenderQuality) -> ClosedRange<Double> {
        isLocal ? 0...0 : SeedancePrice.cents(seconds: seconds, quality: quality)
    }

    /// "~$1.71–2.05", or "$0" for a local render.
    func priceText(seconds: Double, quality: RenderQuality) -> String {
        isLocal ? "$0" : SeedancePrice.text(seconds: seconds, quality: quality)
    }
}

enum GenerationError: LocalizedError {
    case noKey
    /// Wan 2.2 Animate was asked for without an own ComfyUI in Settings.
    case noOwnComfy
    /// The provider finished the request without a result; the reason is already readable.
    case rejected(String)
    /// The submit failed after it may have reached the provider (a dropped connection, a 5xx, an unreadable reply).
    case outcomeUnknown(String)

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your Comfy API key in Settings."
        case .noOwnComfy: "Set up your own ComfyUI in Settings › Own ComfyUI to render with Wan 2.2 Animate."
        case .rejected(let reason): "Seedance rejected the request: \(reason.prefix(300))"
        case .outcomeUnknown(let reason): "The submit's outcome is unknown: \(reason)"
        }
    }
}
