import Accelerate
import CoreImage
import Vision

/// What a person looks like in one frame, computed from the pixels inside their mask only, so the background
/// (often the same for everyone in a scene) does not make two people look alike.
public struct Appearance: Sendable {
    /// A unit-length image embedding of the isolated person, compared by Euclidean distance (0…2).
    public let embedding: [Float]?
    /// Hue (12) × saturation (4) × value (4) histogram of the masked pixels, summing to 1.
    public let colour: [Float]

    public init(embedding: [Float]? = nil, colour: [Float]) {
        self.embedding = embedding
        self.colour = colour
    }

    /// 0 for the same look, about 1 for unrelated looks.
    public func distance(to other: Appearance, tuning: Tuning) -> Float {
        let colourTerm = tuning.colourWeight * histogramDistance(colour, other.colour)
        guard let a = embedding, let b = other.embedding, a.count == b.count else {
            return colourTerm / tuning.colourWeight
        }
        return tuning.printWeight * min(1, vDSP.distanceSquared(a, b).squareRoot() / 1.2) + colourTerm
    }
}

/// Vision's generic feature print of the person on neutral grey, plus their clothing colours.
struct MaskedAppearance: AppearanceDescribing {
    let context: CIContext

    func appearance(of frame: CIImage, mask: CIImage, box: CGRect) throws -> Appearance {
        let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: frame.extent)
        let isolated = frame.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: grey, kCIInputMaskImageKey: mask]
        ).cropped(to: box)
        return Appearance(
            embedding: try featurePrint(of: isolated).map(Self.floats),
            colour: colourHistogram(image: frame.cropped(to: box), mask: mask.cropped(to: box), context: context))
    }

    /// The print's vector; Vision's own `computeDistance` is the Euclidean distance between these.
    static func floats(_ print: VNFeaturePrintObservation) -> [Float] {
        guard print.elementType == .float else { return [] }
        return print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

func featurePrint(of image: CIImage) throws -> VNFeaturePrintObservation? {
    let request = VNGenerateImageFeaturePrintRequest()
    try VNImageRequestHandler(ciImage: image).perform([request])
    return request.results?.first
}

func featurePrintDistance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
    var distance: Float = 0
    do { try a.computeDistance(&distance, to: b) } catch { return 2 }
    return distance
}

/// 1 − Bhattacharyya coefficient: 0 for identical histograms, 1 for disjoint ones.
public func histogramDistance(_ a: [Float], _ b: [Float]) -> Float {
    max(0, 1 - zip(a, b).reduce(0) { $0 + ($1.0 * $1.1).squareRoot() })
}

func colourHistogram(image: CIImage, mask: CIImage, context: CIContext) -> [Float] {
    let width = 48, height = 96
    let pixels = renderRGBA(image, width: width, height: height, context: context)
    let coverage = renderRGBA(mask, width: width, height: height, context: context)
    var histogram = [Float](repeating: 0, count: 12 * 4 * 4)
    var total: Float = 0
    for i in stride(from: 0, to: pixels.count, by: 4) where coverage[i] > 127 {
        let (h, s, v) = hsv(Float(pixels[i]) / 255, Float(pixels[i + 1]) / 255, Float(pixels[i + 2]) / 255)
        histogram[min(11, Int(h * 12)) * 16 + min(3, Int(s * 4)) * 4 + min(3, Int(v * 4))] += 1
        total += 1
    }
    return total > 0 ? histogram.map { $0 / total } : histogram
}

func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let high = max(r, g, b), low = min(r, g, b), delta = high - low
    var hue: Float = 0
    if delta > 0 {
        hue = high == r ? (g - b) / delta : high == g ? 2 + (b - r) / delta : 4 + (r - g) / delta
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
    }
    return (hue, high == 0 ? 0 : delta / high, high)
}
