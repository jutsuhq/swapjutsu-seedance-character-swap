import CoreImage
import Foundation

/// The colour of a shot's hands, sampled from the hands themselves, so a hybrid control shows the footage on their
/// skin only: a mask drawn from the joints, or tracked, also takes in the cuff and the pocket around the hand, and
/// Seedance redraws those as rings and patches on the new outfit. Skin is told apart by its hue, the angle of its
/// chroma (Cb, Cr), which light and shade change little: a hand and a cuff of a similar colour can lie some 20°
/// apart though their Cb and Cr each differ by a dozen levels or less. Grey and white (little chroma) and shadow
/// (much darker than the hand) are not skin either.
struct HandSkin: Equatable {
    /// A pixel as Y, Cb, Cr in 0–255 (BT.601).
    struct Pixel: Equatable {
        var y: Float
        var cb: Float
        var cr: Float
    }

    /// Degrees, Cb right and Cr up from (128, 128).
    var hue: Float
    var hueSpread: Float
    var chroma: Float
    var luma: Float

    /// How far from the hand's hue, in spreads, a pixel is still skin.
    static let reach: Float = 2.5
    /// The hue spread's bounds in degrees: one hand's samples can agree too closely to allow its own shading, or,
    /// with the cuff in them, too loosely to keep the cuff out.
    static let spreads: ClosedRange<Float> = 3...6
    /// Less chroma than this share of the hand's is grey or white; darker than this share of its luma, shadow.
    static let palest: Float = 0.35
    static let darkest: Float = 0.45

    init(hue: Float, hueSpread: Float, chroma: Float, luma: Float) {
        (self.hue, self.hueSpread, self.chroma, self.luma) = (hue, hueSpread, chroma, luma)
    }

    /// The median hue, chroma and luma of `samples` (Y, Cb, Cr triples), the hue's spread from its median absolute
    /// deviation, robust to the cuff or pocket pixels a drawn hand also covers; nil under 16 samples.
    init?(samples: [Pixel]) {
        guard samples.count >= 16 else { return nil }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        let hues = samples.map(Self.hue)
        let middle = median(hues)
        hue = middle
        hueSpread = min(
            Self.spreads.upperBound, max(Self.spreads.lowerBound, 1.4826 * median(hues.map { abs($0 - middle) })))
        chroma = median(samples.map(Self.chroma))
        luma = median(samples.map(\.y))
    }

    /// The pixels of `rgba` (rows top-down, 4 bytes each) under `mask` at full strength: the hand's colour.
    static func samples(rgba: [UInt8], mask: [UInt8], stride step: Int = 2) -> [Pixel] {
        Swift.stride(from: 0, to: mask.count, by: step).compactMap { k in
            mask[k] >= 250 ? ycc(rgba, k) : nil
        }
    }

    func isSkin(_ p: Pixel) -> Bool {
        Self.angle(Self.hue(p), hue) <= Self.reach * hueSpread && Self.chroma(p) >= Self.palest * chroma
            && p.y >= Self.darkest * luma
    }

    /// Degrees between two hues, the short way round.
    static func angle(_ a: Float, _ b: Float) -> Float { abs(remainder(a - b, 360)) }

    static func hue(_ p: Pixel) -> Float { atan2(p.cr - 128, p.cb - 128) * 180 / .pi }

    static func chroma(_ p: Pixel) -> Float { hypot(p.cr - 128, p.cb - 128) }

