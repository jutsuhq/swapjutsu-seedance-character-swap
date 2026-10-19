import CoreImage
import CoreVideo
import Foundation

/// Runs a `MaskTracking` tracker over a clip from each object's seed frame in each shot. Frames come in order, once.
///
/// With `backward` on, each object is tracked both ways: backward from its seed to the shot's first frame, then
/// forward from the seed to the shot's last. Each direction is its own sweep from a fresh tracker state
/// (`startShot`), seeded from the same seed mask, so the backward sweep never sees the forward sweep's memory.
/// EdgeTAM gives memory frames relative temporal positions only, and its object pointers have none
/// (`add_tpos_enc_to_obj_ptrs: false`), so going backward is the same propagation over the frames in reverse.
///
/// The backward sweep needs the frames before the seed in reverse, so a shot's frames are copied as they arrive, up
/// to its last seed frame; there both sweeps run over the copies (the forward one from the first seed frame), the
/// copies are dropped, and the forward sweep goes on with the live frames. A seed frame is encoded once per sweep.
///
/// With `backward` off (the default), nothing is held: one forward sweep per shot, each object starting at its seed
/// frame, exactly as the tracker ran before two-way tracking.
///
/// Masks are emitted once per object and frame: going both ways, the seed frame and the frames before it from the
/// backward sweep (frame numbers falling), the frames after it from the forward sweep. A shot whose tracker throws
/// is reported in `failed` and skipped from there on.
///
/// Every frame is stepped with the next one of its sweep handed to the tracker first (`MaskTracking.lookahead`), so
/// the tracker can start on it. A live frame waits for the next one to arrive for that, so its mask comes one frame
/// later; the shot's last frame is stepped as it comes, and `finish` steps a frame still waiting when the clip ends.
public final class TwoWayTracking {
    /// One shot: frames `start..<end`, each object's seed frame there, and the crops it is tracked in.
    public struct Shot: Sendable {
        public let start: Int
        public let end: Int
        public let seeds: [Int: Int]
        public let crops: [Int: TrackingCrop]
        /// The turn that stands the shot upright for the tracker (`UprightTracking`); nil: as filmed.
        public let upright: Upright?

        public init(
            start: Int, end: Int, seeds: [Int: Int], crops: [Int: TrackingCrop] = [:], upright: Upright? = nil
        ) {
            (self.start, self.end, self.seeds, self.crops, self.upright) = (start, end, seeds, crops, upright)
        }
    }

    let tracker: any MaskTracking
    let shots: [Shot]
    let backward: Bool
    let context: CIContext
    /// The seed mask of an object (shot, object, frame): frame-sized bytes, rows top-down, inside where > 127.
    let seedMask: (Int, Int, Int) throws -> [UInt8]
    /// Each mask as it comes: (frame, shot, object, mask).
    let emit: (Int, Int, Int, TrackedMask) throws -> Void
    /// Re-seeds drifting objects from Vision (#13); nil: never.
    let reseeding: VisionReseeding?
    /// Shots whose tracker threw, with the error.
    public private(set) var failed: [Int: String] = [:]
    /// The most frames held at once.
    public private(set) var peakHeldFrames = 0

    // note: the backward sweep holds a copy of every frame from the shot's start to its last seed, about 1.7 MB a
    // frame at 854 × 480 (measured: +404 MB for 240 frames), so a 30 s shot seeded at its end needs about 1.2 GB.
    // Only `chooseSeed` (off) takes this path. A corrected shot (#58) goes through `CorrectedTracking`, which
    // re-decodes the shot backward in chunks instead; that is the upgrade path here too.
    private var held: [Int: CIImage] = [:]
    private var shot = -1
    /// A live frame waiting for the next one, to be its lookahead.
    private var waiting: Live?

    private struct Live {
        let shot: Int
        let n: Int
        let frame: CIImage
    }

    public init(
        tracker: any MaskTracking, shots: [Shot], backward: Bool, context: CIContext,
        seedMask: @escaping (Int, Int, Int) throws -> [UInt8],
        emit: @escaping (Int, Int, Int, TrackedMask) throws -> Void, reseeding: VisionReseeding? = nil
    ) {
        self.reseeding = reseeding
        self.tracker = tracker
        self.shots = shots
        self.backward = backward
        self.context = context
        self.seedMask = seedMask
        self.emit = emit
    }

