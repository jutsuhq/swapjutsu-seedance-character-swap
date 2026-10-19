import Foundation
import Observation

/// One example from Higgsfield's public Genjutsu gallery: the source clip, the character images it was given, its
/// prompt and the result. Picking one fills Create with the same inputs.
struct Sample: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case motion, swap }

    let id: String
    let title: String
    let kind: Kind
    let sourceVideo: URL
    let thumbnail: URL?
    let duration: Double
    /// The finished example, a small looping video for the hover preview.
    let preview: URL?
    let references: [URL]
    let prompt: String?
}

/// The tabs of the gallery, as on higgsfield.ai › Genjutsu › Motion Library.
enum SampleShelf: String, CaseIterable, Hashable, Sendable {
    case higgsfield, trending, new

    var title: String {
        switch self {
        case .higgsfield: "Higgsfield"
        case .trending: "Trending"
        case .new: "New"
        }
    }

    fileprivate var query: [URLQueryItem] {
        switch self {
        case .higgsfield: [URLQueryItem(name: "source", value: "higgsfield")]
        case .trending: [URLQueryItem(name: "source", value: "community")]
        case .new: [URLQueryItem(name: "source", value: "community"), URLQueryItem(name: "sort", value: "new")]
        }
    }
}

/// Reads the gallery the Genjutsu page shows signed out. It is an undocumented endpoint of Higgsfield's CMS, so
/// everything is optional and an item without a source clip is skipped rather than failing the page.
struct SampleCatalog: Sendable {
    var base = URL(string: "https://cms.higgsfield.ai/higgsfield-multiplier/video-explore/v2")
    var pageSize = 24

    struct Page: Sendable {
        let items: [Sample]
        let next: Int?
    }

    func page(_ shelf: SampleShelf, cursor: Int) async throws -> Page {
        guard let base else { throw URLError(.badURL) }
        let url = base.appending(
            queryItems: [
                URLQueryItem(name: "lang", value: "en"), URLQueryItem(name: "size", value: "\(pageSize)"),
                URLQueryItem(name: "cursor", value: "\(cursor)"),
            ] + shelf.query)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let wire = try JSONDecoder().decode(WirePage.self, from: data)
        let items = wire.items.compactMap(\.sample)
        let loaded = (cursor - 1) * pageSize + wire.items.count
        return Page(items: items, next: wire.items.isEmpty || loaded >= (wire.total ?? 0) ? nil : wire.cursor)
    }
}

private struct WirePage: Decodable {
    let total: Int?
    let cursor: Int?
    let items: [WireItem]
}

private struct WireMedia: Decodable {
    let url: URL?
    let thumbnailURL: URL?
    let duration: Double?
    enum CodingKeys: String, CodingKey { case url, duration, thumbnailURL = "thumbnail_url" }
}

private struct WireAsset: Decodable { let url: URL? }

private struct WireVariant: Decodable {
    let type: String
    let media: WireMedia?
    let prompt: String?
    let inputAssets: [WireAsset]?
    enum CodingKeys: String, CodingKey { case type, media, prompt, inputAssets = "input_assets" }
}

private struct WireItem: Decodable {
    let id: String
    let title: String?
    let jobSetType: String?
    let originalVideo: WireMedia?
    let variants: [WireVariant]?

    enum CodingKeys: String, CodingKey {
        case id, title, variants
        case jobSetType = "job_set_type"
        case originalVideo = "original_video"
    }

    var sample: Sample? {
        guard let source = originalVideo?.url else { return nil }
        let generation = variants?.first { $0.type == "generation" }
        let edit = variants?.first { $0.type == "edit" }
        return Sample(
            id: id, title: title ?? "Untitled", kind: jobSetType == "hf_mult_replace_object" ? .swap : .motion,
            sourceVideo: source, thumbnail: originalVideo?.thumbnailURL ?? generation?.media?.thumbnailURL,
            duration: originalVideo?.duration ?? 0, preview: generation?.media?.url ?? edit?.media?.url,
            references: generation?.inputAssets?.compactMap(\.url) ?? [],
            prompt: generation?.prompt.flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The gallery as Create shows it: one feed per tab, loaded page by page.
@MainActor
@Observable
final class SampleLibrary {
    /// Whether the person turned the examples on: until then the app makes no request to Higgsfield.
    nonisolated static let consentKey = "showsHiggsfieldExamples"
    var shelf = SampleShelf.higgsfield
    private(set) var items: [SampleShelf: [Sample]] = [:]
    private(set) var failure: String?
    private(set) var isLoading = false
    private var next: [SampleShelf: Int?] = [:]
    private let catalog: SampleCatalog

    init(catalog: SampleCatalog = SampleCatalog()) {
        self.catalog = catalog
    }

    var current: [Sample] { items[shelf] ?? [] }
    var hasMore: Bool { next[shelf] != .some(nil) }

    func loadIfNeeded() async {
        if items[shelf] == nil { await loadMore() }
    }

    func loadMore() async {
        let shelf = shelf
        guard !isLoading, hasMore else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let page = try await catalog.page(shelf, cursor: (next[shelf] ?? 1) ?? 1)
            items[shelf, default: []] += page.items.filter { new in !(items[shelf] ?? []).contains { $0.id == new.id } }
            next[shelf] = .some(page.next)
        } catch {
            failure = "Can't load examples: \(error.localizedDescription)"
        }
    }
}
