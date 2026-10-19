import Foundation
import SwapjutsuDescribe
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// The prompt writer around prep: it describes before prep in the same slot, its description is kept on the clip,
/// and a description already there, the person's own, is never replaced.
@MainActor
@Suite(.serialized)
struct DescriptionTests {
    let base = JobStoreTests()
    nonisolated static let described = SceneDescription(
        characters: [.init(noun: "WOMAN", pronoun: "her", wardrobe: "red coat")], source: "Stand-in")

    actor Calls {
        var inputs: [DescribeInput] = []
        func add(_ input: DescribeInput) { inputs.append(input) }
    }

    func store(
        _ calls: Calls, isOn: Bool = true, background: BackgroundMode? = nil, delay: Duration = .milliseconds(30)
    ) -> JobStore {
        JobStore(
            root: base.root, providers: { _ in FakeProvider(statuses: []) },
            preparer: JobStoreTests.preparer(targets: [1], background: background), pollInterval: .zero, maxPolls: 5,
            saveRetryInterval: .milliseconds(5),
            describer: {
                guard isOn else { return nil }
                return { input, _ in
                    await calls.add(input)
                    var described = input.characters.isEmpty ? SceneDescription(source: "Stand-in") : Self.described
                    if let wish = input.wish {
                        described.request = .init(text: wish.text, reading: .verbatim(wish.text, people: wish.people))
                    }
                    return described
                }
            }, describeDelay: delay)
    }

    @Test func prepDescribesFirstAndTheDescriptionSurvivesARelaunch() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let first = store(calls)
        let job = first.enqueue(try await base.spec())
        await first.settle(job)
        #expect(job.stage == .prepared)
        #expect(job.spec.description?.characters == Self.described.characters)
        let inputs = await calls.inputs
        #expect(inputs.count == 1 && inputs[0].characters.count == 1 && inputs[0].location == nil)
        #expect(inputs[0].characters[0].path.hasPrefix(job.output.path))

