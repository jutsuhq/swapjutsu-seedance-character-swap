import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// The job lifecycle around a paid request: nothing is submitted twice, every step survives a relaunch, and every
/// job gets its own folder. Prep and the provider are stand-ins; the video files are real, a few frames long.
@MainActor
@Suite(.serialized)
struct JobStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-jobs-\(UUID().uuidString)")

    @Test func aFailedPollResumesTheSameRequest() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.failure(URLError(.networkConnectionLost)), .success(try await output())])
        let store = makeStore(provider)
        let job = try await prepared(store)

        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .failed && job.render(render.id)?.providerJobID == "r1")

        store.retry(try #require(job.render(render.id)), of: job, by: .person)
        await store.settle(job)
        let done = try #require(job.render(render.id))
        #expect(done.stage == .done, "\(done.detail)")
        #expect(provider.submits == 1)
        #expect(job.resultURL(of: done).map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(done.generated == "seedance-r1.mp4")
    }

    @Test func aRelaunchResumesARenderWithoutSubmitting() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = makeStore(FakeProvider(statuses: []), poll: .seconds(3600))
        let job = try await prepared(first)
        let render = try #require(first.render(job, quality: .final720))
        while job.render(render.id)?.stage != .generating { await Task.yield() }

        let provider = FakeProvider(statuses: [.success(try await output())])
        let second = makeStore(provider)
        let restored = try #require(second.jobs.first { $0.id == job.id })
        await second.settle(restored)
        #expect(restored.render(render.id)?.stage == .done, "\(restored.render(render.id)?.detail ?? "")")
        #expect(restored.render(render.id)?.quality == .final720)
        #expect(provider.submits == 0)
        #expect(restored.manifest != nil)
        first.cancel(render, of: job)
        await first.settle(job)
    }

    /// The smoke-test launch: a render in flight is neither loaded nor resumed, and its record stays as it is.
    @Test func aSmokeLaunchResumesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = makeStore(FakeProvider(statuses: []), poll: .seconds(3600))
        let job = try await prepared(first)
        let render = try #require(first.render(job, quality: .final720))
        while job.render(render.id)?.stage != .generating { await Task.yield() }
        let record = try Data(contentsOf: job.recordURL)

        let smoke = JobStore(
            root: root,
            providers: { _ in
                Issue.record("a smoke launch asked for a provider")
                return FakeProvider(statuses: [])
            },
            preparer: { _, _, _ in
                Issue.record("a smoke launch started prep")
                throw CancellationError()
            }, restoresJobs: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(smoke.jobs.isEmpty && smoke.activeCount == 0)
        #expect(try Data(contentsOf: job.recordURL) == record, "job.json is left as it was")
        first.cancel(render, of: job)
        await first.settle(job)
    }

    @Test func aDraftIsFinalizedFromItsTaskAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output(task: "cgt-1")), .success(try await output())])
        let store = makeStore(provider)
        let job = try await prepared(store)
        let draft = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        let done = try #require(job.render(draft.id))
        #expect(done.draftTaskID == "cgt-1" && done.canFinalize())

        let final = try #require(store.finalize(done, of: job))
        #expect(store.finalize(done, of: job) == nil, "one final per draft")
        await store.settle(job)
        #expect(job.render(final.id)?.stage == .done && job.render(final.id)?.parent == draft.id)
        #expect(provider.requests.last == .finalize(draftTaskID: "cgt-1"))
        #expect(job.finished.map { job.name(of: $0) } == ["Draft 1", "Final 1080p"])
        #expect(job.resultURL(of: done) != job.render(final.id).flatMap(job.resultURL), "each keeps its file")
    }

    @Test func aDraftOlderThanAWeekCantBeFinalized() {
        var draft = Render(quality: .draft, prompt: "", created: Date().addingTimeInterval(-8 * 24 * 3600))
        draft.stage = .done
        draft.draftTaskID = "cgt-1"
        #expect(!draft.canFinalize())
        #expect(draft.canFinalize(at: draft.created.addingTimeInterval(3600)))
    }

    @Test func anUnknownSubmitIsNotRetriedByItself() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [], submitError: GenerationError.outcomeUnknown("Gateway timeout."))
        let store = makeStore(provider)
        let job = try await prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .unknown && job.render(render.id)?.providerJobID == nil)
        #expect(provider.submits == 1)
        let relaunched = makeStore(provider)
        #expect(relaunched.jobs.first?.renders.first?.stage == .unknown)
        #expect(provider.submits == 1)
    }

    @Test func cancelingARenderCancelsItOnTheProvider() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let store = makeStore(provider, poll: .seconds(3600))
        let job = try await prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        while job.render(render.id)?.stage != .generating { await Task.yield() }
        store.cancel(render, of: job)
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .canceled && job.render(render.id)?.providerJobID == nil)
        #expect(provider.canceled == ["r1"])
    }

    @Test func tooFewImagesForTheTargetsStopBeforeUploading() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let store = makeStore(provider, targets: [1, 2])
        let job = try await prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .failed && job.render(render.id)?.detail.contains("2 people") == true)
        #expect(provider.submits == 0)
    }

    @Test func aVersion1JobComesBackAsAClipWithItsRender() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spec = try JSONEncoder().encode(try await spec())
        let record = """
            {"version": 1, "id": "\(UUID().uuidString)", "created": "2026-10-10T10:00:00Z",
             "spec": \(String(decoding: spec, as: UTF8.self)), "stage": "done", "detail": "final.mp4",
             "providerJobID": "r9", "generated": "seedance-r9.mp4", "result": "final.mp4"}
            """
        try Data(record.utf8).write(to: folder.appending(path: "job.json"))
        let store = makeStore(FakeProvider(statuses: []))
        let job = try #require(store.jobs.first)
        #expect(job.stage == .prepared)
        #expect(job.renders.count == 1 && job.renders[0].stage == .done && job.renders[0].result == "final.mp4")
        #expect(job.renders[0].quality == .draft && job.renders[0].providerJobID == "r9")
        let saved = try JobRecord.decode(Data(contentsOf: folder.appending(path: "job.json")))
        #expect(saved?.version == 2)
    }

    @Test func aRangeIsCutWhenTheJobAdoptsItsInputs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(FakeProvider(statuses: []))
        var ranged = try await spec()
        ranged.range = ClipRange(start: 0.1, end: 0.4)
        let job = store.enqueue(ranged)
        await store.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        #expect(job.source.lastPathComponent == "source.mov")
        let seconds = try await AVURLAsset(url: job.source).load(.duration).seconds
        #expect(abs(seconds - 0.3) < 0.05, "\(seconds)")
    }

    /// Prepare Again reads the copy the clip already has; it must not cut or copy that file onto itself. The root is
    /// made from a path, as `SWAPJUTSU_JOBS` is: such a URL once compared unequal to the same folder.
    @Test func aRangedClipIsPreparedAgainFromItsOwnCopy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(
            root: URL(filePath: root.path), providers: { _ in FakeProvider(statuses: []) },
            preparer: Self.preparer(targets: [1]))
        var ranged = try await spec()
        ranged.range = ClipRange(start: 0.1, end: 0.4)
        let job = store.enqueue(ranged)
        await store.settle(job)
        let source = job.source
        store.prepareAgain(job, target: .all, faceGuide: false)
        await store.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        #expect(job.source == source && FileManager.default.fileExists(atPath: source.path))
        let seconds = try await AVURLAsset(url: job.source).load(.duration).seconds
        #expect(abs(seconds - 0.3) < 0.05, "\(seconds)")
    }

    @Test func theJobOwnsCopiesOfItsInputs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(FakeProvider(statuses: []))
        let original = try await spec()
        let job = store.enqueue(original)
        await store.settle(job)
        #expect(job.source.path.hasPrefix(job.output.path) && job.source != original.source)
        let reference = try #require(job.spec.references.first)
        #expect(reference.path.hasPrefix(job.output.path) && reference != original.references[0])
        #expect(reference.lastPathComponent == "character-1.png")
        let image = try Data(contentsOf: original.references[0])
        try FileManager.default.removeItem(at: original.source)
        try FileManager.default.removeItem(at: original.references[0])
        #expect(FileManager.default.fileExists(atPath: job.source.path))
        #expect(try Data(contentsOf: reference) == image)
    }

    @Test func jobsSavedBeforeBackgroundRemovalStillOpen() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(try await spec())) as? [String: Any])
        json["removeBackground"] = nil
        json["replaceBackground"] = nil
        json["background"] = nil
        let spec = try JSONDecoder().decode(JobSpec.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!spec.removeBackground && !spec.replaceBackground && spec.background == nil)
        #expect(spec.options.background == .keep)
    }

}

