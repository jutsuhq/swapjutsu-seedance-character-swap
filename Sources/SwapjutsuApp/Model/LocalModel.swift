import Foundation
import Observation
import SwapjutsuPrep

/// Depth Anything V2 Small, which prep needs for every clip.
typealias DepthModel = LocalModel<any DepthEstimating>
/// EdgeTAM's four video models, for the mask tracking stage.
typealias TrackingModel = LocalModel<EdgeTAMModels>

extension LocalModel where Loaded == any DepthEstimating {
    /// Settings › Prep › Depth model, then `SWAPJUTSU_DEPTH_MODEL`, then the app's own copy.
    convenience init(
        load: @escaping @Sendable (URL) async throws -> any DepthEstimating = { try await DepthAnything(modelURL: $0) }
    ) {
        self.init(files: .depth, chosen: { Self.chosenDepth() }, load: load)
    }

    /// The model chosen in Settings, kept as a security-scoped bookmark so a sandboxed app can open it again after a
    /// relaunch; the URL is reachable only between `startAccessingSecurityScopedResource` and its stop. A bookmark that
    /// no longer resolves is dropped, and the app's copy is used instead.
    /// `SWAPJUTSU_DEPTH_MODEL` is a plain path: a sandboxed build reaches it only inside its container or ~/Movies.
    nonisolated static func chosenDepth(
        in defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let key = AppPaths.depthModelKey
        if let bookmark = defaults.data(forKey: key) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            {
                // A moved or renamed model resolves once more from the old bookmark; a fresh one keeps it found.
                if isStale, url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let fresh = try? depthBookmark(for: url) { defaults.set(fresh, forKey: key) }
                }
                return url
            }
            defaults.removeObject(forKey: key)
        }
        return environment["SWAPJUTSU_DEPTH_MODEL"].map { URL(filePath: $0) }
    }

    /// What Settings stores for a model picked in the open panel, while the panel's access to it lasts.
    nonisolated static func depthBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope)
    }
}

extension LocalModel where Loaded == EdgeTAMModels {
    convenience init(
        load: @escaping @Sendable (URL) async throws -> EdgeTAMModels = { try await EdgeTAMModels(folder: $0) }
    ) {
        self.init(files: .edgeTAM, load: load)
    }
}

/// A Core ML model prep runs on this Mac (`ModelFiles`). It lives in Application Support, not next to the app or the
/// checkout, so any build finds it: the first prep (or Settings › Prep › Download) puts it there once, copied from a
/// checkout's `Models/` when one is at hand, else downloaded (from Hugging Face, or a GitHub release's zip). Core ML
/// compiles it next to itself on first use (`.mlmodelc`).
///
/// The model is loaded once, in the background, at launch and right after a fetch, and that one instance serves
/// every prep: the first load of a new copy waits for Core ML to optimize it for the Neural Engine, which should
/// happen before the person presses Prepare, not after. Before the first load each launch, the copy is checked
/// against its pinned hashes, and a damaged one is fetched again.
@MainActor
@Observable
final class LocalModel<Loaded: Sendable> {
    /// Where the model is, as Settings › Prep and the Prep step show it.
    enum Phase {
        case missing, fetching, optimizing, ready
    }

    let files: ModelFiles
    /// The download on its way; one at a time, shared by prep and Settings.
    private(set) var isFetching = false
    /// The load on its way, which on a new copy includes the Neural Engine compile.
    private(set) var isOptimizing = false
    private(set) var failure: String?
    /// The check or fetch on its way, which prep and warm-up share; `isNew` after a fetch.
    private var task: Task<(url: URL, isNew: Bool), Error>?
    /// The app's copy, once checked this launch.
    private var checked: URL?
    /// The model loaded from `url`, or loading: warm-up and prep wait on the same task, so there is never a second
    /// copy in memory.
    private var loaded: (url: URL, task: Task<Loaded, Error>)?
    private let chosen: @Sendable () -> URL?
    private let load: @Sendable (URL) async throws -> Loaded

    /// `chosen` is a model picked by the person, used as it is; `load` is injected so tests run without the model.
    init(
        files: ModelFiles, chosen: @escaping @Sendable () -> URL? = { nil },
        load: @escaping @Sendable (URL) async throws -> Loaded
    ) {
        self.files = files
        self.chosen = chosen
        self.load = load
    }

    var url: URL { chosen() ?? files.standard }

    var exists: Bool {
        if let chosen = chosen() {
            // A chosen model outside the sandbox container is reachable only while its bookmark's access is on.
            let isAccessing = chosen.startAccessingSecurityScopedResource()
            defer { if isAccessing { chosen.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: chosen.path(percentEncoded: false))
        }
        return files.isComplete(files.standard)
    }

    var phase: Phase {
        if isFetching { return .fetching }
        if isOptimizing { return .optimizing }
        return exists ? .ready : .missing
    }

    /// The model, fetched first if the app's copy is missing or damaged. A chosen model is used as it is.
    func ensure(log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        if let chosen = chosen() { return chosen }
        if let checked { return checked }
        if let task { return try await task.value.url }
        failure = nil
        let files = files
        let task = Task.detached { [weak self] in
            if files.isIntact(files.standard) { return (url: files.standard, isNew: false) }
            await self?.setFetching(true)
            return (url: try await files.install(log: log), isNew: true)
        }
        self.task = task
        defer {
            self.task = nil
            isFetching = false
        }
        do {
            let (url, isNew) = try await task.value
            checked = url
            // A new copy is optimized now, not in the next prep.
            if isNew { warm() }
            return url
        } catch {
            failure = error.localizedDescription
            throw error
        }
    }

    private func setFetching(_ value: Bool) { isFetching = value }

    /// Checks and loads the model in the background when it is there, so a new copy is optimized before the first
    /// prep and a damaged one is fetched again. A missing model is left for `ensure`, which warms it once fetched.
    func warm() {
        guard exists else { return }
        Task { _ = try? await model(for: try await ensure()) }
    }

    /// The model at `url`, loaded once: a load already on its way (warm-up, or another prep) is awaited, not
    /// repeated. A failed load is forgotten, so the next prep tries again.
    func model(for url: URL) async throws -> Loaded {
        if let loaded, loaded.url == url { return try await loaded.task.value }
        let load = load
        // Utility, not background: the Neural Engine compile happens inside this load, and background work can be
        // throttled for as long as the Mac is busy; utility still yields to what the person is doing.
        let task = Task.detached(priority: .utility) {
            // A chosen model stays reachable while Core ML reads and compiles it (a no-op for the app's copy).
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            return try await load(url)
        }
        loaded = (url, task)
        isOptimizing = true
        failure = nil
        // A load replaced meanwhile (another model chosen) leaves the state to its successor.
        do {
            let model = try await task.value
            if loaded?.task == task { isOptimizing = false }
            return model
        } catch {
            if loaded?.task == task {
                loaded = nil
                isOptimizing = false
                failure = error.localizedDescription
            }
            throw error
        }
    }
}
