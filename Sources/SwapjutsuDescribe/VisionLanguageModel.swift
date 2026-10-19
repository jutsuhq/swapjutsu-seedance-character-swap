import Foundation

/// A model that answers a text prompt about images: a local MLX model, Apple's system model, or a model behind an
/// API. `Describer` is the only caller; it knows the prompts and reads the answers, so a provider only moves text
/// and images, and any model that does that can be plugged in.
public protocol VisionLanguageModel: Sendable {
    /// As the description's source and Settings name it: "Qwen3-VL 8B", "Apple system model".
    var name: String { get }
    /// Whether it can answer now; the reason is shown when it can't.
    func availability() async -> VisionModelAvailability
    /// The model's answer to `prompt` about `images`, in their order.
    func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String
    /// Frees what the model holds in memory. Prep's depth and tracking models need the RAM a local model takes, so
    /// `Describer` calls this before prep runs.
    func unload() async
}

public enum VisionModelAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

public enum VisionModelError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .failed(let reason): reason
        }
    }
}

/// A local model's files on disk: what Settings downloads, deletes and turns into a `VisionLanguageModel`. The app
/// gets one from its executable (`Sources/Swapjutsu`), which links the MLX implementation; the app itself and its
/// tests never build MLX.
public protocol LocalVisionBackend: Sendable {
    /// Downloads commit `revision` of the Hugging Face repository `repo` into `folder`, reporting the share done
    /// (0–1), and returns the folder inside it that holds the model's files.
    func download(
        repo: String, revision: String, into folder: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    /// The model in `folder`, loaded on its first answer.
    func model(in folder: URL, name: String) -> any VisionLanguageModel
}
