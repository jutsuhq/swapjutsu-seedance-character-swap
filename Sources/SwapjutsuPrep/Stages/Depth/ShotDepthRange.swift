import Accelerate
import CoreImage

/// The near/far range of the coloured depth, fixed for a whole shot and measured on the target people only:
/// the background never flattens them, and a fixed scale cannot flicker. Per-frame ranges come from the 2nd–98th
/// percentile under each target mask; the shot takes the 10th percentile of the lows and 90th of the highs.
struct ShotDepthRange {
    let low: Float
    let high: Float

    init?(_ ranges: [ClosedRange<Float>]) {
        guard !ranges.isEmpty else { return nil }
        let lows = ranges.map(\.lowerBound).sorted(), highs = ranges.map(\.upperBound).sorted()
        low = lows[lows.count / 10]
        high = max(highs[highs.count * 9 / 10], low + 1e-3)
    }

    /// Mean normalised depth inside the mask, for the flicker metric.
    func meanInside(_ depth: CIImage, mask: MaskGrid, context: CIContext) -> Float {
        let values = depthSamples(depth, mask: mask, context: context)
        guard !values.isEmpty else { return 0 }
        return values.map { min(1, max(0, ($0 - low) / (high - low))) }.reduce(0, +) / Float(values.count)
    }
}

/// 2nd–98th percentile of depth samples (the values under a target mask).
func depthRange(_ samples: [Float]) -> ClosedRange<Float>? {
    var values = samples
    vDSP.sort(&values, sortOrder: .ascending)
    guard values.count >= 16 else { return nil }
    let lo = values[values.count * 2 / 100]
    return lo...max(values[values.count * 98 / 100], lo)
}

/// Depth values under the mask's cells. Rendering through the same CIContext path as `MaskGrid` keeps both grids in
/// the same orientation. `depth` must already be placed on the frame.
func depthSamples(_ depth: CIImage, mask: MaskGrid, context: CIContext) -> [Float] {
    let side = mask.side
    var pixels = [Float](repeating: 0, count: side * side * 4)
    let e = depth.extent
    let fitted =
        depth
        .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / e.width, y: CGFloat(side) / e.height))
    context.render(
        fitted, toBitmap: &pixels, rowBytes: side * 16, bounds: CGRect(x: 0, y: 0, width: side, height: side),
        format: .RGBAf, colorSpace: nil)
    return mask.cells.indices.filter { mask.cells[$0] }.map { pixels[$0 * 4] }
}
