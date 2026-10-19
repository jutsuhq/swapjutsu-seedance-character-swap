import CoreImage
import Testing

@testable import SwapjutsuPrep

/// Re-seeding from Vision (#13) on synthetic 10 × 10 grids, no Core ML: the drift trigger, Vision's confidence, the
/// overlap veto and the conditioning-slot layout, then the whole loop through `TwoWayTracking` with a stand-in tracker.
struct ReseedingTests {
    /// Cells `x0..<x1` × `y0..<y1` of a 10 × 10 grid.
    private func rect(_ x0: Int, _ x1: Int, _ y0: Int = 2, _ y1: Int = 9) -> MaskGrid {
        MaskGrid(side: 10, cells: (0..<100).map { (x0..<x1).contains($0 % 10) && (y0..<y1).contains($0 / 10) })
    }

    private let person = (2, 6)
    private var body: MaskGrid { rect(2, 6) }

    private func tuning() -> TrackingTuning.Reseed {
        var t = TrackingTuning.Reseed()
        t.enabled = true
        t.cooldown = 4
        return t
    }

    private func observe(_ monitor: inout DriftMonitor, _ tracked: MaskGrid?, _ vision: MaskGrid?, times: Int = 1) {
        for _ in 0..<times { monitor.observe(tracked: tracked, vision: vision) }
    }

    // MARK: Drift trigger

    @Test func driftOnANeighbourIsDueAfterThreeFrames() {
        var monitor = DriftMonitor(tuning: tuning())
        observe(&monitor, body, body, times: 5)
        #expect(!monitor.due(confident: true))
        // The tracker moves to a neighbour of the same size.
        observe(&monitor, rect(6, 10), body, times: 2)
        #expect(!monitor.due(confident: true), "two frames are not enough")
        observe(&monitor, rect(6, 10), body)
        #expect(monitor.due(confident: true))
        #expect(!monitor.due(confident: false), "waits for a confident Vision frame")
    }

    @Test func oneAgreeingFrameResetsTheStreak() {
        var monitor = DriftMonitor(tuning: tuning())
        observe(&monitor, rect(6, 10), body, times: 2)
        observe(&monitor, body, body)
        observe(&monitor, rect(6, 10), body, times: 2)
        #expect(!monitor.due(confident: true))
    }

    @Test func aLostTargetDriftsAndACorrectionWaitsOutTheCooldown() {
        var monitor = DriftMonitor(tuning: tuning())
        observe(&monitor, body, body, times: 3)
        observe(&monitor, nil, body, times: 3)
        #expect(monitor.due(confident: true))
        monitor.corrected()
        observe(&monitor, nil, body, times: 3)
        #expect(!monitor.due(confident: true), "inside the cooldown")
        observe(&monitor, nil, body, times: 2)
        #expect(monitor.due(confident: true))
    }

    @Test func missingHandsDriftButVisionMissingHairDoesNot() {
        let monitor = DriftMonitor(tuning: tuning())
        // The tracker has the torso only: half of Vision's person (orange-jacket's hands).
        #expect(monitor.drifted(tracked: rect(2, 4), vision: body))
        // Vision has the torso only and the tracker the whole person (blonde-hair-swap): Vision is the one missing parts.
        #expect(!monitor.drifted(tracked: body, vision: rect(2, 4)))
    }

    @Test func visionMergingPeopleIsNotDrift() {
        var monitor = DriftMonitor(tuning: tuning())
        observe(&monitor, rect(2, 4, 2, 6), rect(2, 4, 2, 6), times: 5)
        // Vision's mask grows to three people's worth (crowd-interaction's blob) while the tracker keeps its person.
        let blob = rect(0, 10, 0, 10)
        observe(&monitor, rect(2, 4, 2, 6), blob, times: 5)
        #expect(!monitor.due(confident: true))
        #expect(!monitor.drifted(tracked: nil, vision: blob), "nor when the tracker loses its person there")
    }

    // MARK: Confidence

    private func seen(
        // swiftlint:disable:next discouraged_optional_boolean
        _ grid: MaskGrid, face: Bool? = true, overlap: Double = 0, unambiguous: Bool = true
    ) -> VisionObservation {
        VisionObservation(grid: grid, face: face, overlap: overlap, unambiguous: unambiguous)
    }

