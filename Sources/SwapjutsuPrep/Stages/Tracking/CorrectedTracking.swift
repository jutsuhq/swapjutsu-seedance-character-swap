import CoreImage
import Foundation

/// Re-tracks one target through one shot from a person's corrections (#58), both ways, in place of Vision's seed.
///
/// The earliest correction is the seed: a backward sweep from it to the shot's first frame, then a forward sweep from
/// it to the shot's last, each from a fresh tracker state as in `TwoWayTracking`. The later corrections are pinned
/// conditioning frames where the forward sweep reaches them (`ConditioningMemory`): they outrank Vision re-seeds,
/// which still run on the other frames while a slot is free for them.
///
/// Frames come from `read`, a decoder over a range of the clip, so nothing outside the shot is decoded. The backward
/// sweep reads the shot backward in chunks of `chunk` frames, each chunk decoded forward, copied, and stepped in
/// reverse, so it holds at most `chunk` frames whatever the shot's length; the forward sweep steps the decoded
/// frames as they come, each once the next has arrived, to hand that to the tracker first (`lookahead`), as every
/// held frame is stepped after its next one is handed over.
///
/// Nothing here is about people: `Shot.object` is any tracker object id, so a later stage can track an object the
/// person clicked (an occluder for `ForegroundMasking`, a door, a mic) through its shot the same way.
public final class CorrectedTracking {
    /// One correction, as the tracker takes it.
    public enum Prompt: Sendable {
        /// Frame-sized bytes, rows top-down, inside where > 127.
        case mask([UInt8])
        /// One click on the target, frame pixels, rows top-down.
        case point(CGPoint)
        /// Clicks on the target and off it (`PromptPoint`), for a tracker that takes them (`mask(points:)`).
        case points([PromptPoint])
    }

    /// A correction on one frame.
    public struct Correction: Sendable {
        public let frame: Int
        public let prompt: Prompt
        public init(frame: Int, prompt: Prompt) { (self.frame, self.prompt) = (frame, prompt) }
    }

    /// One target in one shot: frames `start..<end`, its crop, and its corrections.
    public struct Shot: Sendable {
        public let index: Int
        public let start: Int
        public let end: Int
        public let object: Int
        public let crop: TrackingCrop?
        public let corrections: [Correction]
        /// The turn that stands the shot upright for the tracker (`UprightTracking`); nil: as filmed.
        public let upright: Upright?

        public init(
            index: Int, start: Int, end: Int, object: Int, crop: TrackingCrop?, corrections: [Correction],
            upright: Upright? = nil
        ) {
            (self.index, self.start, self.end, self.object, self.crop) = (index, start, end, object, crop)
            self.upright = upright
            self.corrections = corrections.filter { $0.frame >= start && $0.frame < end }.sorted { $0.frame < $1.frame }
        }
    }

    public typealias Reader = (Range<Int>, (Int, CIImage) throws -> Void) async throws -> Void

    let tracker: any MaskTracking
    let context: CIContext
    let read: Reader
    let chunk: Int
    let reseeding: VisionReseeding?
    /// Frames stepped and frames to step, after each step.
    let progress: (Int, Int) -> Void
    /// The most frames held at once.
    public private(set) var peakHeldFrames = 0
    /// The masks the corrections became, by frame (a click's mask from the initializer).
    public private(set) var correctionMasks: [Int: [UInt8]] = [:]

    public init(
        tracker: any MaskTracking, context: CIContext, read: @escaping Reader, chunk: Int = 24,
        reseeding: VisionReseeding? = nil, progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        (self.tracker, self.context, self.read, self.chunk) = (tracker, context, read, max(1, chunk))
        (self.reseeding, self.progress) = (reseeding, progress)
    }

