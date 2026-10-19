import CoreImage
import Foundation

/// A finished prep's target shot re-tracked from the person's corrections (#58) in seconds, without running the prep
/// again: the shot is read from `prepared.mp4` and tracked both ways by `CorrectedTracking`, as the prep will when it
/// runs again with the corrections. The app shows the result before and after; the control video changes only when
/// the prep runs again.
///
/// note: the prep tracks the source clip and this the encoded `prepared.mp4`, so the masks differ by encoding noise;
/// the person sees the same fix, not the same bytes.
public enum CorrectionPreview {
    public struct Request: Sendable {
        public let prep: URL
        /// The shot's frames, `start..<end`.
        public let shot: Int
        public let start: Int
        public let end: Int
        public let identity: Int
        /// The crop the prep tracked the shot in (`Manifest.TrackedShot.crop`); nil: the full frame.
        public let crop: TrackingCrop?
        public let corrections: [TargetCorrection]
        /// The frames whose masks come back; the rest are only tracked through.
        public let keep: Set<Int>
        /// Clockwise degrees the prep turned the shot to track it (`Manifest.Shot.orientation`).
        public let orientation: Int

        public init(
            prep: URL, shot: Int, start: Int, end: Int, identity: Int, crop: TrackingCrop?,
            corrections: [TargetCorrection], keep: Set<Int>, orientation: Int = 0
        ) {
            (self.prep, self.shot, self.start, self.end, self.identity) = (prep, shot, start, end, identity)
            (self.crop, self.corrections, self.keep, self.orientation) = (crop, corrections, keep, orientation)
        }
    }

    /// The kept frames' masks (frame-sized, rows top-down, 0/255; a frame without the target is all 0), with
    /// `progress` told (frames done, frames to do) as the tracker goes.
    public static func run(
        _ request: Request, tracker: any MaskTracking, context: CIContext,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> [Int: [UInt8]] {
        let source = try await VideoSource.open(request.prep.appending(path: "prepared.mp4"), tuning: Tuning())
        let (width, height) = (Int(source.size.width), Int(source.size.height))
        let prompts = try request.corrections.map { c -> CorrectedTracking.Correction in
            switch c.kind {
            case .point(let x, let y):
                return .init(frame: c.frame, prompt: .point(CGPoint(x: x * Double(width), y: y * Double(height))))
            case .mask(let file):
                let bytes = try TargetCorrections.maskBytes(
                    request.prep.appending(path: file), width: width, height: height)
                return .init(frame: c.frame, prompt: .mask(bytes))
            }
        }
        let crop = request.crop.flatMap { crop in
            prompts.allSatisfy { contains(crop, $0.prompt, width: width) } ? crop : nil
        }
        let upright = Upright(degrees: request.orientation, size: source.size)
        let driver = CorrectedTracking(
            tracker: upright.isTurned ? UprightTracking(tracker) : tracker, context: context,
            read: { try await source.forEachFrame(in: $0, $1) }, progress: progress)
        var kept: [Int: [UInt8]] = [:]
        try await driver.run(
            .init(
                index: request.shot, start: request.start, end: request.end, object: request.identity, crop: crop,
                corrections: prompts, upright: upright)
        ) { n, found in
            guard request.keep.contains(n) else { return }
            kept[n] = found.mask.map { $0.map { $0 > 127 ? 255 : 0 } } ?? [UInt8](repeating: 0, count: width * height)
        }
        return kept
    }

    /// Whether a correction lies inside the crop: the click, or every pixel of the mask.
    static func contains(_ crop: TrackingCrop, _ prompt: CorrectedTracking.Prompt, width: Int) -> Bool {
        func inside(_ x: Int, _ y: Int) -> Bool {
            x >= crop.x && x < crop.x + crop.width && y >= crop.y && y < crop.y + crop.height
        }
        switch prompt {
        case .point(let p): return inside(Int(p.x), Int(p.y))
        case .points(let points): return points.allSatisfy { inside(Int($0.point.x), Int($0.point.y)) }
        case .mask(let bytes):
            for (i, v) in bytes.enumerated() where v > 127 && !inside(i % width, i / width) { return false }
            return true
        }
    }
}