// MARK: Helpers

extension JobStoreTests {
    func prepared(_ store: JobStore) async throws -> Job {
        let job = store.enqueue(try await spec())
        await store.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        return job
    }

    /// A finished render: the test clip, and a draft's task when there is one.
    func output(task: String? = nil) async throws -> GenerationOutput {
        GenerationOutput(video: try await clip(), draftTaskID: task)
    }

    func makeStore(
        _ provider: FakeProvider, poll: Duration = .zero, targets: [Int] = [1], background: BackgroundMode? = nil
    ) -> JobStore {
        JobStore(
            root: root, providers: { _ in provider }, preparer: Self.preparer(targets: targets, background: background),
            pollInterval: poll,
            maxPolls: 5, saveRetryInterval: .milliseconds(5))
    }

    func spec() async throws -> JobSpec {
        let inputs = root.appending(path: "originals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let video = inputs.appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: try await clip(), to: video)
        let image = inputs.appending(path: "hero.png")
        try Data(base64Encoded: Self.onePixelPNG)?.write(to: image)
        return JobSpec(
            title: "same", source: video, references: [image], prompt: "", target: .main, faceGuide: false,
            model: .seedance25)
    }

    /// A 0.5 s silent H.264 clip, written once per test run.
    func clip() async throws -> URL { try await Self.clipFile.value }

    /// One shared write, so tests running at once neither block a thread on it nor write the file twice.
    private static let clipFile = Task {
        let url = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-clip.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try VideoWriter(url: url, size: CGSize(width: 64, height: 64), fps: 24, context: CIContext())
        for _ in 0..<12 {
            try writer.append(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        }
        try await writer.finish()
        return url
    }

    static func preparer(targets: [Int], background: BackgroundMode? = nil) -> Preparer {
        { _, output, _ in
            let mode = background.map { #", "background": "\#($0.rawValue)""# } ?? ""
            let json = """
                {"source": "clip.mp4", "width": 64, "height": 64, "fps": 24, "frames": 12, "shots": [],
                 "timeline": [], "identities": [], "targets": \(targets), "warnings": [],
                 "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                             "mergeDistance": 0.33},
                 "seedance": {"video": "control.mp4", "prompt": "Replace the person.", "durationSeconds": 0.5},
                 "timings": {}\(mode)}
                """
            try Data(json.utf8).write(to: output.appending(path: "manifest.json"))
            return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        }
    }

    static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
}

// MARK: Characters and options on the clip

extension JobStoreTests {
    @Test func charactersAddedDuringPrepStayOnTheClip() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(FakeProvider(statuses: []))
        var bare = try await spec()
        bare.references = []
        let job = store.enqueue(bare)
        #expect(store.addReferences([try picture()], to: job) == nil)
        await store.settle(job)
        #expect(job.stage == .prepared && job.spec.references.count == 1)
        #expect(job.spec.references[0].path.hasPrefix(job.output.appending(path: "inputs").path))
        #expect(job.missingCharacters == 0)
        #expect(store.addReferences([job.output.appending(path: "control.mp4")], to: job) != nil)
    }

    @Test func aCharacterReplacesTheOneOfItsPerson() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(FakeProvider(statuses: []), targets: [1, 2])
        let job = try await prepared(store)
        #expect(job.missingCharacters == 1)
        let first = job.spec.references[0]
        store.addReferences([try picture()], to: job, person: 1)
        #expect(job.spec.references.count == 1 && job.spec.references[0] != first)
        store.addReferences([try picture()], to: job, person: 2)
        #expect(job.spec.references.count == 2 && job.missingCharacters == 0)
        let second = job.spec.references[1]
        store.removeReference(at: 0, of: job)
        #expect(job.spec.references == [second])
        #expect(job.cast.map(\.images) == [[], [0]], "person 2 keeps their image")
    }

    @Test func aPreparedClipIsPreparedAgainWithOtherOptions() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let store = makeStore(provider)
        let job = try await prepared(store)
        store.render(job, quality: .draft)
        await store.settle(job)
        store.prepareAgain(job, target: .all, faceGuide: true)
        #expect(job.stage == .waiting || job.stage == .preparing)
        await store.settle(job)
        #expect(job.stage == .prepared && job.spec.target == .all && job.spec.faceGuide)
        #expect(job.finished.count == 1, "renders already made stay")
    }

    @Test func backgroundRemovalIsAppliedWhenTheCharactersUpload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let store = makeStore(provider)
        let job = try await prepared(store)
        store.setRemoveBackground(true, of: job)
        store.render(job, quality: .draft)
        await store.settle(job)
        // One plain pixel has no subject to lift, so the original goes.
        guard case .edit(_, let images, _, _) = provider.requests.first else {
            Issue.record("no edit was sent")
            return
        }
        #expect(images == job.spec.references)
    }

    /// A 400×400 PNG, big enough for Seedance.
    func picture() throws -> URL {
        let url = root.appending(path: "picture-\(UUID().uuidString).png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = try #require(
            CGContext(
                data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}
