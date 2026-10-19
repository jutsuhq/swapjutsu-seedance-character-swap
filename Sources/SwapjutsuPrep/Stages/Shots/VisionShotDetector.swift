import CoreImage
import Vision

/// Vision: a cut is a jump in the whole-frame feature print or in the colour histogram.
struct VisionShotDetector: ShotDetecting {
    let tuning: Tuning
    let context: CIContext
    private var previous: (VNFeaturePrintObservation?, [Float])?

    init(tuning: Tuning, context: CIContext) {
        self.tuning = tuning
        self.context = context
    }

    mutating func isCut(_ frame: CIImage) throws -> Bool {
        let current = (try featurePrint(of: frame), Self.histogram(frame, context: context))
        defer { previous = current }
        guard let previous else { return false }
        if histogramDistance(previous.1, current.1) > tuning.cutColour { return true }
        guard let a = previous.0, let b = current.0 else { return false }
        return featurePrintDistance(a, b) > tuning.cutDistance
    }

    /// 8 × 8 × 8 RGB histogram of the frame at 64 × 64.
    static func histogram(_ frame: CIImage, context: CIContext) -> [Float] {
        let pixels = renderRGBA(frame, width: 64, height: 64, context: context)
        var bins = [Float](repeating: 0, count: 512)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            bins[Int(pixels[i]) / 32 * 64 + Int(pixels[i + 1]) / 32 * 8 + Int(pixels[i + 2]) / 32] += 1 / 4096
        }
        return bins
    }
}
