import Foundation

/// A target's mask on one frame of a shot, as a seed candidate.
public struct SeedCandidate: Sendable {
    public let frame: Int
    public let grid: MaskGrid
    /// A face was found on the target here; nil when the caller cannot tell, which scores 0.5.
    // swiftlint:disable:next discouraged_optional_boolean
    public let face: Bool?
    /// The largest share of the target's box covered by another person's box on this frame; 0 when alone or unknown.
    public let overlap: Double

    // swiftlint:disable:next discouraged_optional_boolean
    public init(frame: Int, grid: MaskGrid, face: Bool?, overlap: Double) {
        (self.frame, self.grid, self.face, self.overlap) = (frame, grid, face, overlap)
    }
}

/// Picks the frame a target is seeded from in a shot (`TrackingTuning`, "Seed choice"), from per-frame terms in 0…1:
///
/// - **face**: 1 with a face, 0 without, 0.5 unknown. A bonus, not a requirement: a back-only shot still seeds.
/// - **area**: 1 at the shot's median mask area, falling linearly to 0 at `seedAreaTolerance` off it.
/// - **stability**: mean grid IoU with the target's masks on the `seedWindow` frames either side inside the shot; a
///   frame without the target there counts 0, so a seed next to a gap or a flicker scores low.
/// - **alone**: 1 − overlap with another person.
///
/// The score is the weighted sum; ties go to the earliest frame. The weights are `TrackingTuning.seedWeights`.
public enum SeedChoice {
    public struct Score: Sendable, Equatable {
        public let frame: Int
        public let face: Double
        public let area: Double
        public let stability: Double
        public let alone: Double
        public let total: Double
    }

    /// Every candidate's score, in frame order.
    public static func scores(_ candidates: [SeedCandidate], tuning: TrackingTuning) -> [Score] {
        let sorted = candidates.sorted { $0.frame < $1.frame }
        guard !sorted.isEmpty else { return [] }
        let areas = sorted.map(\.grid.areaShare).sorted()
        let median = areas[areas.count / 2]
        let byFrame = Dictionary(sorted.map { ($0.frame, $0.grid) }) { a, _ in a }
        let (first, last) = (sorted[0].frame, sorted[sorted.count - 1].frame)
        let w = tuning.seedWeights
        return sorted.map { c in
            let face = c.face.map { $0 ? 1.0 : 0.0 } ?? 0.5
            let off = median > 0 ? abs(c.grid.areaShare / median - 1) : 1
            let area = max(0, 1 - off / tuning.seedAreaTolerance)
            let neighbours = (c.frame - tuning.seedWindow...c.frame + tuning.seedWindow)
                .filter { $0 != c.frame && $0 >= first && $0 <= last }
            let stability =
                neighbours.isEmpty
                ? 0 : neighbours.map { byFrame[$0].map(c.grid.iou) ?? 0 }.reduce(0, +) / Double(neighbours.count)
            let alone = 1 - min(1, max(0, c.overlap))
            let total = w.face * face + w.area * area + w.stability * stability + w.alone * alone
            return Score(frame: c.frame, face: face, area: area, stability: stability, alone: alone, total: total)
        }
    }

    /// The best seed frame, nil without candidates.
    public static func best(_ candidates: [SeedCandidate], tuning: TrackingTuning) -> Score? {
        scores(candidates, tuning: tuning).reduce(nil) { best, s in
            guard let best else { return s }
            return s.total > best.total ? s : best
        }
    }
}