    @Test func aSteadyAloneFaceIsConfidentAfterTheStabilityFrames() {
        let doubts = ReseedConfidence.doubts(Array(repeating: seen(body), count: 6), tuning: tuning())
        #expect(doubts == [.unstable, .unstable, .unstable, nil, nil, nil])
    }

    @Test func everyDoubtHasItsReason() {
        let t = tuning()
        func last(_ o: VisionObservation?) -> ReseedConfidence.Doubt? {
            ReseedConfidence.doubts(Array(repeating: seen(body), count: 5) + [o], tuning: t).last.flatMap { $0 }
        }
        #expect(last(nil) == .missing)
        #expect(last(seen(body, unambiguous: false)) == .ambiguous)
        #expect(last(seen(body, face: false)) == .noFace)
        #expect(last(seen(body, face: nil)) == nil, "unknown face passes")
        #expect(last(seen(rect(2, 4))) == .unstable, "half the person since the frame before")
    }

    @Test func overlapWithAnotherPersonVetoesTheFrame() {
        let t = tuning()
        let frames = Array(repeating: seen(body), count: 5) + [seen(body, overlap: 0.3), seen(body, overlap: 0.1)]
        let doubts = ReseedConfidence.doubts(frames, tuning: t)
        #expect(doubts[5] == .crowded)
        #expect(doubts[6] == nil, "at the limit")
    }

    @Test func aGradualAreaJumpIsCaught() {
        var t = tuning()
        t.minStability = 0.5
        // Area 28 cells for 20 frames, then 35, 42, 49: each step is stable, the last is 1.75× the median.
        let frames = Array(repeating: seen(rect(2, 6)), count: 20) + [5, 6, 7].map { seen(rect(2, 2 + $0)) }
        let doubts = ReseedConfidence.doubts(frames, tuning: t)
        #expect(doubts[20] == .areaJump && doubts[22] == .areaJump)
    }

    // MARK: Conditioning slots

    @Test func withOnlyTheSeedTheBankIsTheOldOne() {
        let spatial = BankLayout.spatial(conditioning: 1, recent: 6)
        #expect(spatial.map(\.slot) == [0, 1, 2, 3, 4, 5, 6])
        #expect(spatial.last?.source == .conditioning(0))
        #expect(spatial.prefix(6).map(\.source) == (0..<6).map { .recent($0) })
        let pointers = BankLayout.pointers(conditioning: 1, recent: 15)
        #expect(pointers.first == .init(slot: 0, source: .conditioning(0)))
        #expect(pointers.dropFirst().map(\.slot) == Array(1...15))
    }

    @Test func correctionsTakeSlotsBelowTheSeedAndPointersAfterIt() {
        let spatial = BankLayout.spatial(conditioning: 3, recent: 6)
        #expect(spatial.count == 7)
        #expect(spatial.filter { $0.source == .conditioning(0) }.map(\.slot) == [6])
        #expect(spatial.filter { $0.source == .conditioning(1) }.map(\.slot) == [5])
        #expect(spatial.filter { $0.source == .conditioning(2) }.map(\.slot) == [4])
        #expect(spatial.prefix(4).map(\.source) == (0..<4).map { .recent($0) }, "four newest recent frames")
        let pointers = BankLayout.pointers(conditioning: 3, recent: 15)
        #expect(pointers.count == 16)
        #expect(pointers.prefix(3).map(\.source) == [.conditioning(0), .conditioning(1), .conditioning(2)])
        #expect(pointers.last == .init(slot: 15, source: .recent(12)))
        #expect(BankLayout.spatial(conditioning: 3, recent: 2).map(\.slot) == [0, 1, 6, 5, 4], "empty slots 2–3")
    }

    @Test func aThirdCorrectionReplacesTheOldestAndTheSeedStays() {
        var memory = ConditioningMemory(seed: "seed", frame: 0, maxCorrections: 5)
        #expect(memory.maxCorrections == BankLayout.maxCorrections)
        for (n, name) in [(10, "a"), (20, "b"), (30, "c")] { memory.correct(name, frame: n) }
        #expect(memory.entries.map(\.entry) == ["seed", "b", "c"])
        #expect(memory.entries.map(\.frame) == [0, 20, 30])
        var none = ConditioningMemory(seed: "seed", frame: 0, maxCorrections: 0)
        none.correct("a", frame: 1)
        #expect(none.entries.count == 1)
    }

