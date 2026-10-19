import Foundation

// Re-seeding the tracker from Vision when it drifts (#13). Vision is often wrong exactly where the tracker drifts
// (it spills onto neighbours, merges people into one blob, loses hair and hands), so a Vision mask only becomes a
// correction when every check below holds; when any fails the correction waits, it never switches the target.

/// Vision's mask of one target on one frame, with what the caller knows about it.
public struct VisionObservation: Sendable {
    public let grid: MaskGrid
    /// A face was found on the target here; nil when the caller cannot tell.
    // swiftlint:disable:next discouraged_optional_boolean
    public let face: Bool?
    /// The largest share of the target's box covered by another person's box; 1 when someone else is on the frame
    /// but the caller does not know where.
    public let overlap: Double
    /// Exactly one detection of the target on this frame, backed by a face or a body, and the target is not one of
    /// a look-alike pair.
    public let unambiguous: Bool

    // swiftlint:disable:next discouraged_optional_boolean
    public init(grid: MaskGrid, face: Bool?, overlap: Double, unambiguous: Bool) {
        (self.grid, self.face, self.overlap, self.unambiguous) = (grid, face, overlap, unambiguous)
    }
}

/// Whether Vision's mask on a frame is trusted enough to re-seed from (`TrackingTuning.Reseed`).
public enum ReseedConfidence {
    /// Why a frame's Vision mask is not trusted; nil when it is.
    public enum Doubt: String, Sendable {
        case missing, ambiguous, crowded, noFace, unstable, areaJump
    }

    /// Each frame of one target in one shot, in frame order (nil where Vision has no mask): nil when confident.
    ///
    /// - The target is unambiguous and alone (box overlap with anyone else at most `maxOverlap`).
    /// - A face, when `requireFace` and the caller knows (`face` nil passes).
    /// - Stable: Vision has the target on the `stabilityFrames` frames before, and each consecutive pair overlaps by
    ///   grid IoU ≥ `minStability`.
    /// - No area jump: the mask's area is within `areaTolerance` of the median of Vision's areas over the
    ///   `areaWindow` frames up to it (a merge with a neighbour or a lost limb shows as a jump).
    public static func doubts(_ frames: [VisionObservation?], tuning: TrackingTuning.Reseed) -> [Doubt?] {
        frames.indices.map { i in
            guard let o = frames[i] else { return .missing }
            guard o.unambiguous else { return .ambiguous }
            guard o.overlap <= tuning.maxOverlap else { return .crowded }
            if tuning.requireFace, o.face == false { return .noFace }
            guard i >= tuning.stabilityFrames else { return .unstable }
            for k in (i - tuning.stabilityFrames)..<i {
                guard let a = frames[k], let b = frames[k + 1], a.grid.iou(b.grid) >= tuning.minStability else {
                    return .unstable
                }
            }
            let areas = frames[max(0, i - tuning.areaWindow + 1)...i].compactMap { $0?.grid.area }.sorted()
            let median = Double(areas[areas.count / 2])
            guard median > 0, abs(Double(o.grid.area) / median - 1) <= tuning.areaTolerance else { return .areaJump }
            return nil
        }
    }
}

/// Watches one object in one tracking direction for drift away from a confident Vision mask.
///
/// A frame counts as drift when Vision is confident there and the tracked mask is missing, or overlaps Vision's by
/// grid IoU under `driftIoU` while covering under `maxVisionCovered` of it. The cover test tells the tracker missing
/// part of the person (hands, a turn) or being elsewhere from Vision missing part (the tracked mask then holds most of
/// Vision's, as on blonde-hair-swap's hair and hand). A Vision mask over `maxAreaRatio` times the tracked area (median
/// of the last `areaWindow` frames) is not drift either: that is Vision merging people (crowd-interaction).
///
/// After `driftFrames` drift frames in a row a correction is due; it is made on the next frame where Vision is
/// confident (`due`), at most once per `cooldown` frames.
struct DriftMonitor: Sendable {
    let tuning: TrackingTuning.Reseed
    private(set) var streak = 0
    private var sinceCorrection = Int.max / 2
    private var trackedAreas: [Int] = []

