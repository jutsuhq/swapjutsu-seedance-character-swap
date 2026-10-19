import Accelerate
import CoreML
import Foundation

// The CPU side of EdgeTAMTracker: the seed prompt, bank copies and the logits resize, with Accelerate so they stay
// cheap in Debug builds too.
extension EdgeTAMTracker {
    struct Prompt {
        /// The seed as logits at 1024²: +10 inside, −10 outside.
        let mask: MLMultiArray
        let coords: MLMultiArray
        let labels: MLMultiArray
    }

    /// The seed mask as confident logits at 1024² (nearest-sampled), and the initializer's prompt for the object
    /// pointer: the interior point nearest the mask's centroid.
    static func prompt(_ seed: [UInt8], width: Int, height: Int) throws -> Prompt {
        let side = Self.side
        let seedMask = try array([1, 1, side, side], fill: -10)
        var sumX = 0.0, sumY = 0.0, count = 0.0
        seedMask.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in
            for y in 0..<side {
                let fy = min(height - 1, y * height / side)
                for x in 0..<side where seed[fy * width + min(width - 1, x * width / side)] > 127 {
                    p[y * side + x] = 10
                    sumX += Double(x)
                    sumY += Double(y)
                    count += 1
                }
            }
        }
        let (cx, cy) = (sumX / max(1, count), sumY / max(1, count))
        var best = (x: cx, y: cy, d: Double.infinity)
        seedMask.withUnsafeBufferPointer(ofType: Float16.self) { p in
            for y in stride(from: 0, to: side, by: 4) {
                for x in stride(from: 0, to: side, by: 4) where p[y * side + x] > 0 {
                    let d = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
                    if d < best.d { best = (Double(x), Double(y), d) }
                }
            }
        }
        let coords = try array([1, 1, 2])
        coords[0] = NSNumber(value: best.x)
        coords[1] = NSNumber(value: best.y)
        let labels = try MLMultiArray(shape: [1, 1], dataType: .int32)
        labels[0] = 1
        return Prompt(mask: seedMask, coords: coords, labels: labels)
    }

    /// `count` halves of `source` into `target` from element `offset`.
    static func copy(_ source: MLMultiArray, into target: MLMultiArray, at offset: Int, count: Int) {
        source.withUnsafeBufferPointer(ofType: Float16.self) { s in
            target.withUnsafeMutableBufferPointer(ofType: Float16.self) { t, _ in
                guard let from = s.baseAddress, let to = t.baseAddress else { return }
                (to + offset).update(from: from, count: count)
            }
        }
    }

    /// Each slot's 64 temporal values repeated over its 512 tokens.
    static func tiled(_ temporal: [Float]) -> [[Float]] {
        (0..<7).map { slot in
            let row = Array(temporal[(slot * 64)..<(slot * 64 + 64)])
            return [[Float]](repeating: row, count: 512).flatMap { $0 }
        }
    }

    /// The 1024² mask logits sampled bilinearly to a `width` × `height` view (pixel centres aligned, edges clamped),
    /// through a sigmoid, as 0–255 (truncated). With `crop` inside a larger `frame`, the mask is frame-sized, written in
    /// place there with the rest empty. The blend (`bilinear`) goes into one buffer and the sigmoid runs over all of
    /// it. Raw buffers, so a Debug build costs little more than the vDSP calls
    /// (#21: 1.8–2.9 ms an object a frame on an M4, against 4.5–6.2 ms row by row with arrays).
    static func frameMask(
        _ logits: MLMultiArray, width: Int, height: Int, crop: TrackingCrop? = nil,
        frame: TrackingCrop? = nil
    ) -> [UInt8] {
        let side = Self.side
        let source = UnsafeMutablePointer<Float>.allocate(capacity: side * side)
        let values = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
        defer {
            source.deallocate()
            values.deallocate()
        }
        logits.withUnsafeBufferPointer(ofType: Float16.self) { l in
            l.baseAddress.map { floats(from: $0, into: source, count: side * side) }
        }
        bilinear(source, side: side, width: width, height: height, into: values)
        sigmoid255(values, count: width * height)
        return quantized(values, width: width, height: height, crop: crop, frame: frame)
    }

    /// A `side`² grid sampled bilinearly to `width` × `height` (pixel centres aligned, edges clamped) into `values`.
    /// Each source row the blend needs is sampled at the output columns once (two gathers, `a + w · (b − a)`) and kept
    /// while the next output row still uses it; the vertical blend goes straight into `values`.
    private static func bilinear(
        _ source: UnsafeMutablePointer<Float>, side: Int, width: Int, height: Int,
        into values: UnsafeMutablePointer<Float>
    ) {
        let clamp = { (v: Float) in max(0, min(Float(side - 1), v)) }
        let sx = Float(side) / Float(width), sy = Float(side) / Float(height)
        // vDSP_vgathr indices are 1-based.
        var left = [vDSP_Length](repeating: 0, count: width), right = left
        var wx = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let fx = clamp((Float(x) + 0.5) * sx - 0.5)
            let x0 = Int(fx)
            (left[x], right[x], wx[x]) = (vDSP_Length(x0 + 1), vDSP_Length(min(side - 1, x0 + 1) + 1), fx - Float(x0))
        }
        let n = vDSP_Length(width)
        // The two gathers of a row, two sampled rows and the vertical difference.
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 5 * width)
        defer { scratch.deallocate() }
        let a = scratch, b = a + width, diff = b + width, sampled = [diff + width, diff + 2 * width]
        var held = [-1, -1]
        /// Source row `y` sampled at the output columns, sampled once while it stays in use (rows only move down).
        func row(_ y: Int) -> UnsafeMutablePointer<Float> {
            if let i = held.firstIndex(of: y) { return sampled[i] }
            let i = held[0] < held[1] ? 0 : 1
            vDSP_vgathr(source + y * side, left, 1, a, 1, n)
            vDSP_vgathr(source + y * side, right, 1, b, 1, n)
            vDSP_vsub(a, 1, b, 1, b, 1, n)
            vDSP_vma(wx, 1, b, 1, a, 1, sampled[i], 1, n)
            held[i] = y
            return sampled[i]
        }
        for y in 0..<height {
            let fy = clamp((Float(y) + 0.5) * sy - 0.5)
            let y0 = Int(fy), y1 = min(side - 1, y0 + 1)
            var wy = fy - Float(y0)
            let top = row(y0), bottom = row(y1)
            vDSP_vsub(top, 1, bottom, 1, diff, 1, n)
            vDSP_vsma(diff, 1, &wy, top, 1, values + y * width, 1, n)
        }
    }

    /// 255 / (1 + e^−v), in place.
    private static func sigmoid255(_ values: UnsafeMutablePointer<Float>, count: Int) {
        let total = vDSP_Length(count)
        vDSP_vneg(values, 1, values, 1, total)
        var elements = Int32(count)
        vvexpf(values, values, &elements)
        var one: Float = 1, scale: Float = 255
        vDSP_vsadd(values, 1, &one, values, 1, total)
        vDSP_svdiv(&scale, values, 1, values, 1, total)
    }

    /// `width` × `height` values as 0–255 (truncated); with `crop`, placed in a `frame`-sized mask, the rest empty.
    private static func quantized(
        _ values: UnsafeMutablePointer<Float>, width: Int, height: Int, crop: TrackingCrop?,
        frame: TrackingCrop?
    ) -> [UInt8] {
        let n = vDSP_Length(width)
        guard let crop, let frame, crop != frame else {
            var out = [UInt8](repeating: 0, count: width * height)
            out.withUnsafeMutableBufferPointer { o in
                if let base = o.baseAddress { vDSP_vfixu8(values, 1, base, 1, n * vDSP_Length(height)) }
            }
            return out
        }
        var out = [UInt8](repeating: 0, count: frame.width * frame.height)
        out.withUnsafeMutableBufferPointer { o in
            guard let base = o.baseAddress else { return }
            for y in 0..<height {
                vDSP_vfixu8(values + y * width, 1, base + (crop.y + y) * frame.width + crop.x, 1, n)
            }
        }
        return out
    }

    /// `count` halves as Float.
    static func floats(from source: UnsafePointer<Float16>, into target: UnsafeMutablePointer<Float>, count: Int) {
        var half = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source), height: 1, width: vImagePixelCount(count),
            rowBytes: count * 2)
        var single = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&half, &single, 0)
    }

    /// `count` Floats as halves.
    static func halves(from source: UnsafeMutablePointer<Float>, into target: UnsafeMutablePointer<Float16>, count: Int)
    {
        var single = vImage_Buffer(data: source, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        var half = vImage_Buffer(data: target, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        vImageConvert_PlanarFtoPlanar16F(&single, &half, 0)
    }

    static func array(_ shape: [Int], fill: Float16 = 0) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        a.withUnsafeMutableBufferPointer(ofType: Float16.self) { p, _ in p.initialize(repeating: fill) }
        return a
    }

    static func floats(_ a: MLMultiArray) -> [Float] {
        a.withUnsafeBufferPointer(ofType: Float16.self) { p in p.map(Float.init) }
    }
}