    /// Tracks the shot and hands each frame's mask to `emit` (frame, mask): the seed frame and the frames before it
    /// from the backward sweep (frame numbers falling), the frames after it from the forward one.
    public func run(_ shot: Shot, emit: (Int, TrackedMask) throws -> Void) async throws {
        guard let first = shot.corrections.first else { return }
        let crops = shot.crop.map { [shot.object: $0] } ?? [:]
        // Clicks resolve on the shot's turn too.
        tracker.startShot(crops: crops, upright: shot.upright)
        var masks: [Int: [UInt8]] = [:]
        for c in shot.corrections where masks[c.frame] == nil {
            let mask = try await resolve(c, shot: shot)
            guard mask.contains(where: { $0 > 127 }) else {
                throw PrepError.model("the correction on frame \(c.frame) has an empty mask")
            }
            masks[c.frame] = mask
        }
        correctionMasks = masks
        seedFrame = first.frame
        let total = (first.frame - shot.start + 1) + (shot.end - first.frame)
        var done = 0

        // Backward, chunk by chunk.
        tracker.startShot(crops: crops, upright: shot.upright)
        var high = first.frame
        while high >= shot.start {
            let low = max(shot.start, high - chunk + 1)
            var held: [(Int, CIImage)] = []
            try await read(low..<(high + 1)) { n, frame in held.append((n, try ownedCopy(frame, context: context))) }
            peakHeldFrames = max(peakHeldFrames, held.count)
            let backward = Array(held.reversed())
            for (i, (n, frame)) in backward.enumerated() {
                if i + 1 < backward.count { tracker.lookahead(backward[i + 1].1) }
                try autoreleasepool {
                    try step(shot, n, frame, reverse: true, emit: emit)
                }
                done += 1
                progress(done, total)
            }
            high = low - 1
        }

        // Forward from the seed.
        tracker.startShot(crops: crops, upright: shot.upright)
        var waiting: (n: Int, frame: CIImage)?
        func stepWaiting() throws {
            guard let w = waiting else { return }
            waiting = nil
            try step(shot, w.n, w.frame, reverse: false, emit: emit)
            done += 1
            progress(done, total)
        }
        try await read(first.frame..<shot.end) { n, frame in
            if waiting != nil { tracker.lookahead(frame) }
            try stepWaiting()
            waiting = (n, frame)
        }
        try stepWaiting()
    }

    private var pinnedSoFar = 0
    private var seedFrame = 0

    private func step(
        _ shot: Shot, _ n: Int, _ frame: CIImage, reverse: Bool, emit: (Int, TrackedMask) throws -> Void
    ) throws {
        let (seed, masks) = (seedFrame, correctionMasks)
        let id = shot.object
        if n == seed { pinnedSoFar = 0 }
        let seeds = n == seed ? [id: masks[seed] ?? []] : [:]
        var corrections: [Int: [UInt8]] = [:]
        var pinned = Set<Int>()
        if n != seed, !reverse, let mask = masks[n] {
            corrections[id] = mask
            pinned.insert(id)
            pinnedSoFar += 1
        } else if n != seed, pinnedSoFar < BankLayout.maxCorrections {
            corrections = try reseeding?.corrections(shot: shot.index, frame: n, objects: [id], reverse: reverse) ?? [:]
        }
        let found = try tracker.step(frame, seeds: seeds, corrections: corrections, pinned: pinned)
        guard let mask = found[id] else { return }
        reseeding?.observe(shot: shot.index, frame: n, object: id, mask: mask, reverse: reverse)
        if reverse ? n <= seed : n > seed { try emit(n, mask) }
    }

    /// A correction's mask: as given, or the tracker's mask for the click on its frame.
    private func resolve(_ c: Correction, shot: Shot) async throws -> [UInt8] {
        switch c.prompt {
        case .mask(let bytes): return bytes
        case .point(let point):
            var mask: [UInt8]?
            try await read(c.frame..<(c.frame + 1)) { _, frame in
                mask = try tracker.mask(at: point, on: frame, crop: shot.crop)
            }
            guard let mask else {
                throw PrepError.model("\(tracker.name) takes no click on frame \(c.frame)")
            }
            return mask
        case .points(let points):
            var mask: [UInt8]?
            try await read(c.frame..<(c.frame + 1)) { _, frame in
                mask = try tracker.mask(points: points, on: frame, crop: shot.crop)
            }
            guard let mask else {
                throw PrepError.model("\(tracker.name) takes no \(points.count)-point prompt on frame \(c.frame)")
            }
            return mask
        }
    }
}