    init(tuning: TrackingTuning.Reseed) { self.tuning = tuning }

    /// Whether the tracked mask on this frame has drifted from Vision's.
    func drifted(tracked: MaskGrid?, vision: MaskGrid) -> Bool {
        guard vision.area > 0 else { return false }
        let history = (trackedAreas + [tracked?.area].compactMap { $0 }).sorted()
        if !history.isEmpty, Double(vision.area) > tuning.maxAreaRatio * Double(max(1, history[history.count / 2])) {
            return false
        }
        guard let tracked, tracked.area > 0 else { return true }
        var inside = 0
        for k in vision.cells.indices where vision.cells[k] && tracked.cells[k] { inside += 1 }
        return tracked.iou(vision) < tuning.driftIoU && Double(inside) / Double(vision.area) < tuning.maxVisionCovered
    }

    /// One tracked frame; `vision` is nil unless Vision is confident there. A frame without a confident Vision mask
    /// says nothing about drift, so it leaves the streak as it is.
    mutating func observe(tracked: MaskGrid?, vision: MaskGrid?) {
        sinceCorrection += 1
        if let vision { streak = drifted(tracked: tracked, vision: vision) ? streak + 1 : 0 }
        if let area = tracked?.area, area > 0 {
            trackedAreas.append(area)
            if trackedAreas.count > tuning.areaWindow { trackedAreas.removeFirst() }
        }
    }

    /// A correction is due on a frame where Vision is confident.
    func due(confident: Bool) -> Bool {
        confident && streak >= tuning.driftFrames && sinceCorrection > tuning.cooldown
    }

    mutating func corrected() {
        streak = 0
        sinceCorrection = 0
    }
}

/// An object's conditioning frames: its seed and up to `BankLayout.maxCorrections` corrections, oldest first. The
/// seed stays. Automatic corrections (Vision re-seeds, #13) are at most `maxCorrections`; a new one past that, or past
/// the slots, replaces the oldest automatic one. The person's own corrections (#58) are `pinned`: they replace the
/// oldest automatic correction when the slots are full, and only the oldest pinned one when every slot is pinned, so
/// an automatic re-seed never pushes a person's fix out.
struct ConditioningMemory<Entry> {
    struct Conditioning {
        let entry: Entry
        let frame: Int
        let pinned: Bool
    }

    let maxCorrections: Int
    private(set) var entries: [Conditioning]

    init(seed: Entry, frame: Int, maxCorrections: Int) {
        entries = [Conditioning(entry: seed, frame: frame, pinned: true)]
        self.maxCorrections = max(0, min(maxCorrections, BankLayout.maxCorrections))
    }

    var corrections: Int { entries.count - 1 }

    mutating func correct(_ entry: Entry, frame: Int, pinned: Bool = false) {
        let automatic = entries.indices.dropFirst().filter { !entries[$0].pinned }
        if pinned {
            if corrections >= BankLayout.maxCorrections { entries.remove(at: automatic.first ?? 1) }
        } else {
            guard maxCorrections > 0 else { return }
            if automatic.count >= maxCorrections || corrections >= BankLayout.maxCorrections {
                guard let oldest = automatic.first else { return }
                entries.remove(at: oldest)
            }
        }
        entries.append(Conditioning(entry: entry, frame: frame, pinned: pinned))
    }
}

/// Where each memory goes in EdgeTAM's banks: 7 spatial slots and 16 object pointers.
///
/// The conditioning frames (seed, then corrections) take the last spatial slots, the seed in slot 6 and corrections
/// below it, all at the conditioning temporal position 6 as SAM 2 places every conditioning frame. The recent frames
/// take the remaining slots from 0, newest first, at their own temporal positions (`MemoryBank.spatial`). Pointers:
/// conditioning first (seed in slot 0), then the recent frames newest first. With only the seed this is the layout
/// the tracker had before re-seeding.
enum BankLayout {
    static let spatialSlots = 7
    static let pointerSlots = 16
    static let conditioningPosition = 6
    /// The seed plus two corrections leaves four recent spatial slots.
    static let maxCorrections = 2