    // MARK: The loop

    /// The person at x 2–6 and their neighbour at 6–10. The tracker jumps to the neighbour on `driftFrom` and stays
    /// there until corrected; Vision has the person on every frame, alone unless `crowded` says otherwise.
    @Test func aDriftedTrackIsCorrectedFromVisionAndRecovers() throws {
        let run = try loop(driftFrom: 8, crowded: [])
        // Frames 8, 9, 10 drift; Vision is confident on 11, so the correction is made there.
        #expect(run.corrections == [11])
        #expect(run.tracked[10] == rect(6, 10))
        #expect(run.tracked[11] == body && run.tracked[19] == body)
    }

    @Test func aCrowdedVisionFrameIsNeverUsedAndTheCorrectionWaits() throws {
        // Someone overlaps the person on frames 11–14: the correction waits for frame 15.
        let run = try loop(driftFrom: 8, crowded: Set(11...14))
        #expect(run.corrections == [15])
        #expect(run.tracked[14] == rect(6, 10))
    }

    @Test func withoutReseedingNothingIsCorrected() throws {
        let run = try loop(driftFrom: 8, crowded: [], enabled: false)
        #expect(run.corrections.isEmpty)
        #expect(run.tracked[19] == rect(6, 10))
    }

    private struct Loop {
        let corrections: [Int]
        let tracked: [Int: MaskGrid]
    }

    private func bytes(_ grid: MaskGrid) -> [UInt8] { grid.cells.map { $0 ? 255 : 0 } }

    private func loop(driftFrom: Int, crowded: Set<Int>, enabled: Bool = true) throws -> Loop {
        let t = tuning()
        let frames = 20
        let observations = (0..<frames).map { seen(body, overlap: crowded.contains($0) ? 0.5 : 0) }
        let doubts = ReseedConfidence.doubts(observations, tuning: t)
        let reseeding = VisionReseeding(
            tuning: t, vision: { _, _, n in (observations[n].grid, doubts[n] == nil) },
            mask: { [self] _, _, _ in bytes(body) }, grid: { MaskGrid(side: 10, cells: $0.map { $0 > 127 }) })
        let tracker = Drifter(drift: bytes(rect(6, 10)), from: driftFrom)
        var tracked: [Int: MaskGrid] = [:]
        let driver = TwoWayTracking(
            tracker: tracker, shots: [.init(start: 0, end: frames, seeds: [1: 0])], backward: false,
            context: CIContext(), seedMask: { [self] _, _, _ in bytes(body) },
            emit: { n, _, _, mask in tracked[n] = mask.mask.map { MaskGrid(side: 10, cells: $0.map { $0 > 127 }) } },
            reseeding: enabled ? reseeding : nil)
        for n in 0..<frames {
            try driver.feed(n, CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 10 + n, height: 2)))
        }
        #expect(tracker.corrected == (enabled ? reseeding.corrections.map(\.frame) : []))
        return Loop(corrections: reseeding.corrections.map(\.frame), tracked: tracked)
    }

    /// Echoes its seed or last correction, except from frame `from` to the next correction, when it has `drift`.
    private final class Drifter: MaskTracking {
        let name = "Drifter"
        let drift: [UInt8]
        let from: Int
        private var mask: [UInt8]?
        private var correctedSinceDrift = false
        private(set) var corrected: [Int] = []

        init(drift: [UInt8], from: Int) { (self.drift, self.from) = (drift, from) }

        func startShot(crops: [Int: TrackingCrop]) { mask = nil }

        func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
            try step(frame, seeds: seeds, corrections: [:])
        }

        func step(_ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
            let n = Int(frame.extent.width) - 10
            if let seed = seeds[1] {
                mask = seed
                return [1: TrackedMask(score: 10, mask: seed)]
            }
            guard let current = mask else { return [:] }
            if let correction = corrections[1] {
                mask = correction
                correctedSinceDrift = true
                corrected.append(n)
                return [1: TrackedMask(score: 10, mask: correction)]
            }
            return [1: TrackedMask(score: 1, mask: n >= from && !correctedSinceDrift ? drift : current)]
        }
    }
}
