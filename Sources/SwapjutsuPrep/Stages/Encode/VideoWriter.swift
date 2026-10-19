import AVFoundation
import CoreImage

/// Writes CIImage frames as H.264 on the hardware encoder.
public final class VideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context: CIContext
    private let fps: Int32
    private let size: CGSize
    private var index: Int64 = 0
    let url: URL

    public init(url: URL, size: CGSize, fps: Int32, context: CIContext) throws {
        try? FileManager.default.removeItem(at: url)
        self.url = url
        self.size = size
        self.fps = fps
        self.context = context
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                // No B-frames: with reordering the first frame decodes two frames early, and that offset lands in
                // the last sample's duration, so the track runs a few frames long and Seedance reads it below 24 fps.
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(size.width * size.height * 12),
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        guard writer.startWriting() else { throw PrepError.writeFailed(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
    }

    public func append(_ image: CIImage) throws {
        try waitUntilReady(input, of: writer)
        guard let pool = adaptor.pixelBufferPool else { throw PrepError.writeFailed("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw PrepError.writeFailed("no pixel buffer") }
        context.render(
            image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: index, timescale: fps)) else {
            throw PrepError.writeFailed(writer.error?.localizedDescription ?? "append")
        }
        index += 1
    }

    /// Drops the file; for a run that failed or was cancelled.
    public func cancel() {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }

    public func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw PrepError.writeFailed(writer.error?.localizedDescription ?? "finish") }
    }
}

/// Blocks until `input` takes more data. Throws when the writer failed, the task was cancelled, or nothing moved for
/// `timeout` seconds, instead of spinning forever on a dead encoder.
func waitUntilReady(_ input: AVAssetWriterInput, of writer: AVAssetWriter, timeout: TimeInterval = 20) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !input.isReadyForMoreMediaData {
        if writer.status == .failed {
            throw PrepError.writeFailed(writer.error?.localizedDescription ?? "encoder failed")
        }
        try Task.checkCancellation()
        guard Date() < deadline else { throw PrepError.writeFailed("the encoder stopped taking frames") }
        Thread.sleep(forTimeInterval: 0.002)
    }
}
