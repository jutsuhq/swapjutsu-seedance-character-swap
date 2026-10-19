import CoreImage
import CoreML
import Vision

/// A depth map at the model's resolution and the transform that places it on the frame.
public struct DepthMap: @unchecked Sendable {
    /// One-channel half or single float, relative inverse depth.
    public let buffer: CVPixelBuffer
    public let toFrame: CGAffineTransform

    public init(buffer: CVPixelBuffer, toFrame: CGAffineTransform) {
        self.buffer = buffer
        self.toFrame = toFrame
    }

    public var size: CGSize {
        CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }
}

/// Depth Anything V2 Small through Core ML (Apple's conversion), on the Neural Engine where it fits. Returns relative
/// inverse depth: larger is nearer.
///
/// Loading is the slow part: the first load of a model at a new location (or on a new OS version) waits for Core
/// ML to compile it for the Neural Engine (`ANECompilerService`, about 6 s on an idle M4, far longer when another
/// compile is queued), later loads take a fraction of a second. An app loads it once ahead of the first prep and
/// hands the same instance to every run (`PrepStages.standard(tuning:depth:)`).
///
/// `@unchecked Sendable`: the request is used from one task at a time, the depth pass.
public final class DepthAnything: DepthEstimating, @unchecked Sendable {
    private let request: VNCoreMLRequest
    public let inputSize: CGSize?

    public init(modelURL: URL) async throws {
        let model = try await CompiledModel.load(modelURL, units: .all)
        let image = model.modelDescription.inputDescriptionsByName.values.compactMap(\.imageConstraint).first
        inputSize = image.map {
            CGSize(width: max($0.pixelsWide, $0.pixelsHigh), height: min($0.pixelsWide, $0.pixelsHigh))
        }
        do { request = VNCoreMLRequest(model: try VNCoreMLModel(for: model)) } catch {
            throw PrepError.model("\(error)")
        }
        request.imageCropAndScaleOption = .scaleFill
    }

    /// Depth for `frame`, as a one-channel float pixel buffer at the model's resolution plus the transform that
    /// maps it onto the frame. Portrait frames are turned sideways first: the model input is landscape (518 × 392),
    /// and squeezing a 9:16 frame into it distorts people far more than a rotation does.
    public func depth(of frame: CIImage) throws -> DepthMap {
        let input = Self.modelInput(frame)
        try VNImageRequestHandler(ciImage: input).perform([request])
        guard let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw PrepError.model("no depth output")
        }
        let map = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        return DepthMap(buffer: buffer, toFrame: Self.toFrame(frame: frame.extent, map: map))
    }

    /// `frame` as the model sees it: turned sideways when portrait. `frame` has its origin at zero.
    static func modelInput(_ frame: CIImage) -> CIImage {
        let extent = frame.extent
        guard extent.height > extent.width else { return frame }
        return frame.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: -extent.width, y: 0))
    }

    /// From a map of size `map` back onto `frame` (origin at zero), undoing the sideways turn of a portrait frame.
    static func toFrame(frame extent: CGRect, map: CGSize) -> CGAffineTransform {
        let portrait = extent.height > extent.width
        let input = portrait ? CGSize(width: extent.height, height: extent.width) : extent.size
        var toFrame = CGAffineTransform(scaleX: input.width / map.width, y: input.height / map.height)
        if portrait {
            // Undo the sideways turn: input (x, y) came from frame (width - y', x') rotated; rotate back by +90°.
            toFrame = toFrame.concatenating(
                CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: 0, y: -extent.width))
        }
        return toFrame
    }
}