    /// The clip's next frame, `n`. Frames outside every shot are ignored.
    public func feed(_ n: Int, _ frame: CIImage) throws {
        guard let s = shots.firstIndex(where: { $0.start <= n && n < $0.end }) else { return }
        let info = shots[s]
        if s != shot {
            try finish()
            held = [:]
            shot = s
            if !backward { tracker.startShot(crops: info.crops, upright: info.upright) }
        }
        guard failed[s] == nil, let first = info.seeds.values.min(), let last = info.seeds.values.max() else { return }
        guard backward else {
            if n >= first { try live(s, n, frame) }
            return
        }
        if n < last {
            held[n] = try ownedCopy(frame, context: context)
            peakHeldFrames = max(peakHeldFrames, held.count)
            return
        }
        try guarded(s) {
            if n == last {
                held[n] = frame
                try sweep(s, frames: Array((info.start...last).reversed()), reverse: true)
                try sweep(s, frames: Array(first...last), reverse: false)
                held = [:]
            } else {
                try live(s, n, frame)
            }
        }
    }

    /// Steps the live frame still waiting for the next one, if any. Call once after the clip's last frame.
    public func finish() throws {
        guard let w = waiting else { return }
        waiting = nil
        if failed[w.shot] == nil { try guarded(w.shot) { try step(w.shot, w.n, w.frame) } }
    }

    /// A live frame: steps the one waiting with this one as its lookahead, then waits in its place (but for the
    /// shot's last frame, stepped now).
    private func live(_ s: Int, _ n: Int, _ frame: CIImage) throws {
        if let w = waiting {
            waiting = nil
            tracker.lookahead(frame)
            try guarded(w.shot) { try step(w.shot, w.n, w.frame) }
        }
        waiting = Live(shot: s, n: n, frame: frame)
        if n == shots[s].end - 1 { try finish() }
    }

    /// One direction over held frames, from a fresh tracker state.
    private func sweep(_ s: Int, frames: [Int], reverse: Bool) throws {
        tracker.startShot(crops: shots[s].crops, upright: shots[s].upright)
        for (i, n) in frames.enumerated() {
            guard let frame = held[n] else { continue }
            if i + 1 < frames.count, let next = held[frames[i + 1]] { tracker.lookahead(next) }
            try autoreleasepool { try step(s, n, frame, reverse: reverse) }
        }
    }

    /// One frame of a sweep: seeds the objects whose seed frame it is, emits the masks this direction owns. A reverse
    /// sweep owns each object's seed frame and the frames before it, a forward one the frames after the seed (and
    /// the seed too when there is no reverse sweep). Corrections due on the frame (`reseeding`) go in with the seeds,
    /// and every mask the sweep tracks is shown to `reseeding`.
    private func step(_ s: Int, _ n: Int, _ frame: CIImage, reverse: Bool = false) throws {
        let seeds = shots[s].seeds
        var seedBytes: [Int: [UInt8]] = [:]
        for (id, f) in seeds.sorted(by: { $0.key < $1.key }) where f == n { seedBytes[id] = try seedMask(s, id, n) }
        let tracked = seeds.filter { reverse ? n < $0.value : n > $0.value }.keys.sorted()
        let corrections =
            try reseeding?.corrections(shot: s, frame: n, objects: tracked, reverse: reverse) ?? [:]
        let found = try tracker.step(frame, seeds: seedBytes, corrections: corrections)
        for (id, mask) in found.sorted(by: { $0.key < $1.key }) {
            guard let f = seeds[id] else { continue }
            reseeding?.observe(shot: s, frame: n, object: id, mask: mask, reverse: reverse)
            let owned = reverse ? n <= f : backward ? n > f : n >= f
            if owned { try emit(n, s, id, mask) }
        }
    }

    /// Runs `body`, recording a throw as the shot's failure; cancellation goes on up.
    private func guarded(_ s: Int, _ body: () throws -> Void) throws {
        do { try body() } catch {
            if error is CancellationError { throw error }
            failed[s] = "\(error)"
            held = [:]
        }
    }

}

/// A copy of the frame in memory of its own, so the decoder's buffer goes back to its pool.
func ownedCopy(_ frame: CIImage, context: CIContext) throws -> CIImage {
    let e = frame.extent
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, Int(e.width), Int(e.height), kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard let buffer else { throw PrepError.model("no pixel buffer for a held frame") }
    context.render(frame.transformed(by: .init(translationX: -e.minX, y: -e.minY)), to: buffer)
    return CIImage(cvPixelBuffer: buffer)
}
