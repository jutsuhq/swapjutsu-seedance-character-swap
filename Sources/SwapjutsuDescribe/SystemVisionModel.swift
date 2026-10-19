import Foundation

// Images reach the system model through `Attachment`, new in the macOS 27 SDK (Xcode 27, Swift 6.4); an older SDK
// builds the model as unavailable.
#if canImport(FoundationModels) && compiler(>=6.4)
    import FoundationModels
#endif

/// Apple's on-device system model, which takes images from macOS 27. No download: it is there when Apple
/// Intelligence is on and its model is ready, and unavailable (with the reason) otherwise.
public struct SystemVisionModel: VisionLanguageModel {
    public let name = "Apple system model"

    public init() {}

    public func availability() async -> VisionModelAvailability {
        #if canImport(FoundationModels) && compiler(>=6.4)
            guard #available(macOS 27, *) else { return .unavailable("It takes images from macOS 27.") }
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                let text: String =
                    switch reason {
                    case .deviceNotEligible: "This Mac can't run Apple Intelligence."
                    case .appleIntelligenceNotEnabled: "Apple Intelligence is off in System Settings."
                    case .modelNotReady: "Apple Intelligence's model is still downloading, or needs disk space."
                    @unknown default: "It isn't available on this Mac."
                    }
                return .unavailable(text)
            }
        #else
            return .unavailable("This build predates the macOS 27 SDK.")
        #endif
    }

    public func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String {
        #if canImport(FoundationModels) && compiler(>=6.4)
            guard #available(macOS 27, *) else { throw VisionModelError.unavailable("It takes images from macOS 27.") }
            let session = LanguageModelSession(model: .default)
            let response = try await session.respond(
                options: GenerationOptions(temperature: 0, maximumResponseTokens: maxTokens)
            ) {
                prompt
                for url in images { Attachment(imageURL: url) }
            }
            return response.content
        #else
            throw VisionModelError.unavailable("This build predates the macOS 27 SDK.")
        #endif
    }

    /// The system keeps its own model; there is nothing of ours to free.
    public func unload() async {}
}
