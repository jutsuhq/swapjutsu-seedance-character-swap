import CoreImage
import Foundation
import ImageIO
import SwapjutsuAgent
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// prepare, clips, set_characters and prepare_again against a real `JobStore` in a temporary folder, with a stand-in
/// for prep and a real 10 s video. Files arrive as an upload leaves them: in the inbox.
@MainActor
@Suite(.serialized)
struct AgentPrepTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-agent-\(UUID().uuidString)")
    var inbox: URL { root.appending(path: "inbox") }
    var jobsFolder: URL { root.appending(path: "jobs") }

    @Test func prepareReturnsAClipPerRangeAtOnceAndSavesItsOrigin() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make()
        let command = try await prepare("r1", ranges: [.init(start: 0, end: 4), .init(start: 5, end: 10)])
        let clips = try #require(try await commands.run(.prepare(command)).clips)
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { $0.stage == "waiting" || $0.stage == "preparing" })
        #expect(clips.compactMap(\.range) == command.ranges)
        #expect(clips.map(\.origin?.client) == ["Test Agent", "Test Agent"])

        let job = try #require(store.job(UUID(uuidString: clips[0].id)))
        let saved = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: job.recordURL)) as? [String: Any])
        let origin = try #require(saved["origin"] as? [String: Any])
        #expect(origin["client"] as? String == "Test Agent")
        #expect(origin["requestID"] as? String == "r1")
        #expect(origin["started"] is String)
        #expect(try JobRecord.decode(Data(contentsOf: job.recordURL))?.origin == job.origin)
        for job in store.jobs { await store.settle(job) }
    }

    @Test func theSameRequestReturnsTheSameClipsAlsoAfterARelaunch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make()
        let command = try await prepare("again", ranges: [.init(start: 1, end: 6)], target: .all)
        let first = try #require(try await commands.run(.prepare(command)).clips?.map(\.id))
        let second = try #require(try await commands.run(.prepare(command)).clips?.map(\.id))
        #expect(first == second && store.jobs.count == 1)
        for job in store.jobs { await store.settle(job) }

        let (relaunched, relaunchedCommands) = make()
        #expect(relaunched.jobs.count == 1)
        let third = try #require(try await relaunchedCommands.run(.prepare(command)).clips)
        #expect(third.map(\.id) == first && relaunched.jobs.count == 1)
        #expect(third.first?.stage == "prepared" && third.first?.target == .all)
    }

    @Test func theSameRequestWithOtherParametersIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make()
        _ = try await commands.run(.prepare(try await prepare("x", ranges: [.init(start: 0, end: 5)])))
        var other = try await prepare("x", ranges: [.init(start: 0, end: 6)])
        await #expect(throws: AgentError.Code.requestConflict) {
            try await code { try await commands.run(.prepare(other)) }
        }
        other.ranges = [.init(start: 0, end: 5)]
        other.faceGuide = true
        await #expect(throws: AgentError.Code.requestConflict) {
            try await code { try await commands.run(.prepare(other)) }
        }
        #expect(store.jobs.count == 1)
        for job in store.jobs { await store.settle(job) }
    }

    @Test func theVideoIsAdoptedFromTheInboxAndTheInboxIsCleared() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let (store, commands) = make(gate: gate)
        let command = try await prepare("adopt", ranges: [.init(start: 2, end: 7)])
        let clip = try #require(try await commands.run(.prepare(command)).clips?.first)
        let job = try #require(store.job(UUID(uuidString: clip.id)))
        #expect(job.source.path == URL(filePath: command.file).resolvingSymlinksInPath().path, "the inbox copy")

        commands.sweepInbox(now: Date().addingTimeInterval(7200))
        #expect(FileManager.default.fileExists(atPath: command.file), "kept while a clip still reads it")
        await gate.release()
        await store.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        #expect(job.source.path.hasPrefix(job.output.appending(path: "inputs").path))
        commands.sweepInbox()
        #expect(FileManager.default.fileExists(atPath: command.file), "a fresh folder may still be filling")
        commands.sweepInbox(now: Date().addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: inbox.appending(path: "adopt").path))
    }

    @Test func filesOutsideTheInboxAreNeverOpened() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make()
        var command = try await prepare("outside")
        let elsewhere = root.appending(path: "elsewhere.mp4")
        try FileManager.default.copyItem(atPath: command.file, toPath: elsewhere.path)
        command.file = elsewhere.path
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.prepare(command)) }
        }
        command.file = inbox.appending(path: "outside/../../elsewhere.mp4").path
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.prepare(command)) }
        }
        #expect(store.jobs.isEmpty)
    }

    @Test(arguments: [
        ([AgentRange(start: 0, end: 3)], AgentError.Code.badRequest),
        ([AgentRange(start: 0, end: 31)], .badRequest),
        ([AgentRange(start: 0, end: 5), AgentRange(start: 4, end: 9)], .badRequest),
        ([AgentRange(start: 6, end: 11)], .badRequest),
        ([AgentRange(start: -1, end: 4)], .badRequest),
        ([], .badRequest),
    ])
    func rangesOutsideSeedancesLimitsAreRefused(ranges: [AgentRange], expected: AgentError.Code) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make()
        let command = try await prepare("ranges", ranges: ranges)
        await #expect(throws: expected) { try await code { try await commands.run(.prepare(command)) } }
        #expect(store.jobs.isEmpty)
    }

    @Test func otherInputsAreChecked() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make()
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.prepare(try await prepare("../up"))) }
        }
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.prepare(try await prepare("ids", target: .people([0])))) }
        }
        var notVideo = try await prepare("image")
        let image = inbox.appending(path: "image/face.png")
        try picture(400, 400).write(to: image)
        notVideo.file = image.path
        await #expect(throws: AgentError.Code.fileRefused) {
            try await code { try await commands.run(.prepare(notVideo)) }
        }
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.clips(ClipsCommand(waitSeconds: 61))) }
        }
        await #expect(throws: AgentError.Code.noSuchClip) {
            try await code { try await commands.run(.clips(ClipsCommand(clip: UUID().uuidString))) }
        }
        await #expect(throws: AgentError.Code.noSuchClip) {
            try await code { try await commands.run(.prepareAgain(PrepareAgainCommand(clip: "nope"))) }
        }
        #expect(store.jobs.isEmpty)
    }

    @Test func clipsWaitsForPrepAndShowsThePeople() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, commands) = make()
        let id = try #require(try await commands.run(.prepare(try await prepare("people", target: .all))).clips?.first?.id)
        let clip = try #require(try await commands.run(.clips(ClipsCommand(clip: id, waitSeconds: 30))).clips?.first)
        #expect(clip.stage == "prepared", "\(clip.progress)")
        #expect(clip.people?.map(\.id) == [1, 2] && clip.people?.allSatisfy(\.isTarget) == true)
        #expect(clip.people?.first?.screenShare == 0.7)
        let crop = try #require(clip.people?.first?.crop)
        #expect(crop.hasPrefix(clip.folder) && FileManager.default.fileExists(atPath: crop))
        #expect(clip.control == clip.folder + "/control.mp4" && clip.review == clip.folder + "/review.mp4")
        #expect(clip.warnings == ["A warning"] && clip.missingCharacters == 2)
        #expect(try await commands.run(.clips(ClipsCommand())).clips?.map(\.id) == [id])
    }

    @Test func charactersGoToTheirPeopleWithTheAppsLimits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let (store, commands) = make(gate: gate)
        let id = try #require(try await commands.run(.prepare(try await prepare("cast", target: .all))).clips?.first?.id)
        let job = try #require(store.job(UUID(uuidString: id)))

        let early = SetCharactersCommand(clip: id, characters: [try character(1, "early")])
        await #expect(throws: AgentError.Code.notPrepared) {
            try await code { try await commands.run(.setCharacters(early)) }
        }
        await gate.release()
        await store.settle(job)

        let twice = SetCharactersCommand(clip: id, characters: [try character(1, "one"), try character(1, "two")])
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.setCharacters(twice)) }
        }
        let stranger = SetCharactersCommand(clip: id, characters: [try character(3, "stranger")])
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.setCharacters(stranger)) }
        }
        let small = SetCharactersCommand(clip: id, characters: [try character(1, "small", size: 200)])
        await #expect(throws: AgentError.Code.fileRefused) {
            try await code { try await commands.run(.setCharacters(small)) }
        }
        #expect(job.spec.references.isEmpty, "a refused image changes nothing")

        let cast = SetCharactersCommand(
            clip: id, characters: [try character(2, "b"), try character(1, "a")], removeBackground: true,
            prompt: "Make it rain.")
        let clip = try #require(try await commands.run(.setCharacters(cast)).clips?.first)
        #expect(clip.missingCharacters == 0 && clip.removeBackground && clip.prompt == "Make it rain.")
        #expect(clip.characters.allSatisfy { $0.hasPrefix(clip.folder + "/inputs/") })
        #expect(clip.people?.compactMap(\.character) == [clip.characters[1], clip.characters[0]], "in any order")
        #expect(!FileManager.default.fileExists(atPath: inbox.appending(path: "a").path), "the inbox copy is gone")

        var view = try character(1, "side")
        view.view = true
        let more = try #require(
            try await commands.run(.setCharacters(SetCharactersCommand(clip: id, characters: [view]))).clips?.first)
        #expect(more.characters.count == 3 && more.missingCharacters == 0)
        #expect(
            more.people?.first?.views == [more.characters[2]] && more.people?.first?.character == clip.characters[1])
    }

    @Test func prepareAgainChangesWhoIsReplaced() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        let (store, commands) = make(gate: gate)
        let id = try #require(try await commands.run(.prepare(try await prepare("redo"))).clips?.first?.id)
        await #expect(throws: AgentError.Code.busy) {
            try await code { try await commands.run(.prepareAgain(PrepareAgainCommand(clip: id, target: .all))) }
        }
        let job = try #require(store.job(UUID(uuidString: id)))
        await gate.release()
        await store.settle(job)
        #expect(job.manifest?.targets == [1])

        await #expect(throws: AgentError.Code.badRequest) {
            try await code {
                try await commands.run(.prepareAgain(PrepareAgainCommand(clip: id, target: .people([5]))))
            }
        }
        let again = try await commands.run(
            .prepareAgain(PrepareAgainCommand(clip: id, target: .people([2]), faceGuide: true, control: .hybridHands)))
        #expect(again.clips?.first?.target == .people([2]))
        #expect(again.clips?.first?.controlMode == .hybridHands)
        await store.settle(job)
        #expect(job.manifest?.targets == [2] && job.spec.faceGuide && job.spec.targetIDs == [2])
        #expect(job.spec.options.control == .hybridHands)
        store.prepareAgain(job)
        await store.settle(job)
        #expect(job.spec.targetIDs == [2], "Prepare Again in Jobs keeps the people")
    }

}

