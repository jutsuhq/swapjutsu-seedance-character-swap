import Foundation
import Observation
import SwapjutsuDescribe

/// A local vision-language model Settings offers, on MLX from Hugging Face, pinned to one commit (`pins`).
struct VisionModelOption: Identifiable, Hashable, Sendable {
    /// A Hugging Face commit and the size and SHA-256 of every file downloaded from it.
    struct Pin: Sendable {
        let revision: String
        let files: [ModelFiles.File]
    }

    /// The Hugging Face repository.
    let id: String
    let title: String
    let gigabytes: Double
    /// The Mac's RAM it needs: the 4-bit weights, the images and prep's models afterwards.
    let memory: Int
    let note: String

    /// Measured in a bake-off of local models: Qwen3-VL 8B describes best on 16 GB. A clip is about three calls
    /// (each character, the place, the moves), so its time is three of the bake-off's calls: 25 s each for Qwen3-VL 8B.
    static let all = [
        VisionModelOption(
            id: "mlx-community/Qwen3-VL-8B-Instruct-4bit", title: "Qwen3-VL 8B", gigabytes: 5.8, memory: 16,
            note: "Recommended: the most accurate on 16 GB, about 75 s a clip"),
        VisionModelOption(
            id: "mlx-community/gemma-4-e4b-it-4bit", title: "Gemma 4 E4B", gigabytes: 5.2, memory: 16,
            note: "About 35 s a clip, less exact on clothes and colours"),
        VisionModelOption(
            id: "mlx-community/Qwen3.5-9B-4bit", title: "Qwen3.5 9B", gigabytes: 6.0, memory: 16,
            note: "As good on places and clothes, weaker on moves, about 90 s a clip"),
        VisionModelOption(
            id: "mlx-community/Qwen3.8-27B-4bit", title: "Qwen3.8 27B", gigabytes: 16.1, memory: 32,
            note: "Larger and slower, for Macs with 32 GB or more"),
        VisionModelOption(
            id: "mlx-community/Qwen3.5-35B-A3B-4bit", title: "Qwen3.5 35B-A3B", gigabytes: 20.4, memory: 32,
            note: "Mixture of experts, for Macs with 32 GB or more"),
    ]

    static let standard = all[0]

    /// Every option has one: `scripts/pin-vision-models.py` writes them from `all`.
    var pin: Pin { Self.pins[id]! }

    /// The options this Mac's RAM can run: the large tiers only from 32 GB.
    static func offered(memory bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [VisionModelOption] {
        let gigabytes = Int((Double(bytes) / 1_073_741_824).rounded())
        return all.filter { $0.memory <= gigabytes }
    }
}

/// Who writes the description part of the prompt.
enum DescriberChoice: String, CaseIterable, Sendable {
    /// A downloaded local model, then Apple's system model.
    case local
    /// Apple's system model only.
    case system
    /// An OpenAI-compatible API, then Apple's system model.
    case api
    /// Nobody: the prompt has only the person's wishes.
    case off

    var title: String {
        switch self {
        case .local: "Local model"
        case .system: "Apple"
        case .api: "API"
        case .off: "Off"
        }
    }
}

/// The local models on this Mac and the choice of who describes: what Settings › Prep › Prompt writer shows, and
/// the `Describer` prep runs first. The MLX implementation comes from the app's executable (`backend`); without it
/// (tests, a build without MLX) only Apple's model and the API are offered.
@MainActor
@Observable
final class VisionModels {
    nonisolated static let choiceKey = "describer"
    nonisolated static let modelKey = "describerModel"
    nonisolated static let apiBaseKey = "describerAPIBase"
    nonisolated static let apiModelKey = "describerAPIModel"

    /// Set once by the executable before the app starts.
    nonisolated(unsafe) static var liveBackend: (any LocalVisionBackend)?

    let backend: (any LocalVisionBackend)?
    let folder: URL
    let defaults: UserDefaults
    let apiKey: KeychainSecret
    /// The first downloaded file that differs from its pin, nil when all match; tests pass a stand-in.
    let verify: @Sendable ([ModelFiles.File], URL) -> String?
    /// Downloads on their way: the share done.
    private(set) var progress: [String: Double] = [:]
    private(set) var failure: String?
    /// Bumped when a model folder appears or goes, so views reading `isDownloaded` follow.
    private(set) var revision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    init(
        backend: (any LocalVisionBackend)? = VisionModels.liveBackend,
        folder: URL = ModelFiles.folder.appending(path: "VLM"), defaults: UserDefaults = .standard,
        apiKey: KeychainSecret = KeychainSecret(service: "com.jutsustudio.swapjutsu.describer"),
        verify: @escaping @Sendable ([ModelFiles.File], URL) -> String? = ModelFiles.firstMismatch
    ) {
        (self.backend, self.folder, self.defaults, self.apiKey) = (backend, folder, defaults, apiKey)
        self.verify = verify
    }

