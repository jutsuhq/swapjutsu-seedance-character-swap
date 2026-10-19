import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// A person's corrections (#58): the corrected-shot driver's order, chunks and pinned slots with a stand-in tracker
/// (no Core ML), the pinned conditioning memory, the flags, and the corrections file.
struct TargetCorrectionTests {
    // MARK: Corrected tracking

    @Test func backwardInChunksFromTheCorrectionThenForward() async throws {
        let run = try await track(start: 0, end: 10, corrections: [(6, .mask([255]))], chunk: 4)
        #expect(run.stepped == [6, 5, 4, 3, 2, 1, 0, 6, 7, 8, 9])
        #expect(run.emitted == [6, 5, 4, 3, 2, 1, 0, 7, 8, 9])
        #expect(run.tracker.seededOn == [6, 6], "both sweeps start from the correction")
        #expect(run.reads == [3..<7, 0..<3, 6..<10], "the shot re-read backward in chunks, then forward")
        #expect(run.driver.peakHeldFrames == 4, "at most one chunk held")
        #expect(run.progress.last == 11)
        // Each step is told the next frame of its sweep first (`lookahead`), within a chunk going backward.
        let events = "a5 s6 a4 s5 a3 s4 s3 a1 s2 a0 s1 s0 a7 s6 a8 s7 a9 s8 s9"
        #expect(run.tracker.events == events.split(separator: " ").map(String.init))
    }

    @Test func laterCorrectionsArePinnedWhereTheForwardSweepMeetsThem() async throws {
        let run = try await track(
            start: 2, end: 12, corrections: [(9, .mask([255])), (4, .mask([255])), (20, .mask([255]))], chunk: 8)
        #expect(run.tracker.seededOn == [4, 4], "the earliest correction in the shot is the seed")
        #expect(run.tracker.pinnedOn == [9], "frame 20 is outside the shot")
        #expect(run.emitted.sorted() == Array(2..<12))
    }

    @Test func aClickBecomesTheTrackersMaskOnItsFrame() async throws {
        let run = try await track(start: 0, end: 5, corrections: [(2, .point(CGPoint(x: 3, y: 1)))], chunk: 8)
        #expect(run.tracker.clicks == [2])
        #expect(run.driver.correctionMasks[2] == [200])
        #expect(run.reads.first == 2..<3, "the click's frame is read once on its own")
    }