// MARK: Helpers

extension AgentPrepTests {
    private func make(gate: Gate? = nil) -> (JobStore, AgentCommands) {
        let store = JobStore(
            root: jobsFolder, providers: { _ in throw GenerationError.noKey }, preparer: Self.preparer(gate))
        let commands = AgentCommands(
            credentials: Credentials(
                comfy: ComfyKeyStore(secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.agents"))),
            depth: DepthModel(load: { _ in throw CancellationError() }), navigation: Navigation(), jobs: store,
            inbox: inbox, bringForward: {})
        return (store, commands)
    }

    /// A request as the binary sends it, the video already in `inbox/<request>/`.
    private func prepare(
        _ requestID: String, ranges: [AgentRange]? = nil, target: AgentTarget? = nil
    ) async throws -> PrepareCommand {
        let folder = inbox.appending(path: requestID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "clip.mp4")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: try await Self.video(), to: file)
        }
        return PrepareCommand(
            requestID: requestID, video: "/tmp/agent/clip.mp4", file: file.path, ranges: ranges, target: target,
            client: "Test Agent")
    }

    private func character(_ person: Int, _ folder: String, size: Int = 400) throws -> SetCharactersCommand.Character {
        let file = inbox.appending(path: "\(folder)/person-\(person).png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try picture(size, size).write(to: file)
        return .init(person: person, image: "/tmp/agent/\(folder).png", file: file.path)
    }

    private func picture(_ width: Int, _ height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The error's code, for `#expect(throws:)`.
    private func code<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as AgentError {
            throw error.code
        }
    }

    /// A 10 s silent clip at 2 fps, written once per test run.
    static func video() async throws -> URL { try await Self.videoFile.value }

    /// One shared write, so tests running at once neither block a thread on it nor write the file twice.
    private static let videoFile = Task {
        let url = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-agent-clip.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let writer = try VideoWriter(url: url, size: CGSize(width: 64, height: 64), fps: 2, context: CIContext())
        for _ in 0..<20 {
            try writer.append(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)))
        }
        try await writer.finish()
        return url
    }

    /// Two people, replaced as the options say, with a face crop each and the two videos.
    static func preparer(_ gate: Gate?) -> Preparer {
        { spec, output, _ in
            await gate?.wait()
            let targets =
                switch spec.options.target {
                case .main: [1]
                case .all: [1, 2]
                case .ids(let ids): ids
                }
            let json = """
                {"source": "source.mov", "width": 64, "height": 64, "fps": 2, "frames": 10, "shots": [],
                 "timeline": [], "targets": \(targets), "warnings": ["A warning"],
                 "identities": [
                    {"id": 1, "frames": 10, "shots": [0], "screenShare": 0.7, "thumbnail": "identities/1.jpg",
                     "isTarget": \(targets.contains(1))},
                    {"id": 2, "frames": 6, "shots": [0], "screenShare": 0.3, "thumbnail": "identities/2.jpg",
                     "isTarget": \(targets.contains(2))}],
                 "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                             "mergeDistance": 0.33},
                 "seedance": {"video": "control.mp4", "prompt": "Replace the person.", "durationSeconds": 5},
                 "timings": {}}
                """
            try FileManager.default.createDirectory(
                at: output.appending(path: "identities"), withIntermediateDirectories: true)
            for name in ["control.mp4", "review.mp4", "identities/1.jpg", "identities/2.jpg"] {
                try Data().write(to: output.appending(path: name))
            }
            try Data(json.utf8).write(to: output.appending(path: "manifest.json"))
            return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        }
    }
}

extension AgentError.Code: Error {}

/// Holds prep until released, so a test sees a clip while it is on its way.
actor Gate {
    private var isOpen = false

    func release() { isOpen = true }

    func wait() async {
        while !isOpen { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
