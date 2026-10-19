import CoreImage

/// A tracker that sees each shot turned upright (`Upright`): frames, seeds, corrections, clicks and crops come in the
/// source's frame, are turned before they reach `base`, and the masks are turned back. A shot started without a turn
/// (`startShot(crops:)`) goes through as it is.
public final class UprightTracking: MaskTracking {
    let base: any MaskTracking
    private var upright: Upright?

    public init(_ base: any MaskTracking) { self.base = base }

    public var name: String { base.name }
    public var timings: [String: Double] { base.timings }

    public func startShot(crops: [Int: TrackingCrop]) { startShot(crops: crops, upright: nil) }

    public func startShot(crops: [Int: TrackingCrop], upright: Upright?) {
        self.upright = upright?.isTurned == true ? upright : nil
        guard let turn = self.upright else { return base.startShot(crops: crops) }
        base.startShot(crops: crops.mapValues { turn.upright($0) })
    }

    public func lookahead(_ next: CIImage) { base.lookahead(upright?.upright(next) ?? next) }

    public func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
        try step(frame, seeds: seeds, corrections: [:], pinned: [])
    }

    public func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]]
    ) throws -> [Int: TrackedMask] {
        try step(frame, seeds: seeds, corrections: corrections, pinned: [])
    }

    public func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]], pinned: Set<Int>
    ) throws -> [Int: TrackedMask] {
        guard let turn = upright else {
            return try base.step(frame, seeds: seeds, corrections: corrections, pinned: pinned)
        }
        let found = try base.step(
            turn.upright(frame), seeds: seeds.mapValues(turn.upright(bytes:)),
            corrections: corrections.mapValues(turn.upright(bytes:)), pinned: pinned)
        return found.mapValues { TrackedMask(score: $0.score, mask: $0.mask.map(turn.source(bytes:))) }
    }

    public func mask(at point: CGPoint, on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
        guard let turn = upright else { return try base.mask(at: point, on: frame, crop: crop) }
        return try base.mask(at: turn.upright(topDown: point), on: turn.upright(frame), crop: crop.map(turn.upright))
            .map(turn.source(bytes:))
    }

    public func mask(points: [PromptPoint], on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
        guard let turn = upright else { return try base.mask(points: points, on: frame, crop: crop) }
        let turned = points.map { PromptPoint(turn.upright(topDown: $0.point), positive: $0.positive) }
        return try base.mask(points: turned, on: turn.upright(frame), crop: crop.map(turn.upright))
            .map(turn.source(bytes:))
    }
}
