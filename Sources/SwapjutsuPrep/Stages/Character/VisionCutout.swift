import CoreImage
import Vision

/// Takes a character image's background away before it goes to Seedance, so the model sees only who to put in.
public protocol BackgroundRemoving: Sendable {
    /// `image` with only its main subject, on plain grey, cropped around it with some room; nil when no clear
    /// subject was found, so the caller keeps the original.
    func cutout(_ image: CGImage) throws -> CGImage?
}

/// Vision's subject lifting (`VNGenerateForegroundInstanceMaskRequest`), the main subject only.
///
/// The subject is the largest instance, favouring the centre, so a pet or a prop at the edge doesn't win. The result
/// has no alpha: Seedance's reference images are flattened, and a transparent background would arrive as black.
public struct VisionCutout: BackgroundRemoving {
    /// Neutral mid grey (#B0B0B0): reads as "no background" and stays away from any skin or clothing extreme.
    public static let backdrop = CIColor(red: 176 / 255, green: 176 / 255, blue: 176 / 255)
    /// Room around the subject, as a share of its box on each side.
    var padding: CGFloat = 0.1
    /// A subject smaller than this share of the image is a stray detection; one larger leaves nothing to remove.
    var coverage: ClosedRange<Double> = 0.02...0.9

    public init() {}

    public func cutout(_ image: CGImage) throws -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        try handler.perform([request, humans, faces])
        guard let observation = request.results?.first,
            let subject = Self.subject(in: observation.instanceMask), coverage.contains(subject.coverage)
        else { return nil }
        // Only a person is cut out: a location or a prop is a reference with its surroundings.
        let people = (humans.results ?? []).map(\.boundingBox) + (faces.results ?? []).map(\.boundingBox)
        guard people.contains(where: { overlap(subject.box, $0) > 0.5 }) else { return nil }
        // Untagged, so the soft edge keeps Vision's values instead of being linearised as gray gamma.
        let mask = CIImage(
            cvPixelBuffer: try observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: subject.label), from: handler),
            options: [.colorSpace: NSNull()])
        let original = CIImage(cgImage: image)
        let extent = original.extent
        let flat = original.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: CIImage(color: Self.backdrop),
                // Squaring the soft edge drops the halo of the old background around hair.
                kCIInputMaskImageKey: fit(mask, to: extent).applyingFilter(
                    "CIGammaAdjust", parameters: ["inputPower": 2]),
            ])
        let box = CGRect(
            x: subject.box.minX * extent.width, y: subject.box.minY * extent.height,
            width: subject.box.width * extent.width, height: subject.box.height * extent.height)
        let crop = Self.frame(box.insetBy(dx: -box.width * padding, dy: -box.height * padding))
        let scale = max(1, 300 / min(crop.width, crop.height))
        let out = flat.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGRect(x: 0, y: 0, width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
        // sRGB: what an upload is read as, whatever the original was tagged.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext().createCGImage(out, from: size, format: .RGBA8, colorSpace: sRGB)
    }

    /// `rect` widened to within Seedance's 1:2.5 aspect (with margin: 1:2), whole pixels. The backdrop is infinite,
    /// so growing past the image edge only adds grey.
    static func frame(_ rect: CGRect) -> CGRect {
        var rect = rect
        if rect.width < rect.height / 2 { rect = rect.insetBy(dx: (rect.width - rect.height / 2) / 2, dy: 0) }
        if rect.height < rect.width / 2 { rect = rect.insetBy(dx: 0, dy: (rect.height - rect.width / 2) / 2) }
        return rect.integral
    }

    struct Subject {
        let label: Int
        /// Unit box, bottom-left origin.
        let box: CGRect
        let coverage: Double
    }

    /// The main instance in Vision's low-resolution label map (0 = background): largest area, weighted towards the
    /// centre.
    static func subject(in labels: CVPixelBuffer) -> Subject? {
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let (width, height) = (CVPixelBufferGetWidth(labels), CVPixelBufferGetHeight(labels))
        let row = CVPixelBufferGetBytesPerRow(labels)
        struct Tally {
            var count = 0
            var distance = 0.0
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        }
        var tallies: [Int: Tally] = [:]
        for y in 0..<height {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width where line[x] != 0 {
                let dx = (Double(x) + 0.5) / Double(width) - 0.5
                let dy = (Double(y) + 0.5) / Double(height) - 0.5
                var t = tallies[Int(line[x]), default: Tally()]
                t.count += 1
                t.distance += (dx * dx + dy * dy).squareRoot()
                (t.minX, t.maxX, t.minY, t.maxY) = (min(t.minX, x), max(t.maxX, x), min(t.minY, y), max(t.maxY, y))
                tallies[Int(line[x])] = t
            }
        }
        // Mean distance from the centre runs 0…0.71; an instance hugging the edge counts about half.
        func score(_ t: Tally) -> Double { Double(t.count) / (1 + 1.4 * t.distance / Double(t.count)) }
        guard let (label, t) = tallies.max(by: { score($0.value) < score($1.value) }) else { return nil }
        let (w, h) = (CGFloat(width), CGFloat(height))
        // Rows run top-down; Core Image's origin is bottom-left.
        let box = CGRect(
            x: CGFloat(t.minX) / w, y: 1 - CGFloat(t.maxY + 1) / h,
            width: CGFloat(t.maxX - t.minX + 1) / w, height: CGFloat(t.maxY - t.minY + 1) / h)
        return Subject(label: label, box: box, coverage: Double(t.count) / Double(width * height))
    }
}
