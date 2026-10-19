import CoreImage
import Vision

/// A square close-up of the face in a character image, sent to Seedance beside the image when the face in it is
/// small. A full-body reference (1024 × 1536) gives the face about 8 % of its height; against Genjutsu with the same
/// image, our face matched it less, and the close-up gives Seedance the face at a size it can copy.
public struct FaceCloseUp: Sendable {
    /// A face at least this share of the image height is large enough as it is: a portrait or a half-body shot.
    public var maxFaceShare: CGFloat = 0.35
    /// The crop's side as a multiple of the face box's longer side: Vision's box stops at the brows and the chin, so
    /// this takes in the hair, the ears and the neck.
    public var scale: CGFloat = 2.2
    /// A face box smaller than this many pixels holds too little to enlarge.
    public var minFace: CGFloat = 64
    /// The close-up's side: a smaller crop is scaled up to `minSide`, a larger one down to `maxSide`, the most
    /// Comfy's upload takes (2048²).
    public var minSide: CGFloat = 1024
    public var maxSide: CGFloat = 2048

    public init() {}

    /// The close-up of the largest face Vision finds in `image`, or nil: no face (a cat, a place), a face too small,
    /// or one already large enough.
    public func closeUp(_ image: CGImage) throws -> CGImage? {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        let faces = (request.results ?? []).map {
            VNImageRectForNormalizedRect($0.boundingBox, image.width, image.height)
        }
        guard let face = faces.max(by: { $0.width * $0.height < $1.width * $1.height }),
            let crop = crop(face: face, in: size)
        else { return nil }
        let side = min(max(crop.width, minSide), maxSide)
        let resize = side / crop.width
        let out = CIImage(cgImage: image).cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: resize])
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext().createCGImage(
            out, from: CGRect(x: 0, y: 0, width: side.rounded(), height: side.rounded()), format: .RGBA8,
            colorSpace: sRGB)
    }

    /// The square to cut around `face` (pixels, bottom-left origin) from an image of `size`, or nil when the face is
    /// large enough already or too small to enlarge. Centred on the face, shifted inside the image at an edge, and
    /// never wider than the image's shorter side, so it holds no padding.
    public func crop(face: CGRect, in size: CGSize) -> CGRect? {
        guard face.height < maxFaceShare * size.height, min(face.width, face.height) >= minFace else { return nil }
        let side = min(max(face.width, face.height) * scale, size.width, size.height).rounded(.down)
        let x = min(max(0, face.midX - side / 2), size.width - side)
        let y = min(max(0, face.midY - side / 2), size.height - side)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: side, height: side)
    }
}