        let restored = try #require(store(Calls()).jobs.first { $0.id == job.id })
        #expect(restored.spec.description == job.spec.description)
    }

    @Test func aDescriptionAlreadyThereIsKept() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let jobs = store(calls)
        var spec = try await base.spec()
        let own = SceneDescription(characters: [.init(noun: "ROBOT")], source: "Edited")
        spec.description = own
        let job = jobs.enqueue(spec)
        await jobs.settle(job)
        #expect(job.spec.description == own)
        #expect(await calls.inputs.isEmpty)
    }

    @Test func offLeavesTheClipWithoutADescription() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let jobs = store(calls, isOn: false)
        let job = jobs.enqueue(try await base.spec())
        await jobs.settle(job)
        #expect(job.stage == .prepared && job.spec.description == nil)
        #expect(await calls.inputs.isEmpty)
    }

    /// Waits while the clip is described again, for at most two seconds.
    func described(_ job: Job) async throws {
        for _ in 0..<400 where job.isDescribing { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!job.isDescribing)
    }

    /// A character given to a replaced person after prep is described with the clip again, by itself; the person's
    /// own description is never replaced.
    @Test func aCharacterAddedAfterPrepIsDescribed() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let jobs = store(calls)
        let job = jobs.enqueue(try await base.spec())
        await jobs.settle(job)
        #expect(await calls.inputs.count == 1)
        jobs.addReferences([try base.picture()], to: job, person: 1)
        try await described(job)
        let inputs = await calls.inputs
        let index = try #require(job.cast.first?.character)
        let character = job.spec.references[index]
        #expect(inputs.count == 2 && inputs[1].characters.map(\.lastPathComponent) == [character.lastPathComponent])
        #expect(job.spec.describedFrom == [character.lastPathComponent])

        let own = SceneDescription(characters: [.init(noun: "ROBOT")], source: "Edited")
        jobs.setDescription(own, of: job)
        jobs.addReferences([try base.picture()], to: job, person: 1)
        try await described(job)
        #expect(await calls.inputs.count == 2 && job.spec.description == own)
    }

    /// A clip prepared before it has any character, as an agent's prepare, is described once one is given.
    @Test func aClipPreparedWithoutCharactersIsDescribedOnceItHasOne() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let jobs = store(calls)
        var spec = try await base.spec()
        spec.references = []
        let job = jobs.enqueue(spec)
        await jobs.settle(job)
        #expect(job.spec.describedFrom == [] && job.spec.describedByPerson == nil)
        jobs.addReferences([try base.picture()], to: job, person: 1)
        try await described(job)
        let index = try #require(job.cast.first?.character)
        #expect(job.spec.describedFrom == [job.spec.references[index].lastPathComponent])
    }

    /// An agent's set_characters, or the person, giving the character, the place and the prompt one after another
    /// right after prep: one description reads them all, behind nothing else.
    @Test func aBurstOfChangesIsDescribedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        // Long enough that a busy test run never lets it pass between the edits.
        let jobs = store(calls, background: .replace, delay: .milliseconds(500))
        var spec = try await base.spec()
        spec.references = []
        spec.replaceBackground = true
        let job = jobs.enqueue(spec)
        await jobs.settle(job)
        let before = await calls.inputs.count
        jobs.addReferences([try base.picture()], to: job, person: 1)
        #expect(job.isDescribing)
        jobs.setBackground(try base.picture(), of: job)
        jobs.setPrompt("Make it dusk.", of: job)
        try await described(job)
        for _ in 0..<200 where !jobs.pendingWishes.isEmpty || jobs.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        let inputs = await calls.inputs.dropFirst(before)
        #expect(inputs.count == 1, "\(inputs.map { ($0.characters.count, $0.location != nil, $0.wish?.text ?? "-") })")
        #expect(inputs.first?.characters.count == 1 && inputs.first?.location != nil)
        #expect(inputs.first?.wish?.text == "Make it dusk.")
        #expect(job.spec.description?.request?.text == "Make it dusk.")
    }

    /// The prompt edited on a described clip is read again on its own, after the edits stop, so the render folds
    /// it into the prompt's parts instead of adding it whole.
    @Test func anEditedPromptIsReadAgain() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let jobs = store(calls)
        let job = jobs.enqueue(try await base.spec())
        await jobs.settle(job)
        let before = await calls.inputs.count
        jobs.setPrompt("Make it", of: job)
        jobs.setPrompt("Make it rain.", of: job)
        for _ in 0..<100 where job.spec.description?.request?.text != "Make it rain." {
            try await Task.sleep(for: .milliseconds(5))
        }
        let inputs = await calls.inputs.dropFirst(before)
        #expect(inputs.count == 1 && inputs.first?.characters.isEmpty == true)
        #expect(job.spec.description?.request?.text == "Make it rain.")
    }

    /// A duo described before prep has its moves read together; once prep tells where each performer stands, only
    /// the moves are read again, one per performer, and the characters' description is kept.
    @Test func aDuosMovesAreReadApartOncePrepPlacesThem() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let calls = Calls()
        let places = ["on the left", "on the right"]
        let brief = String(decoding: try JSONEncoder().encode(ServicePrompt(people: 2, places: places)), as: UTF8.self)
        let jobs = JobStore(
            root: base.root, providers: { _ in FakeProvider(statuses: []) },
            preparer: { _, output, _ in
                let json = """
                    {"source": "clip.mp4", "width": 64, "height": 64, "fps": 24, "frames": 12, "shots": [],
                     "timeline": [], "identities": [], "targets": [1, 2], "warnings": [],
                     "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                                 "mergeDistance": 0.33},
                     "seedance": {"video": "control.mp4", "prompt": "Replace them.", "durationSeconds": 0.5,
                                  "brief": \(brief)},
                     "timings": {}}
                    """
                try Data(json.utf8).write(to: output.appending(path: "manifest.json"))
                return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
            }, pollInterval: .zero, maxPolls: 5, saveRetryInterval: .milliseconds(5),
            describer: {
                { input, _ in
                    await calls.add(input)
                    var described = input.known ?? Self.described
                    described.motion = .init(
                        beats: "both talk", performers: input.performers.map { _ in .init(beats: "a step") })
                    return described
                }
            }, describeDelay: .milliseconds(30))
        var spec = try await base.spec()
        spec.references.append(try base.picture())
        let job = jobs.enqueue(spec)
        await jobs.settle(job)
        try await described(job)
        let inputs = await calls.inputs
        #expect(inputs.count == 2)
        #expect(inputs.first?.performers == [] && inputs.first?.known == nil)
        #expect(inputs.last?.performers == places && inputs.last?.known?.characters == Self.described.characters)
        #expect(job.spec.description?.motion?.performers.count == 2)
        #expect(job.spec.description?.characters == Self.described.characters)
    }

    @Test func theWishesWinOverTheDescription() async throws {
        var spec = try await base.spec()
        defer { try? FileManager.default.removeItem(at: base.root) }
        spec.prompt =
            "Replace the dancer in @Video1 with the woman in @Image1: a long green dress, no hat. Keep it calm."
        // As a model reads it (`DescriptionPrompts.wish`).
        spec.description = Self.described
        spec.description?.request = .init(
            text: spec.prompt,
            reading: Wish(
                characters: [.init(performer: "the dancer", noun: "woman", looks: "a long green dress, no hat")],
                notes: ["Keep it calm."]))
        let job = Job(spec: spec, output: base.root)
        let output = base.root.appending(path: "manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = try await JobStoreTests.preparer(targets: [1])(spec, output) { _ in }
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        var seedance = try #require(json["seedance"] as? [String: Any])
        seedance["brief"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ServicePrompt(people: 1)))
        json["seedance"] = seedance
        job.manifest = try JSONDecoder().decode(Manifest.self, from: JSONSerialization.data(withJSONObject: json))
        let prompt = job.effectivePrompt
        // The person's words for the look come first, then what the description adds.
        #expect(prompt.contains("the replacement WOMAN: a long green dress, no hat. Wardrobe: red coat."))
        #expect(prompt.contains("REPLACE the colored-depth dancer"))
        #expect(prompt.contains("\nKeep it calm.\nIdentity lock:") && prompt.hasSuffix("stays exactly the same."))
    }
}

