import CoreImage
import Testing

@testable import SwapjutsuPrep

/// Two-way tracking's order and state with a stand-in tracker (no Core ML), and the seed score on synthetic grids.
///
/// Frame n is a (10 + n) × 2 image, so the stand-in can tell frames apart after the driver copies them. Its mask for
/// an object is one byte: how many frames that object has been followed since its seed in the current tracker
/// state, so a mask shows whether a sweep started fresh.
struct TwoWayTrackingTests {
    // MARK: Two-way tracking

    @Test func backwardFromTheSeedThenForward() throws {
        let run = try track(shots: [.init(start: 0, end: 10, seeds: [1: 6])], backward: true)
        #expect(run.stepped == [6, 5, 4, 3, 2, 1, 0, 6, 7, 8, 9])
        #expect(run.emitted.map(\.frame) == [6, 5, 4, 3, 2, 1, 0, 7, 8, 9])
        #expect(run.tracker.shots == 2, "one fresh state per direction")
        #expect(run.tracker.seededOn == [6, 6], "both sweeps start from the same seed")
        #expect(run.driver.peakHeldFrames == 6, "frames 0–5 held until the seed arrives")
        // Each step is told the next frame of its sweep first (`lookahead`): held frames at once, a live frame once
        // the next one arrives; the shot's last frame is stepped as it comes.
        let events = "a5 s6 a4 s5 a3 s4 a2 s3 a1 s2 a0 s1 s0 s6 a8 s7 a9 s8 s9"
        #expect(run.tracker.events == events.split(separator: " ").map(String.init))
    }

    @Test func finishStepsTheFrameStillWaitingWhenTheClipEndsEarly() throws {
        let shots: [TwoWayTracking.Shot] = [.init(start: 0, end: 10, seeds: [1: 2])]
        let early = try track(shots: shots, backward: false, frames: 7, finish: false)
        #expect(early.emitted.map(\.frame) == [2, 3, 4, 5], "frame 6 waits for a next frame")
        let finished = try track(shots: shots, backward: false, frames: 7)
        #expect(finished.emitted.map(\.frame) == [2, 3, 4, 5, 6])
    }

    @Test func everyFrameOfEveryObjectComesOnceWithTwoSeeds() throws {
        let run = try track(shots: [.init(start: 0, end: 10, seeds: [1: 3, 2: 6])], backward: true)
        for id in [1, 2] {
            let frames = run.emitted.filter { $0.id == id }.map(\.frame)
            #expect(frames.sorted() == Array(0..<10), "object \(id)")
        }
        #expect(run.stepped == [6, 5, 4, 3, 2, 1, 0, 3, 4, 5, 6, 7, 8, 9])
    }

    @Test func forwardOnlyHoldsNothingAndMatchesTheOldOrder() throws {
        let run = try track(
            shots: [.init(start: 0, end: 5, seeds: [1: 2]), .init(start: 5, end: 9, seeds: [1: 5])], backward: false)
        #expect(run.driver.peakHeldFrames == 0)
        #expect(run.stepped == [2, 3, 4, 5, 6, 7, 8])
        #expect(run.emitted.map(\.frame) == [2, 3, 4, 5, 6, 7, 8])
        #expect(run.tracker.shots == 2, "one state per shot")
        let events = "a3 s2 a4 s3 s4 a6 s5 a7 s6 a8 s7 s8"
        #expect(run.tracker.events == events.split(separator: " ").map(String.init), "no lookahead across a cut")
    }

    @Test func aFailingShotIsSkippedAndTheNextOneTracked() throws {
        let run = try track(
            shots: [.init(start: 0, end: 5, seeds: [1: 3]), .init(start: 5, end: 9, seeds: [1: 6])], backward: true,
            failOn: 1)
        #expect(run.driver.failed.keys.sorted() == [0])
        // Masks of the failed shot that came before the throw are left to the caller, which drops the whole shot.
        #expect(run.emitted.map(\.frame).filter { $0 >= 5 }.sorted() == [5, 6, 7, 8])
    }

    private struct Emitted {
        let frame: Int
        let id: Int
        let age: Int
    }

    private struct Run {
        let driver: TwoWayTracking
        let tracker: StandIn
        let stepped: [Int]
        let emitted: [Emitted]
    }

