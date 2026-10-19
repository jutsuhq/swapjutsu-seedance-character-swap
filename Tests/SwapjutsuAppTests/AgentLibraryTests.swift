import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// library_search and show against jobs restored from `job.json`, as after a relaunch: what Library lists, in its
/// order, and the pages `show` opens. Nothing is rendered.
@MainActor
struct AgentLibraryTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-library-\(UUID().uuidString)")
    let navigation = Navigation()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func listsFinishedRendersNewestFirstWithTheirFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let beach = try clip("Beach walk", renders: [(.draft, .done, 1), (.final1080, .done, 3), (.draft, .failed, 4)])
        let city = try clip("City night", renders: [(.draft, .done, 2)])
        let commands = load()

        let page = try #require(try commands.librarySearch(LibrarySearchCommand()).library)
        #expect(page.total == 3 && page.nextCursor == nil)
        #expect(page.results.map(\.name) == ["Final 1080p", "Draft 1", "Draft 1"])
        #expect(page.results.map(\.title) == ["Beach walk", "City night", "Beach walk"])
        let final = page.results[0]
        #expect(final.render == beach.renders[1].uuidString && final.clip == beach.id.uuidString)
        let file = beach.folder.appending(path: "result-1.mp4").resolvingSymlinksInPath()
        #expect(URL(filePath: final.file).resolvingSymlinksInPath() == file, "\(final.file)")
        #expect(final.quality == .final1080 && final.duration == 6 && final.client == nil)
        #expect(final.finished == start.addingTimeInterval(3) && final.created == start)
        #expect(page.results[1].clip == city.id.uuidString)
    }

    @Test func filtersByTextAndQualityAndPages() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try clip("Beach walk", renders: [(.draft, .done, 1), (.final720, .done, 2)], prompt: "golden hour")
        _ = try clip("City night", renders: [(.draft, .done, 3), (.draft, .done, 4)], prompt: "neon Rain")
        let commands = load()
        func search(_ command: LibrarySearchCommand) throws -> AgentLibraryPage {
            try #require(try commands.librarySearch(command).library)
        }

        #expect(try search(LibrarySearchCommand(text: "BEACH")).results.map(\.title) == ["Beach walk", "Beach walk"])
        #expect(try search(LibrarySearchCommand(text: "rain night")).total == 2, "every word, anywhere")
        #expect(try search(LibrarySearchCommand(text: "rain beach")).total == 0)
        #expect(try search(LibrarySearchCommand(text: "draft 2")).results.map(\.name) == ["Draft 2"])
        #expect(try search(LibrarySearchCommand(quality: .final720)).results.map(\.name) == ["Final 720p"])

        var seen: [String] = []
        var cursor: String?
        repeat {
            let page = try search(LibrarySearchCommand(limit: 3, cursor: cursor))
            #expect(page.total == 4)
            seen += page.results.map(\.render)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(seen == (try search(LibrarySearchCommand(limit: 50)).results.map(\.render)))
        #expect(seen.count == 4)
    }

    @Test func aLongPromptIsCut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try clip("Long", renders: [(.draft, .done, 1)], prompt: String(repeating: "a", count: 300))
        let result = try #require(try load().librarySearch(LibrarySearchCommand()).library?.results.first)
        #expect(result.promptTruncated && result.prompt.count == AgentLibraryItem.promptLength)
        #expect(result.prompt.hasSuffix("…"))
    }

    @Test func aBadLimitOrCursorIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = load()
        for command in [
            LibrarySearchCommand(limit: 0), LibrarySearchCommand(limit: 51),
            LibrarySearchCommand(cursor: UUID().uuidString),
        ] {
            #expect(throws: AgentError.self) { try commands.librarySearch(command) }
        }
    }

    @Test func showOpensAResultAClipOrAPage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let beach = try clip("Beach walk", renders: [(.draft, .done, 1), (.draft, .failed, 2)])
        var forward = 0
        let commands = load { forward += 1 }

        let result = try commands.show(.result(beach.renders[0].uuidString))
        #expect(result.shown == .library && result.renders?.first?.id == beach.renders[0].uuidString)
        #expect(navigation.screen == .library && navigation.result == beach.renders[0])

        let failed = try commands.show(.result(beach.renders[1].uuidString))
        #expect(failed.shown == .create, "only finished renders are in Library")
        #expect(navigation.screen == .create && navigation.clip == beach.id && navigation.render == beach.renders[1])

        navigation.screen = .jobs
        let clip = try commands.show(.clip(beach.id.uuidString))
        #expect(clip.shown == .create && clip.clips?.first?.id == beach.id.uuidString)
        #expect(navigation.screen == .create && navigation.clip == beach.id && navigation.render == nil)

        #expect(try commands.show(.screen(.settings)).shown == .settings && navigation.screen == .settings)
        #expect(forward == 4)
        #expect(throws: AgentError.self) { try commands.show(.result(UUID().uuidString)) }
        #expect(throws: AgentError.self) { try commands.show(.clip("nope")) }
    }
}

// MARK: Helpers

extension AgentLibraryTests {
    struct Saved {
        let id: UUID
        let folder: URL
        let renders: [UUID]
    }

    /// A prepared 6 s clip saved as `job.json`, with renders that finished `offset` seconds after `start`.
    // swiftlint:disable large_tuple
    private func clip(
        _ title: String, renders: [(RenderQuality, Render.Stage, TimeInterval)], prompt: String = ""
    ) throws -> Saved {  // swiftlint:enable large_tuple
        let id = UUID()
        let folder = root.appending(path: "\(title) \(id.uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = renders.enumerated().map { index, render in
            var saved = Render(quality: render.0, prompt: prompt, created: start)
            saved.stage = render.1
            if render.1 == .done {
                saved.result = "result-\(index).mp4"
                FileManager.default.createFile(
                    atPath: folder.appending(path: "result-\(index).mp4").path, contents: Data())
                saved.finished = start.addingTimeInterval(render.2)
            }
            return saved
        }
        let spec = JobSpec(
            title: title, source: folder.appending(path: "inputs/source.mp4"), references: [], prompt: prompt,
            target: .main, faceGuide: false, model: .seedance25, range: ClipRange(start: 2, end: 8))
        let record = JobRecord(
            id: id, created: start, spec: spec, stage: .prepared, detail: "", renders: saved, origin: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appending(path: "job.json"))
        return Saved(id: id, folder: folder, renders: saved.map(\.id))
    }

    private func load(bringForward: @escaping @MainActor () -> Void = {}) -> AgentCommands {
        let store = JobStore(
            root: root, providers: { _ in throw GenerationError.noKey },
            preparer: { _, _, _ in throw CancellationError() })
        return AgentCommands(
            credentials: Credentials(
                comfy: ComfyKeyStore(secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.agents"))),
            depth: DepthModel(load: { _ in throw CancellationError() }), navigation: navigation, jobs: store,
            inbox: nil, bringForward: bringForward)
    }
}