    var choice: DescriberChoice {
        get {
            _ = revision
            let saved = defaults.string(forKey: Self.choiceKey).flatMap(DescriberChoice.init)
            return saved ?? (backend == nil ? .system : .local)
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.choiceKey)
            revision += 1
        }
    }

    var chosen: VisionModelOption {
        get {
            _ = revision
            let id = defaults.string(forKey: Self.modelKey)
            return VisionModelOption.all.first { $0.id == id } ?? .standard
        }
        set {
            defaults.set(newValue.id, forKey: Self.modelKey)
            revision += 1
        }
    }

    /// "owner--name" under `folder`: one folder per model, deleted whole.
    func folder(of option: VisionModelOption) -> URL {
        folder.appending(path: option.id.replacingOccurrences(of: "/", with: "--"))
    }

    /// The pinned commit downloaded and checked: `download` writes a marker naming the folder of its files, inside
    /// `folder(of:)` and ending in the commit, once every file matched its pin. A download of another commit, an
    /// older pin's, doesn't count.
    func isDownloaded(_ option: VisionModelOption) -> Bool {
        _ = revision
        return files(of: option)?.lastPathComponent == option.pin.revision
    }

    private func marker(_ option: VisionModelOption) -> URL { folder(of: option).appending(path: ".complete") }

    /// The folder of the model's files, as the marker names it.
    private func files(of option: VisionModelOption) -> URL? {
        guard let data = try? Data(contentsOf: marker(option)), !data.isEmpty else { return nil }
        return folder(of: option).appending(path: String(decoding: data, as: UTF8.self))
    }

    func download(_ option: VisionModelOption) {
        guard let backend, tasks[option.id] == nil else { return }
        failure = nil
        progress[option.id] = 0
        let destination = folder(of: option), marker = marker(option), pin = option.pin, verify = verify
        tasks[option.id] = Task {
            do {
                let files = try await backend.download(repo: option.id, revision: pin.revision, into: destination) {
                    share in
                    Task { @MainActor in if self.progress[option.id] != nil { self.progress[option.id] = share } }
                }
                try Task.checkCancellation()
                // Hashing 5–20 GB takes seconds: off the main actor.
                if let damaged = await Task.detached(operation: { verify(pin.files, files) }).value {
                    try? FileManager.default.removeItem(at: destination)
                    throw VisionModelError.failed("\(damaged) doesn't match its pinned SHA-256, so it was discarded.")
                }
                let base = destination.resolvingSymlinksInPath().path(percentEncoded: false)
                let inside = files.resolvingSymlinksInPath().path(percentEncoded: false)
                guard inside.hasPrefix(base) else { throw VisionModelError.failed("\(inside) is outside \(base).") }
                try Data(inside.dropFirst(base.count).split(separator: "/").joined(separator: "/").utf8).write(to: marker)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
            } catch {
                failure = "Couldn't download \(option.title): \(error.localizedDescription)"
            }
            progress[option.id] = nil
            tasks[option.id] = nil
            revision += 1
        }
    }

    func cancelDownload(_ option: VisionModelOption) {
        guard let task = tasks[option.id] else { return }
        task.cancel()
    }

    func delete(_ option: VisionModelOption) {
        cancelDownload(option)
        try? FileManager.default.removeItem(at: folder(of: option))
        revision += 1
    }

    var apiBase: String {
        get {
            _ = revision
            return defaults.string(forKey: Self.apiBaseKey) ?? "http://localhost:1234/v1"
        }
        set {
            defaults.set(newValue, forKey: Self.apiBaseKey)
            revision += 1
        }
    }

    var apiModel: String {
        get {
            _ = revision
            return defaults.string(forKey: Self.apiModelKey) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Self.apiModelKey)
            revision += 1
        }
    }

    /// The models to ask, in order: the choice, then Apple's system model, then nobody (the wishes alone).
    func models() -> [any VisionLanguageModel] {
        let system = SystemVisionModel()
        switch choice {
        case .off: return []
        case .system: return [system]
        case .local:
            guard let backend, isDownloaded(chosen), let files = files(of: chosen) else { return [system] }
            return [backend.model(in: files, name: chosen.title), system]
        case .api:
            guard let base = URL(string: apiBase), !apiModel.isEmpty else { return [system] }
            return [OpenAICompatibleVisionModel(base: base, model: apiModel, key: apiKey.read()), system]
        }
    }
}