    private func track(
        shots: [TwoWayTracking.Shot], backward: Bool, failOn: Int? = nil, frames: Int? = nil, finish: Bool = true
    ) throws -> Run {
        let tracker = StandIn(failOn: failOn)
        var emitted: [Emitted] = []
        let driver = TwoWayTracking(
            tracker: tracker, shots: shots, backward: backward, context: CIContext(),
            seedMask: { _, _, _ in [255] },
            emit: { n, _, id, mask in emitted.append(Emitted(frame: n, id: id, age: Int(mask.mask?.first ?? 255))) })
        let end = frames ?? shots.map(\.end).max() ?? 0
        for n in 0..<end {
            try driver.feed(n, CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 10 + n, height: 2)))
        }
        if finish { try driver.finish() }
        return Run(driver: driver, tracker: tracker, stepped: tracker.stepped, emitted: emitted)
    }

    private final class StandIn: MaskTracking {
        let name = "StandIn"
        let failOn: Int?
        private var ages: [Int: Int] = [:]
        private(set) var shots = 0
        private(set) var stepped: [Int] = []
        private(set) var seededOn: [Int] = []
        /// `a<n>`: told frame n comes next (`lookahead`); `s<n>`: stepped frame n.
        private(set) var events: [String] = []

        init(failOn: Int?) { self.failOn = failOn }

        func lookahead(_ next: CIImage) { events.append("a\(Int(next.extent.width) - 10)") }

        func startShot(crops: [Int: TrackingCrop]) {
            ages = [:]
            shots += 1
        }

        func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
            let n = Int(frame.extent.width) - 10
            if n == failOn { throw PrepError.model("stand-in fails on \(n)") }
            stepped.append(n)
            events.append("s\(n)")
            var out: [Int: TrackedMask] = [:]
            for id in ages.keys {
                ages[id, default: 0] += 1
                out[id] = TrackedMask(score: 1, mask: [UInt8(ages[id] ?? 0)])
            }
            for id in seeds.keys {
                ages[id] = 0
                seededOn.append(n)
                out[id] = TrackedMask(score: 10, mask: [0])
            }
            return out
        }
    }

    // MARK: Seed choice

    /// A 4 × 4 grid with the cells listed set.
    private func grid(_ cells: Set<Int>) -> MaskGrid {
        MaskGrid(side: 4, cells: (0..<16).map { cells.contains($0) })
    }

    private let body: Set<Int> = [5, 6, 9, 10, 13, 14]

    @Test func aSpillFrameIsNotTheSeed() throws {
        // A steady body on frames 0–19; frame 4 spills onto two more cells; nothing else differs.
        let candidates = (0..<20).map {
            SeedCandidate(frame: $0, grid: grid($0 == 4 ? body.union([7, 11]) : body), face: true, overlap: 0)
        }
        let scores = SeedChoice.scores(candidates, tuning: TrackingTuning())
        let spill = try #require(scores.first { $0.frame == 4 })
        #expect(spill.area == 0, "a third over the median area is past the 0.25 tolerance")
        #expect(scores.filter { $0.frame != 4 }.allSatisfy { $0.total > spill.total })
        // The spill also lowers its neighbours' stability, so the seed lands away from it.
        let best = try #require(SeedChoice.best(candidates, tuning: TrackingTuning()))
        #expect(best.frame == 11, "the first frame whose ±6 window misses the spill")
    }

    @Test func aFaceAndBeingAloneBreakTies() throws {
        let tuning = TrackingTuning()
        let faces = (0..<5).map { SeedCandidate(frame: $0, grid: grid(body), face: $0 == 3, overlap: 0) }
        #expect(SeedChoice.best(faces, tuning: tuning)?.frame == 3)
        let crowded = (0..<5).map { SeedCandidate(frame: $0, grid: grid(body), face: nil, overlap: $0 == 3 ? 0 : 0.6) }
        let best = try #require(SeedChoice.best(crowded, tuning: tuning))
        #expect(best.frame == 3 && best.alone == 1 && best.face == 0.5)
    }

    @Test func stabilityCountsMissingNeighboursAsZero() throws {
        // The target is missing on frames 14–16: frames next to the gap score lower stability than frame 4.
        let candidates = (0..<24).filter { !(14...16).contains($0) }.map {
            SeedCandidate(frame: $0, grid: grid(body), face: false, overlap: 0)
        }
        let scores = SeedChoice.scores(candidates, tuning: TrackingTuning())
        let stability = Dictionary(uniqueKeysWithValues: scores.map { ($0.frame, $0.stability) })
        #expect(stability[4] == 1)
        #expect((stability[13] ?? 1) < 1 && (stability[17] ?? 1) < 1)
        #expect(SeedChoice.best([], tuning: TrackingTuning()) == nil)
    }

    // MARK: Short losses in an accepted shot

    @Test func aShortLossTakesVisionsMaskUnlessVisionMergesPeople() {
        func mask(_ cells: Int, _ key: String) -> TargetMask {
            TargetMask(
                identity: 1, key: key, grid: MaskGrid(side: 10, cells: (0..<100).map { $0 < cells }),
                detection: nil, face: nil)
        }
        // Tracked at area 10 on frames 0–3 and 7–9; lost on 4–6, where Vision has 18 cells (a fast move), 30 (three
        // people merged: over 2.5 × the median of 10) and nothing. Frame 2 also has Vision, and stays tracked.
        let tracked = Dictionary(uniqueKeysWithValues: [0, 1, 2, 3, 7, 8, 9].map { ($0, mask(10, "t1_\($0)")) })
        var vision = [[TargetMask]](repeating: [], count: 10)
        vision[2] = [mask(12, "v2")]
        vision[4] = [mask(18, "v4")]
        vision[5] = [mask(30, "v5")]
        let shot = TargetMasks.filled(tracked: tracked, vision: vision, identity: 1, frames: 0..<10, maxAreaRatio: 2.5)
        #expect(shot.filled == [4], "filled from Vision; not the merge on 5, nothing to fill on 6")
        #expect(shot.masks[4]?.key == "v4")
        #expect(shot.masks[5] == nil && shot.masks[6] == nil, "no tracked mask held over the gap")
        #expect(shot.masks[2]?.key == "t1_2", "a tracked frame keeps the tracked mask")
        let other = TargetMasks.filled(tracked: tracked, vision: vision, identity: 2, frames: 0..<10, maxAreaRatio: 2.5)
        #expect(other.filled.isEmpty, "only the target's own Vision mask")

        let frame = TrackingFlags.Frame(
            frame: 4, mask: shot.masks[4]?.grid, score: nil, visionSees: true, filled: true, others: [])
        #expect(TrackingFlags.reasons(frame, previous: nil, tuning: TrackingTuning().flags) == [.lost])
    }
}