    /// `region` kept where `frame` is skin (`isSkin`), else black, on the GPU: the frame's sRGB values turned so the
    /// hand's hue lies along one axis (u) and its perpendicular (v), each test a linear one in them. Within the hue's
    /// reach θ is |v| ≤ u·tan θ; u ≥ the least chroma stands for the chroma test, since u is the chroma times the
    /// cosine of a hue difference of at most 15°.
    func mask(_ region: CIImage, frame: CIImage) -> CIImage {
        let extent = frame.extent
        let angle = Double(hue) * .pi / 180, reach = tan(Double(Self.reach * hueSpread) * .pi / 180)
        // Rows of (r, g, b) → Y, Cb − 128, Cr − 128 in 0–255 for sRGB values in 0…1 (BT.601).
        let y = SIMD3(0.299, 0.587, 0.114) * 255
        let cb = SIMD3(-0.1687, -0.3313, 0.5) * 255, cr = SIMD3(0.5, -0.4187, -0.0813) * 255
        let u = cos(angle) * cb + sin(angle) * cr, v = -sin(angle) * cb + cos(angle) * cr
        // Each test as a value ≥ 0 where it holds, scaled so the clamp makes it 1, and 0 a fraction of a level below.
        let steep = 1000.0
        let vector = { (w: SIMD3<Double>) in CIVector(x: steep * w.x, y: steep * w.y, z: steep * w.z, w: 0) }
        let tests = {
            (r: SIMD3<Double>, rBias: Double, g: SIMD3<Double>, gBias: Double, b: SIMD3<Double>, bBias: Double) in
            frame.applyingFilter("CILinearToSRGBToneCurve").applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": vector(r), "inputGVector": vector(g), "inputBVector": vector(b),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(
                        x: steep * rBias + 1, y: steep * gBias + 1, z: steep * bBias + 1, w: 1),
                ]
            ).applyingFilter("CIColorClamp")
        }
        let hueTests = tests(reach * u - v, 0, reach * u + v, 0, u, -Double(Self.palest * chroma))
        let dark = -Double(Self.darkest * luma)
        let lumaTest = tests(y, dark, y, dark, y, dark)
        let skin = hueTests.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: lumaTest])
            .applyingFilter("CIMinimumComponent")
        return region.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: skin])
            .cropped(to: extent)
    }

    /// Pixel `k` of `rgba`.
    static func ycc(_ rgba: [UInt8], _ k: Int) -> Pixel {
        let (r, g, b) = (Float(rgba[4 * k]), Float(rgba[4 * k + 1]), Float(rgba[4 * k + 2]))
        return Pixel(
            y: 0.299 * r + 0.587 * g + 0.114 * b, cb: 128 - 0.1687 * r - 0.3313 * g + 0.5 * b,
            cr: 128 + 0.5 * r - 0.4187 * g - 0.0813 * b)
    }

    /// `mask` grown by `radius` pixels each way, a square max filter, on the GPU.
    static func grown(_ mask: CIImage, by radius: Int) -> CIImage {
        guard radius > 0 else { return mask }
        let side = 2 * radius + 1
        return mask.applyingFilter(
            "CIMorphologyRectangleMaximum", parameters: ["inputWidth": side, "inputHeight": side]
        ).cropped(to: mask.extent)
    }

    /// `mask` (rows top-down) grown by `radius` pixels each way, a square max filter in two passes over the box
    /// its pixels are in.
    static func grown(_ mask: [UInt8], width: Int, height: Int, by radius: Int) -> [UInt8] {
        guard radius > 0, let box = bounds(mask, width: width) else { return mask }
        let xs = max(0, box.x.lowerBound - radius)...min(width - 1, box.x.upperBound + radius)
        let ys = max(0, box.y.lowerBound - radius)...min(height - 1, box.y.upperBound + radius)
        var rows = mask
        for y in box.y {
            for x in xs {
                var high: UInt8 = 0
                for i in max(0, x - radius)...min(width - 1, x + radius) { high = max(high, mask[y * width + i]) }
                rows[y * width + x] = high
            }
        }
        var out = rows
        for y in ys {
            for x in xs {
                var high: UInt8 = 0
                for j in max(0, y - radius)...min(height - 1, y + radius) { high = max(high, rows[j * width + x]) }
                out[y * width + x] = high
            }
        }
        return out
    }

    /// The columns and rows `mask` has pixels in; nil for an empty one.
    static func bounds(_ mask: [UInt8], width: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
        for k in mask.indices where mask[k] > 0 {
            let (x, y) = (k % width, k / width)
            (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
        }
        return maxX < 0 ? nil : (minX...maxX, minY...maxY)
    }

    /// The patches of `mask` (above half, 4-connected) that touch `anchor`, the hand Vision found or the one kept on
    /// the frame before: a tracker that strays onto the bare belly beside the hand leaves a patch of skin there,
    /// which Seedance draws as a stray patch on the new clothes. Without an anchor, or none touched, the largest.
    static func attached(_ mask: [UInt8], width: Int, anchor: [UInt8]?) -> [UInt8] {
        var label = [Int32](repeating: 0, count: mask.count)
        var patches: [(pixels: [Int], touches: Bool)] = []
        guard let box = bounds(mask, width: width) else { return [UInt8](repeating: 0, count: mask.count) }
        let starts = box.y.lazy.flatMap { y in box.x.lazy.map { y * width + $0 } }
        for start in starts where mask[start] > 127 && label[start] == 0 {
            let id = Int32(patches.count + 1)
            var (pixels, queue, touches) = ([Int](), [start], false)
            label[start] = id
            while let k = queue.popLast() {
                pixels.append(k)
                if let anchor, anchor[k] > 127 { touches = true }
                let x = k % width
                for next in [k - width, k + width, x > 0 ? k - 1 : -1, x < width - 1 ? k + 1 : -1]
                where next >= 0 && next < mask.count && mask[next] > 127 && label[next] == 0 {
                    label[next] = id
                    queue.append(next)
                }
            }
            patches.append((pixels, touches))
        }
        let kept =
            patches.contains(where: \.touches)
            ? patches.filter(\.touches) : patches.max { $0.pixels.count < $1.pixels.count }.map { [$0] } ?? []
        var out = [UInt8](repeating: 0, count: mask.count)
        for patch in kept { for k in patch.pixels { out[k] = mask[k] } }
        return out
    }
}