/// Settings' local models: the large tiers only on 32 GB Macs, and the chain the choice gives `Describer`.
@MainActor
struct VisionModelsTests {
    /// Downloads nothing: an empty snapshot folder named after the commit, as Hugging Face's cache lays it out.
    struct Backend: LocalVisionBackend {
        func download(
            repo: String, revision: String, into folder: URL, progress: @escaping @Sendable (Double) -> Void
        ) async throws -> URL {
            let files = folder.appending(path: "models--\(repo.replacingOccurrences(of: "/", with: "--"))")
                .appending(path: "snapshots/\(revision)")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            return files
        }
        func model(in folder: URL, name: String) -> any VisionLanguageModel { SystemVisionModel() }
    }

    @Test func largeModelsNeed32GB() {
        let gigabyte: UInt64 = 1_073_741_824
        #expect(VisionModelOption.offered(memory: 16 * gigabyte).allSatisfy { $0.memory == 16 })
        #expect(VisionModelOption.offered(memory: 16 * gigabyte).count == 3)
        #expect(VisionModelOption.offered(memory: 36 * gigabyte).count == VisionModelOption.all.count)
        #expect(VisionModelOption.offered(memory: 8 * gigabyte).isEmpty)
    }

    @Test func everyModelIsPinnedToACommitWithItsWeights() {
        for option in VisionModelOption.all {
            #expect(option.pin.revision.count == 40)
            let paths = option.pin.files.map(\.path)
            #expect(paths.contains("config.json") && paths.contains { $0.hasSuffix(".safetensors") })
            #expect(option.pin.files.allSatisfy { $0.sha256.count == 64 })
            let gigabytes = Double(option.pin.files.map(\.size).reduce(0, +)) / 1e9
            #expect(abs(gigabytes - option.gigabytes) < 0.1)
        }
    }

    @Test func aDownloadThatDiffersFromItsPinIsDiscarded() async throws {
        let suite = "swapjutsu-describer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let models = VisionModels(
            backend: Backend(), folder: folder, defaults: defaults, apiKey: KeychainSecret(service: suite),
            verify: ModelFiles.firstMismatch)
        models.download(.standard)
        while !models.progress.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!models.isDownloaded(.standard))
        #expect(models.failure?.contains("pinned SHA-256") == true)
        #expect(!FileManager.default.fileExists(atPath: models.folder(of: .standard).path(percentEncoded: false)))
    }

    @Test func theChoiceFallsBackToApplesModel() throws {
        let suite = "swapjutsu-describer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let models = VisionModels(
            backend: Backend(), folder: folder, defaults: defaults, apiKey: KeychainSecret(service: suite),
            verify: { _, _ in nil })
        #expect(models.choice == .local)
        #expect(models.models().map(\.name) == [SystemVisionModel().name])

        try FileManager.default.createDirectory(at: models.folder(of: models.chosen), withIntermediateDirectories: true)
        let marker = models.folder(of: models.chosen).appending(path: ".complete")
        try Data("snapshots/0000000000000000000000000000000000000000".utf8).write(to: marker)
        #expect(!models.isDownloaded(models.chosen))
        try Data("snapshots/\(models.chosen.pin.revision)".utf8).write(to: marker)
        #expect(models.isDownloaded(models.chosen))
        #expect(models.models().count == 2)

        models.choice = .api
        models.apiModel = "qwen3-vl"
        #expect(models.models().map(\.name).first == "qwen3-vl")
        models.choice = .off
        #expect(models.models().isEmpty)
        models.delete(models.chosen)
        #expect(!models.isDownloaded(models.chosen))
    }
}
