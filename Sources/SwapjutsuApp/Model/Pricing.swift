import Foundation

/// What a Seedance 2.5 edit costs. A draft follows Comfy's bill: a 5 s 480p draft edit with its reference video
/// (direct route) was billed 180 credits, at 211 credits a dollar, so 36 credits a second; the high end leaves 20%
/// for rounding and length.
///
/// Finals use the price badge of ComfyUI's `ByteDance2ReferenceNodeV2` (`comfy_api_nodes/nodes_bytedance.py`):
/// tokens are `floor(perFrame × (24 × seconds + 1))`, and an edit is billed for the clip it renders plus the clip it
/// reads. The badge's range runs from the render alone to both; finals take its top, since that draft's bill
/// ($0.85) landed at the top of the badge's $0.44–0.88 for it.
///
/// note: finals are still the badge, not a bill. A 720p and a 1080p bill from Comfy's transactions would let them
/// follow measured rates like drafts.
enum SeedancePrice {
    static let draftCreditsPerSecond = 36.0
    static let creditsPerDollar = 211.0

    static func estimate(seconds: Double, quality: RenderQuality) -> ClosedRange<Double> {
        let perFrame: Double
        switch quality {
        case .draft:
            let billed = draftCreditsPerSecond * seconds / creditsPerDollar
            return billed...(billed * 1.2)
        // The badge's 854×480 frame; never sent to Seedance, whose 480p is the draft.
        case .final480: perFrame = 400.0
        case .final720: perFrame = 900.0
        case .final1080: perFrame = 2025.0
        }
        let pricePerThousand = quality == .final1080 ? 0.01001 : 0.009152
        func cost(_ seconds: Double) -> Double {
            (perFrame * (24 * seconds + 1)).rounded(.down) / 1000 * pricePerThousand
        }
        let top = cost(2 * seconds)
        return top...top
    }

    /// "~$1.71–2.05", or "~$9.75" for a single figure.
    static func text(_ range: ClosedRange<Double>) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
        let low = range.lowerBound.formatted(format), high = range.upperBound.formatted(format)
        return low == high ? "~$\(low)" : "~$\(low)–\(high)"
    }

    static func text(seconds: Double, quality: RenderQuality) -> String {
        text(estimate(seconds: seconds, quality: quality))
    }

    /// The estimate to the cent, widened outwards: what agents are quoted, and what `maxCost` and the agent budget
    /// are checked against (`upperBound`), so a limit an agent copies from a quote is never a fraction of a cent short.
    static func cents(seconds: Double, quality: RenderQuality) -> ClosedRange<Double> {
        let range = estimate(seconds: seconds, quality: quality)
        return ((range.lowerBound * 100).rounded(.down) / 100)...((range.upperBound * 100).rounded(.up) / 100)
    }

    /// "$2.00".
    static func dollars(_ amount: Double) -> String {
        "$\(amount.formatted(.number.precision(.fractionLength(2))))"
    }
}
