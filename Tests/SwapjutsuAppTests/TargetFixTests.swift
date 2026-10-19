import Foundation
import SwapjutsuAgent
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// The target fix of a prepared clip (#58): the flagged frames, a click or a painted mask, the re-track with its
/// progress and after-masks, the correction in the clip's folder, and correct_target for agents. Prep and the tracker
/// are stand-ins.
@MainActor
@Suite(.serialized)
struct TargetFixTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-fix-\(UUID().uuidString)")

    @Test func aClickOnAFlaggedFrameRetracksItsShotAndKeepsTheCorrection() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = StandIn()
        let (store, job, fixes) = try await prepared(tracker)
        let fix = fixes.fix(for: job)
        #expect(fix === fixes.fix(for: job), "one fix per clip, for the Prep step and agents")
        #expect(fix.flags.map(\.title) == ["Frame 2 · lost", "Frames 6–7 · size jump · on someone else"])
        #expect(fix.frame == 2, "opens on the first flagged frame")

        let flag = fix.flags[1]
        fix.select(frame: flag.frame, person: flag.person)
        #expect(!fix.hasCorrection)
        fix.click(CGPoint(x: 0.25, y: 0.75))
        await fix.retrack()

        #expect(fix.phase == .retracked)
        let request = try #require(tracker.requests.first)
        #expect((request.shot, request.start, request.end, request.identity) == (1, 5, 10, 1), "the second shot only")
        #expect(request.crop == TrackingCrop(x: 8, y: 0, width: 56, height: 64))
        #expect(request.keep == [6, 7])
        #expect(request.corrections.map(\.kind) == [.point(x: 0.25, y: 0.75)])
        #expect(fix.after[6] == [UInt8](repeating: 255, count: 64 * 64))
        #expect(tracker.progressed, "progress came through")
        let saved = try TargetCorrections.load(from: job.output)
        #expect(saved.map(\.frame) == [6] && saved.first?.shot == 1)
        #expect(fix.summary?.hasPrefix("re-tracked shot 1 from frame 6") == true)

        // A second fix of the same frame replaces the first; another frame of the shot joins it.
        fix.click(CGPoint(x: 0.5, y: 0.5))
        #expect(fix.phase == .editing, "a new click is not re-tracked yet")
        await fix.retrack()
        fix.select(frame: 8)
        fix.click(CGPoint(x: 0.5, y: 0.25))
        await fix.retrack()
        #expect(try TargetCorrections.load(from: job.output).map(\.frame) == [6, 8])
        #expect(tracker.requests.last?.corrections.map(\.frame) == [6, 8])

        fix.removeFixes()
        #expect(try TargetCorrections.load(from: job.output).isEmpty)
        #expect(fix.phase == .editing && fix.after.isEmpty)
    }

    @Test func paintingStartsFromThePrepsMaskAndGoesInAsAPNG() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = StandIn()
        let (store, job, fixes) = try await prepared(tracker)
        let fix = fixes.fix(for: job)
        fix.select(frame: 3)
        fix.tool = .paint
        let base = [UInt8](repeating: 0, count: 64 * 64)
        fix.brush(CGPoint(x: 0.5, y: 0.5), radius: 0.1, base: base)
        fix.tool = .erase
        fix.brush(CGPoint(x: 0.5, y: 0.5), radius: 0.02, base: base)
        let painted = try #require(fix.painted)
        #expect(painted[32 * 64 + 32] == 0, "erased in the middle")
        #expect(painted[32 * 64 + 36] == 255, "painted around it")
        #expect(painted[0] == 0)
        await fix.retrack()

        let saved = try #require(try TargetCorrections.load(from: job.output).first)
        guard case .mask(let file) = saved.kind else {
            Issue.record("not a mask: \(saved.kind)")
            return
        }
        #expect(try TargetCorrections.maskBytes(job.output.appending(path: file), width: 64, height: 64) == painted)
        #expect(tracker.requests.first?.start == 0 && tracker.requests.first?.end == 5)
    }

    /// A drag goes on past the canvas, so the brush gets positions off the frame on every side.
    @Test func aBrushOffTheFrameKeepsOnlyThePartOnIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, job, fixes) = try await prepared(StandIn())
        let fix = fixes.fix(for: job)
        fix.select(frame: 3)
        let outside = [CGPoint(x: 1.2, y: 0.5), CGPoint(x: -0.2, y: 0.5), CGPoint(x: 0.5, y: -0.2), CGPoint(x: 0.5, y: 1.2)]
        for tool in [TargetFix.Tool.paint, .erase] {
            fix.tool = tool
            for unit in outside + [CGPoint(x: 9e300, y: -9e300), CGPoint(x: Double.nan, y: 0.5)] {
                fix.brush(unit, radius: 0.025, base: nil)
            }
        }
        #expect(fix.painted == nil, "a disc wholly off the frame paints nothing")

        fix.tool = .paint
        fix.brush(CGPoint(x: 1, y: 0.5), radius: 0.05, base: nil)
        fix.brush(CGPoint(x: 0.5, y: 0), radius: 0.05, base: nil)
        fix.brush(CGPoint(x: -0.02, y: 1.02), radius: 0.05, base: nil)
        let painted = try #require(fix.painted)
        #expect(painted[32 * 64 + 63] == 255, "the right edge")
        #expect(painted[32 * 64 + 59] == 0, "outside the disc")
        #expect(painted[0 * 64 + 32] == 255, "the top edge")
        #expect(painted[63 * 64 + 0] == 255, "the bottom-left corner")
        #expect(painted.filter { $0 == 255 }.count < 100, "only the parts on the frame")

        fix.tool = .erase
        fix.brush(CGPoint(x: 1.01, y: 0.5), radius: 0.05, base: nil)
        #expect(fix.painted?[32 * 64 + 63] == 0, "erasing past the edge reaches it")
        fix.brush(CGPoint(x: 0.5, y: 1.5), radius: 0.05, base: nil)
        #expect(fix.painted?[0 * 64 + 32] == 255, "erasing wholly off the frame changes nothing")
    }

    @Test func aFailedRetrackSaysWhyAndPreparingAgainStartsAFreshFix() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = StandIn()
        tracker.fails = true
        let (store, job, fixes) = try await prepared(tracker)
        let fix = fixes.fix(for: job)
        fix.click(CGPoint(x: 0.5, y: 0.5))
        await fix.retrack()
        guard case .failed = fix.phase else {
            Issue.record("phase \(fix.phase)")
            return
        }
        #expect(!(try TargetCorrections.load(from: job.output)).isEmpty, "the correction stays for the next prep")
        store.prepareAgain(job)
        await store.settle(job)
        #expect(fixes.fix(for: job) !== fix)
    }

    @Test func correctTargetClicksAndRetracksForAnAgent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = StandIn()
        let (store, job, fixes) = try await prepared(tracker)
        let navigation = Navigation()
        let commands = AgentCommands(
            credentials: Credentials(
                comfy: ComfyKeyStore(secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.fix"))),
            depth: DepthModel(load: { _ in throw CancellationError() }), navigation: navigation, jobs: store,
            fixes: fixes, inbox: root.appending(path: "inbox"), bringForward: {})
        let id = job.id.uuidString

        for bad in [
            CorrectTargetCommand(clip: id, person: 2, frame: 6, x: 10, y: 10),
            CorrectTargetCommand(clip: id, frame: 99, x: 10, y: 10),
            CorrectTargetCommand(clip: id, frame: 6, x: 10),
            CorrectTargetCommand(clip: id, frame: 6, x: 64, y: 10),
            CorrectTargetCommand(clip: id, frame: 6, x: 1, y: 1, file: "/nope.png"),
        ] {
            await #expect(throws: AgentError.self) { try await commands.run(.correctTarget(bad)) }
        }
        let clip = try #require(
            try await commands.run(.correctTarget(CorrectTargetCommand(clip: id, frame: 6, x: 16, y: 48))).clips?.first)
        #expect(clip.fix != nil)
        #expect(navigation.clip == job.id && fixes.fix(for: job).isOpen)
        let fix = fixes.fix(for: job)
        while fix.phase != .retracked { await Task.yield() }
        #expect(tracker.requests.first?.corrections.map(\.kind) == [.point(x: 0.25, y: 0.75)])
        let after = try #require(try await commands.run(.clips(ClipsCommand(clip: id))).clips?.first)
        #expect(after.fix?.contains("prepare_again") == true)
    }

    // MARK: Stand-ins

    /// Records each request, reports progress, and returns a full mask for every kept frame.
    private final class StandIn: @unchecked Sendable {
        var requests: [CorrectionPreview.Request] = []
        var progressed = false
        var fails = false

        var retracker: Retracker {
            { [self] request, progress in
                if fails { throw CocoaError(.fileReadCorruptFile) }
                requests.append(request)
                progress(1, 2)
                progress(2, 2)
                progressed = true
                return Dictionary(uniqueKeysWithValues: request.keep.map { ($0, [UInt8](repeating: 255, count: 64 * 64)) })
            }
        }
    }

    // swiftlint:disable:next large_tuple
    private func prepared(_ tracker: StandIn) async throws -> (JobStore, Job, TargetFixes) {
        let store = JobStore(
            root: root.appending(path: "jobs"), providers: { _ in throw GenerationError.noKey },
            preparer: Self.preparer)
        let source = root.appending(path: "clip.mov")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: source)
        let job = store.enqueue(
            JobSpec(
                title: "fix", source: source, references: [], prompt: "", target: .main, faceGuide: false,
                model: .seedance25))
        await store.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        return (store, job, TargetFixes(retracker: tracker.retracker))
    }

    /// Two shots of person 1: a lost frame in the first, a size jump in the second.
    private static let preparer: Preparer = { _, output, _ in
        let json = """
            {"source": "clip.mov", "width": 64, "height": 64, "fps": 2, "frames": 10,
             "shots": [{"index": 0, "start": 0, "end": 4}, {"index": 1, "start": 5, "end": 9}],
             "timeline": [], "targets": [1], "warnings": [],
             "identities": [{"id": 1, "frames": 10, "shots": [0, 1], "screenShare": 1, "isTarget": true}],
             "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                         "mergeDistance": 0.33},
             "seedance": {"video": "control.mp4", "prompt": "Replace the person.", "durationSeconds": 5},
             "timings": {"total": \(Double.random(in: 1...100))},
             "tracking": {"tracker": "EdgeTAM", "shots": [
                {"shot": 0, "target": 1, "source": "tracked", "seedFrame": 0, "trackedFrames": 4,
                 "recoveredFrames": 0, "lostFrames": 1, "longestLoss": 1,
                 "flags": [{"frame": 2, "until": 2, "reasons": ["lost"]}]},
                {"shot": 1, "target": 1, "source": "tracked", "seedFrame": 5, "trackedFrames": 5,
                 "recoveredFrames": 0, "lostFrames": 0, "longestLoss": 0, "crop": [8, 0, 56, 64],
                 "flags": [{"frame": 6, "until": 7, "reasons": ["areaJump", "overlap"]}]}]}}
            """
        try Data(json.utf8).write(to: output.appending(path: "manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    }
}