    @Test func onePositivePointGoesToTheClickAndMoreNeedTheTrackersOwn() async throws {
        let one = try await track(
            start: 0, end: 5, corrections: [(2, .points([PromptPoint(CGPoint(x: 3, y: 1))]))], chunk: 8)
        #expect(one.tracker.clicks == [2])
        await #expect(throws: PrepError.self, "a stand-in without mask(points:) takes no negative click") {
            _ = try await track(
                start: 0, end: 5,
                corrections: [(2, .points([PromptPoint(CGPoint(x: 3, y: 1)), PromptPoint(.zero, positive: false)]))],
                chunk: 8)
        }
    }

    @Test func anEmptyCorrectionIsRefused() async throws {
        await #expect(throws: PrepError.self) {
            _ = try await track(start: 0, end: 5, corrections: [(2, .mask([0]))], chunk: 8)
        }
    }

    @Test func personsCorrectionsOutrankAutomaticOnes() {
        var memory = ConditioningMemory(seed: "seed", frame: 0, maxCorrections: 2)
        memory.correct("mine", frame: 5, pinned: true)
        memory.correct("vision a", frame: 10)
        memory.correct("vision b", frame: 20)
        #expect(memory.entries.map(\.entry) == ["seed", "mine", "vision b"], "an automatic one goes, not mine")
        memory.correct("mine 2", frame: 30, pinned: true)
        #expect(memory.entries.map(\.entry) == ["seed", "mine", "mine 2"])
        memory.correct("vision c", frame: 40)
        #expect(memory.entries.map(\.entry) == ["seed", "mine", "mine 2"], "no slot for Vision when all are mine")
        memory.correct("mine 3", frame: 50, pinned: true)
        #expect(memory.entries.map(\.entry) == ["seed", "mine 2", "mine 3"], "the newest of mine wins")
    }

    // MARK: Flags

    private func grid(_ cells: Set<Int>) -> MaskGrid { MaskGrid(side: 4, cells: (0..<16).map { cells.contains($0) }) }

    @Test func flagsMarkJumpsOverlapLossAndLowScoresAsRuns() {
        let body: Set<Int> = [5, 6, 9, 10]
        let other = grid([2, 3])
        let frames = (0..<10).map { n -> TrackingFlags.Frame in
            switch n {
            case 3: .init(frame: n, mask: grid(body.union([1, 2, 3, 7])), score: 5, visionSees: true, others: [other])
            case 6, 7: .init(frame: n, mask: nil, score: -2, visionSees: true, others: [])
            case 9: .init(frame: n, mask: grid(body), score: 0.4, visionSees: true, others: [])
            default: .init(frame: n, mask: grid(body), score: 5, visionSees: true, others: [other])
            }
        }
        let flags = TrackingFlags.flags(frames, tuning: TrackingTuning().flags)
        #expect(flags.map(\.frame) == [3, 6, 9])
        #expect(flags[0] == TrackingFlag(frame: 3, until: 4, reasons: [.areaJump, .overlap]))
        #expect(flags[1] == TrackingFlag(frame: 6, until: 7, reasons: [.lost]))
        #expect(flags[2].reasons == [.lowScore])
        var few = TrackingTuning().flags
        few.maxRuns = 1
        #expect(TrackingFlags.flags(frames, tuning: few).map(\.frame) == [3], "the longest first, ties by frame")
    }

    @Test func aSteadyShotHasNoFlags() {
        let frames = (0..<5).map {
            TrackingFlags.Frame(frame: $0, mask: grid([5, 6]), score: 8, visionSees: $0 != 2, others: [grid([0])])
        }
        #expect(TrackingFlags.flags(frames, tuning: TrackingTuning().flags).isEmpty)
    }

    // MARK: The file

    @Test func correctionsAndTheirMasksSurviveInThePrepFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "corrections-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try TargetCorrections.load(from: folder).isEmpty)
        let bytes: [UInt8] = [0, 255, 0, 0, 200, 0]
        let file = try TargetCorrections.storeMask(bytes, width: 3, height: 2, in: folder, name: "fix")
        let list = [
            TargetCorrection(shot: 0, frame: 4, identity: 1, kind: .point(x: 0.25, y: 0.5)),
            TargetCorrection(shot: 1, frame: 90, identity: 2, kind: .mask(file: file)),
        ]
        try TargetCorrections.save(list, to: folder)
        #expect(try TargetCorrections.load(from: folder) == list)
        let read = try TargetCorrections.maskBytes(folder.appending(path: file), width: 3, height: 2)
        #expect(read == [0, 255, 0, 0, 255, 0], "rows top-down, binary")
        try TargetCorrections.save([], to: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: TargetCorrections.file).path))
    }

    // MARK: Stand-ins

    private struct Run {
        let driver: CorrectedTracking
        let tracker: StandIn
        let stepped: [Int]
        let emitted: [Int]
        let reads: [Range<Int>]
        let progress: [Int]
    }

    private func track(
        start: Int, end: Int, corrections: [(Int, CorrectedTracking.Prompt)], chunk: Int
    ) async throws -> Run {
        let tracker = StandIn()
        let reads = Box<[Range<Int>]>([])
        let progress = Box<[Int]>([])
        let driver = CorrectedTracking(
            tracker: tracker, context: CIContext(),
            read: { range, body in
                reads.value.append(range)
                for n in range {
                    try body(n, CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 10 + n, height: 2)))
                }
            }, chunk: chunk, progress: { done, _ in progress.value.append(done) })
        var emitted: [Int] = []
        try await driver.run(
            .init(
                index: 0, start: start, end: end, object: 1, crop: nil,
                corrections: corrections.map { .init(frame: $0.0, prompt: $0.1) })
        ) { n, _ in emitted.append(n) }
        return Run(
            driver: driver, tracker: tracker, stepped: tracker.stepped, emitted: emitted, reads: reads.value,
            progress: progress.value)
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private final class StandIn: MaskTracking {
        let name = "StandIn"
        private(set) var stepped: [Int] = []
        private(set) var seededOn: [Int] = []
        private(set) var pinnedOn: [Int] = []
        private(set) var clicks: [Int] = []
        /// `a<n>`: told frame n comes next (`lookahead`); `s<n>`: stepped frame n.
        private(set) var events: [String] = []
        private var tracking = false

        func lookahead(_ next: CIImage) { events.append("a\(Int(next.extent.width) - 10)") }

        func startShot(crops: [Int: TrackingCrop]) { tracking = false }

        func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
            try step(frame, seeds: seeds, corrections: [:], pinned: [])
        }

        func step(
            _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]], pinned: Set<Int>
        ) throws -> [Int: TrackedMask] {
            let n = Int(frame.extent.width) - 10
            stepped.append(n)
            events.append("s\(n)")
            if !seeds.isEmpty {
                seededOn.append(n)
                tracking = true
            }
            if !pinned.isEmpty { pinnedOn.append(n) }
            return tracking ? [1: TrackedMask(score: 5, mask: [255])] : [:]
        }

        func mask(at point: CGPoint, on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
            clicks.append(Int(frame.extent.width) - 10)
            return [200]
        }
    }
}
