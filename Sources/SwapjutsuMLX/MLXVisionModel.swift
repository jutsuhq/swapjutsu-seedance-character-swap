// Built with the MLX trait (Package.swift); without it this library is empty.
#if MLX
import Foundation
import HuggingFace
import MLX
import MLXLMCommon
import MLXVLM
import SwapjutsuDescribe
import Tokenizers

/// Local vision-language models on MLX (mlx-swift-lm's MLXVLM), downloaded from Hugging Face into a folder of the
/// app's: the folder is the download's own Hugging Face cache (blobs and a snapshot of links), so nothing lands in
/// a shared cache and deleting the folder frees the disk. Loaded on the first answer and unloaded before prep.
public struct MLXVisionBackend: LocalVisionBackend {
    /// The weights, the tokenizer and the configs; not the repository's README or extra formats.
    /// `scripts/pin-vision-models.py` pins the files these match; keep the two in step.
    static let patterns = ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model", "*.tiktoken"]
    /// The argument that makes an executable a `WorkerVisionModel`'s child: `--vision-worker <folder> <name>`.
    public static let workerFlag = "--vision-worker"

    /// The executable that runs the models in a child process (`serveIfWorker`), nil to run them in this one.
    let worker: URL?

    /// The app passes its own executable, so an MLX error ends a child instead of the app; the command-line tools
    /// run the model in their own process.
    public init(worker: URL? = nil) { self.worker = worker }

    /// When this process was started as a worker, serves the model it names and returns true.
    public static func serveIfWorker(_ arguments: [String] = CommandLine.arguments) async -> Bool {
        guard arguments.count >= 4, arguments[1] == workerFlag else { return false }
        await VisionWorker.serve(MLXVisionModel(folder: URL(filePath: arguments[2]), name: arguments[3]))
        return true
    }

    public func download(
        repo: String, revision: String, into folder: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let id = Repo.ID(rawValue: repo) else { throw VisionModelError.failed("\(repo) is not a repository.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // note: swift-huggingface 1.0.0 fails a cache-less download into a folder after fetching it, so the folder is
        // the cache; the snapshot inside it is the model (`snapshot(in:)`).
        return try await HubClient(cache: HubCache(cacheDirectory: folder)).downloadSnapshot(
            of: id, revision: revision, matching: Self.patterns, progressHandler: { value in progress(value.fractionCompleted) })
    }

    public func model(in folder: URL, name: String) -> any VisionLanguageModel {
        guard let worker else { return MLXVisionModel(folder: folder, name: name) }
        return WorkerVisionModel(
            name: name, executable: worker, arguments: [Self.workerFlag, folder.path(percentEncoded: false), name],
            isAvailable: { Self.snapshot(in: folder) != nil })
    }

    /// The model's files in a download folder: the folder itself when it holds config.json, else the snapshot in
    /// its cache layout (`models--<owner>--<name>/snapshots/<commit>`).
    static func snapshot(in folder: URL) -> URL? {
        let files = FileManager.default
        func hasConfig(_ url: URL) -> Bool { files.fileExists(atPath: url.appending(path: "config.json").path(percentEncoded: false)) }
        if hasConfig(folder) { return folder }
        let repos = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for repo in repos where repo.lastPathComponent.hasPrefix("models--") {
            let snapshots = (try? files.contentsOfDirectory(at: repo.appending(path: "snapshots"), includingPropertiesForKeys: nil)) ?? []
            if let snapshot = snapshots.first(where: hasConfig) { return snapshot }
        }
        return nil
    }
}

/// One MLX model. The container stays loaded between the calls of one description and goes on `unload`, with
/// MLX's buffer cache, so prep gets the memory back.
public struct MLXVisionModel: VisionLanguageModel {
    let folder: URL
    public let name: String
    private let holder = Holder()

    public init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
    }

    public func availability() async -> VisionModelAvailability {
        MLXVisionBackend.snapshot(in: folder) == nil ? .unavailable("\(name) isn't downloaded.") : .available
    }

    public func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String {
        let container = try await holder.container(folder)
        let session = ChatSession(
            container, generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            processing: .init(resize: CGSize(width: 768, height: 768)),
            // Qwen3.5's template thinks aloud unless told not to; the others ignore it.
            additionalContext: ["enable_thinking": false])
        return try await session.respond(to: prompt, images: images.map { .url($0) }, videos: [], audios: [])
    }

    public func unload() async {
        await holder.drop()
        Memory.clearCache()
    }

    actor Holder {
        private var loaded: ModelContainer?

        func container(_ folder: URL) async throws -> ModelContainer {
            if let loaded { return loaded }
            guard let files = MLXVisionBackend.snapshot(in: folder) else {
                throw VisionModelError.unavailable("The model isn't downloaded.")
            }
            let container = try await VLMModelFactory.shared.loadContainer(from: files, using: TransformersLoader())
            loaded = container
            return container
        }

        func drop() { loaded = nil }
    }
}

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol, as its MLXHuggingFace macro writes it.
struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }

    struct Bridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer

        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }

        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }

        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(
                    messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
}
#endif
