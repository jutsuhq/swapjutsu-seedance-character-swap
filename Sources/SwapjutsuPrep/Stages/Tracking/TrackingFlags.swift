import Foundation

/// A run of frames of one target shot worth a look before rendering (#58), so the person corrects only those.
public struct TrackingFlag: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// The mask's area changed sharply from the frame before: a limb lost or gained, or a jump to someone else.
        case areaJump
        /// The mask covers a large part of another person's mask.
        case overlap
        /// The tracker has no mask while Vision still sees the target; in a tracked shot the render then takes
        /// Vision's mask there (`TrackingFlags.Frame.filled`), unless Vision merges people.
        case lost
        /// The tracker sees the target, but barely (object score near 0).
        case lowScore
    }

    /// The run's first and last frame.
    public let frame: Int
    public let until: Int
    public let reasons: [Reason]

    public init(frame: Int, until: Int, reasons: [Reason]) {
        (self.frame, self.until, self.reasons) = (frame, until, reasons)
    }
}

/// Picks the suspicious frames of one target shot from its final masks (`TrackingTuning.Flags`).
public enum TrackingFlags {
    /// One frame of the shot.
    public struct Frame: Sendable {
        public let frame: Int
        /// The target's mask the render uses; nil or empty when there is none.
        public let mask: MaskGrid?
        /// The tracker's object score, when the tracker made the mask.
        public let score: Float?
        /// Whether Vision has the target on this frame.
        public let visionSees: Bool
        /// Whether `mask` is Vision's standing in for a tracker that lost the target: still flagged `lost`.
        public let filled: Bool
        /// The other people's masks on this frame.
        public let others: [MaskGrid]

        public init(
            frame: Int, mask: MaskGrid?, score: Float?, visionSees: Bool, filled: Bool = false, others: [MaskGrid]
        ) {
            (self.frame, self.mask, self.score, self.visionSees, self.filled, self.others) =
                (frame, mask, score, visionSees, filled, others)
        }
    }

    /// Each frame's reasons, then consecutive flagged frames as one run; the `maxRuns` longest runs, in frame order.
    public static func flags(_ frames: [Frame], tuning: TrackingTuning.Flags) -> [TrackingFlag] {
        struct Run {
            let first: Int
            var last: Int
            var reasons: Set<TrackingFlag.Reason>
        }
        var runs: [Run] = []
        var previous: MaskGrid?
        for f in frames.sorted(by: { $0.frame < $1.frame }) {
            let reasons = reasons(f, previous: previous, tuning: tuning)
            previous = f.mask.flatMap { $0.area > 0 ? $0 : nil }
            guard !reasons.isEmpty else { continue }
            if let last = runs.last, last.last == f.frame - 1 {
                runs[runs.count - 1].last = f.frame
                runs[runs.count - 1].reasons.formUnion(reasons)
            } else {
                runs.append(Run(first: f.frame, last: f.frame, reasons: reasons))
            }
        }
        let kept = runs.enumerated().sorted { a, b in
            let (la, lb) = (a.element.last - a.element.first, b.element.last - b.element.first)
            return la != lb ? la > lb : a.offset < b.offset
        }.prefix(tuning.maxRuns).sorted { $0.offset < $1.offset }
        return kept.map { r in
            TrackingFlag(
                frame: r.element.first, until: r.element.last,
                reasons: TrackingFlag.Reason.allCases.filter(r.element.reasons.contains))
        }
    }

    static func reasons(
        _ f: Frame, previous: MaskGrid?, tuning: TrackingTuning.Flags
    ) -> Set<TrackingFlag.Reason> {
        var out = Set<TrackingFlag.Reason>()
        guard let mask = f.mask, mask.area > 0 else {
            if f.visionSees { out.insert(.lost) }
            return out
        }
        if f.filled { out.insert(.lost) }
        if let previous {
            let (a, b) = (Double(previous.area), Double(mask.area))
            if abs(a - b) / max(a, b) > tuning.areaChange { out.insert(.areaJump) }
        }
        for other in f.others where other.area > 0 {
            var inside = 0
            for k in other.cells.indices where other.cells[k] && mask.cells[k] { inside += 1 }
            if Double(inside) / Double(other.area) > tuning.overlap { out.insert(.overlap) }
        }
        if let score = f.score, score < tuning.minScore { out.insert(.lowScore) }
        return out
    }
}
