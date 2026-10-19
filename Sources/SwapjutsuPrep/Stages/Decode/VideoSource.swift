import AVFoundation
import CoreImage

/// The source clip resampled to the working frame rate and size: upright, even dimensions, longest side ≤ maxSide,
/// and never under Seedance's minimum frame area (a small or very wide clip is scaled up to it).
public struct VideoSource: Sendable {
    public let url: URL
    public let size: CGSize
    public let frameCount: Int
    public let fps: Int32
    public let sourceDuration: Double
    public let hasAudio: Bool
    /// The working size is larger than the source: Seedance rejects reference videos under `Tuning.minPixels`.
    public let upscaled: Bool
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let sourceFPS: Float

    public static func open(_ url: URL, tuning: Tuning) async throws -> VideoSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PrepError.noVideoTrack(url)
        }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let upright = CGRect(origin: .zero, size: natural).applying(transform).size
        let w = abs(upright.width), h = abs(upright.height)
        var scale = min(1, tuning.maxSide / max(w, h))
        // Seedance rejects frames under minPixels; a small or very wide clip goes up to it, past maxSide if needed.
        let minScale = (tuning.minPixels / max(1, w * h)).squareRoot()
        let upscaled = scale < minScale
        scale = max(scale, minScale)
        let even = { (side: CGFloat) in ((side * scale) / 2).rounded(upscaled ? .up : .down) * 2 }
        let size = CGSize(width: even(w), height: even(h))
        let used = min(duration, tuning.maxSeconds)
        return VideoSource(
            url: url, size: size, frameCount: Int((used * Double(tuning.fps)).rounded(.down)),
            fps: tuning.fps, sourceDuration: duration, hasAudio: hasAudio, upscaled: upscaled, naturalSize: natural,
            transform: transform, sourceFPS: rate)
    }

    public var duration: Double { Double(frameCount) / Double(fps) }

    /// Calls `body` once per working frame, in order. Each output frame is the latest source frame at or before
    /// its timestamp, so 25/30/60 fps sources map onto 24 fps without blending. Stops with `CancellationError` when
    /// the task is cancelled.
    public func forEachFrame(_ body: (Int, CIImage) throws -> Void) async throws {
        try await forEachFrame(in: 0..<frameCount, body)
    }

    /// As `forEachFrame(_:)` for the working frames in `range` only, the same frames as a full pass gives them. A
    /// range that does not start at the first frame is read from half a second before it (`AVAssetReader.timeRange`),
    /// so the source frame at or before its first frame is there; the rest of the clip is not decoded.
    public func forEachFrame(in range: Range<Int>, _ body: (Int, CIImage) throws -> Void) async throws {
        let range = range.clamped(to: 0..<frameCount)
        guard !range.isEmpty else { return }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PrepError.noVideoTrack(url)
        }
        let reader = try AVAssetReader(asset: asset)
        if range != 0..<frameCount {
            let start = max(0, Double(range.lowerBound) / Double(fps) - 0.5)
            let end = Double(range.upperBound) / Double(fps) + 0.5
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        }
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw PrepError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        defer { reader.cancelReading() }
        let samples = SampleQueue(output)

        var emitted = range.lowerBound
        var previous: CIImage?
        func emit(until time: Double) throws {
            while emitted < range.upperBound, Double(emitted) / Double(fps) < time, let frame = previous {
                try Task.checkCancellation()
                try autoreleasepool { try body(emitted, frame) }
                emitted += 1
            }
        }
        while emitted < range.upperBound, let sample = await samples.next() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try emit(until: pts)
            previous = upright(CIImage(cvPixelBuffer: buffer))
        }
        try emit(until: .infinity)
        if reader.status == .failed { throw PrepError.readFailed(reader.error?.localizedDescription ?? "unknown") }
    }

    /// Applies the track's rotation and scales to the working size, with the origin at zero.
    private func upright(_ image: CIImage) -> CIImage {
        let rotated = image.transformed(by: transform)
        let moved = rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        let scaled = moved.transformed(
            by: CGAffineTransform(
                scaleX: size.width / moved.extent.width,
                y: size.height / moved.extent.height))
        return scaled.cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// A reader output whose `copyNextSampleBuffer` runs on a queue of its own, awaited from the task. The call blocks
/// until the decoder hands a sample over, and the decoder needs a free Swift concurrency pool thread to get there:
/// with every pool thread blocked in it (as many readers as cores, a few preps at once) no reader ever returns.
/// Awaited, a reader only suspends its task and leaves the pool thread free.
public final class SampleQueue: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let queue = DispatchQueue(label: "SwapjutsuPrep.decode", autoreleaseFrequency: .workItem)

    public init(_ output: AVAssetReaderOutput) { self.output = output }

    public func next() async -> CMSampleBuffer? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.output.copyNextSampleBuffer()) }
        }
    }
}