    enum Source: Equatable {
        case conditioning(Int)
        case recent(Int)
    }

    struct Slot: Equatable {
        let slot: Int
        let source: Source
    }

    /// Spatial slots for `conditioning` conditioning frames and `recent` available recent frames.
    static func spatial(conditioning: Int, recent: Int) -> [Slot] {
        let k = min(conditioning, spatialSlots)
        let cond = (0..<k).map { Slot(slot: spatialSlots - 1 - $0, source: .conditioning($0)) }
        let rec = (0..<min(recent, spatialSlots - k)).map { Slot(slot: $0, source: .recent($0)) }
        return rec + cond
    }

    static func pointers(conditioning: Int, recent: Int) -> [Slot] {
        let k = min(conditioning, pointerSlots)
        let cond = (0..<k).map { Slot(slot: $0, source: .conditioning($0)) }
        let rec = (0..<min(recent, pointerSlots - k)).map { Slot(slot: k + $0, source: .recent($0)) }
        return cond + rec
    }
}

/// Re-seeding for a `TwoWayTracking` run: told every tracked mask, asked before each frame for the corrections due
/// there. Each object and direction has its own `DriftMonitor`.
public final class VisionReseeding {
    let tuning: TrackingTuning.Reseed
    /// Vision's grid of an object (shot, object, frame) and whether it is confident there; nil without a mask.
    let vision: (Int, Int, Int) -> (grid: MaskGrid, confident: Bool)?
    /// Vision's mask bytes of an object (shot, object, frame): frame-sized, rows top-down, inside where > 127.
    let mask: (Int, Int, Int) throws -> [UInt8]
    /// A tracked mask's grid.
    let grid: ([UInt8]) -> MaskGrid
    public struct Correction: Sendable, Equatable {
        public let shot: Int
        public let object: Int
        public let frame: Int
    }

    /// Every correction made, in order.
    public private(set) var corrections: [Correction] = []
    private var monitors: [[Int]: DriftMonitor] = [:]

    public init(
        tuning: TrackingTuning.Reseed, vision: @escaping (Int, Int, Int) -> (grid: MaskGrid, confident: Bool)?,
        mask: @escaping (Int, Int, Int) throws -> [UInt8], grid: @escaping ([UInt8]) -> MaskGrid
    ) {
        (self.tuning, self.vision, self.mask, self.grid) = (tuning, vision, mask, grid)
    }

    private func key(_ s: Int, _ id: Int, _ reverse: Bool) -> [Int] { [s, id, reverse ? 1 : 0] }

    /// Corrections due on frame `n` for the `objects` being tracked there.
    func corrections(shot s: Int, frame n: Int, objects: [Int], reverse: Bool) throws -> [Int: [UInt8]] {
        var out: [Int: [UInt8]] = [:]
        for id in objects {
            let k = key(s, id, reverse)
            guard let monitor = monitors[k], monitor.due(confident: vision(s, id, n)?.confident == true) else {
                continue
            }
            out[id] = try mask(s, id, n)
            monitors[k]?.corrected()
            corrections.append(Correction(shot: s, object: id, frame: n))
        }
        return out
    }

    /// The tracker's mask of an object on frame `n`.
    func observe(shot s: Int, frame n: Int, object id: Int, mask: TrackedMask, reverse: Bool) {
        let k = key(s, id, reverse)
        let seen = vision(s, id, n)
        monitors[k, default: DriftMonitor(tuning: tuning)].observe(
            tracked: mask.mask.map(grid), vision: seen?.confident == true ? seen?.grid : nil)
    }
}
