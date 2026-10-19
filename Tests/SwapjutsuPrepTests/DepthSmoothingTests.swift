import CoreImage
import Testing

@testable import SwapjutsuPrep

/// Depth smoothing along the optical flow (#17): the flow's direction and units, its confidence, the history
/// resets, the scale alignment and the fallback where the flow is not trusted.
///
/// Smoother tests use a 64 × 48 frame (or 48 × 64, portrait) with the flow at the frame size, so a vector in flow
/// pixels is a vector in frame pixels.
struct DepthSmoothingTests {
    let context = CIContext()

    // MARK: Vision's flow

    /// The content moves 6 px right and 4 px down (rows top-down) from the previous frame to the current one, so
    /// each current pixel came from 6 px left and 4 px up: the backward vectors are (−6, −4), landscape and portrait.
    @Test(arguments: [(160, 96), (96, 160)])
    func backwardFlowPointsToWhereThePixelWas(size: (Int, Int)) throws {
        let (w, h) = size
        let previous = try FlowFrame(texture(w, h, dx: 0, dy: 0), width: w, height: h, context: context)
        let current = try FlowFrame(texture(w, h, dx: 6, dy: 4), width: w, height: h, context: context)
        let back = try OpticalFlow.vectors(from: current.buffer, to: previous.buffer)
        var u: Float = 0, v: Float = 0, n: Float = 0
        for y in h / 4..<(3 * h / 4) {
            for x in w / 4..<(3 * w / 4) {
                u += back[(y * w + x) * 2]
                v += back[(y * w + x) * 2 + 1]
                n += 1
            }
        }
        #expect(abs(u / n + 6) < 0.5 && abs(v / n + 4) < 0.5, "mean vector (\(u / n), \(v / n))")
    }

    // MARK: Confidence

    /// Consistent motion is trusted except where it leaves the frame; where the forward flow disagrees (a
    /// disocclusion) or the luma does not match, it is not.
    @Test func confidenceRejectsLeavingTheFrameDisocclusionAndALumaMismatch() throws {
        let w = 32, h = 16
        let backward = (0..<(w * h)).flatMap { _ -> [Float] in [-2, 0] }
        // x ≥ 24: the forward flow does not bring the pixel back.
        let forward = (0..<(w * h)).flatMap { k -> [Float] in k % w >= 22 ? [-5, 0] : [2, 0] }
        let luma = (0..<(w * h)).map { k in Float(k % w) / 64 }
        // Rows ≥ 12: the previous frame is much brighter there.
        let previous = (0..<(w * h)).map { k in Float(k % w + 2) / 64 + (k / w >= 12 ? 0.5 : 0) }
        let field = try OpticalFlow.field(
            backward: backward, forward: forward, luma: luma, previousLuma: previous, size: (w, h), sigma: 0.05)
        func c(_ x: Int, _ y: Int) -> Float { field.values[(y * w + x) * 4 + 2] }
        #expect(c(0, 4) == 0 && c(1, 4) == 0, "lands left of the frame")
        #expect(c(2, 4) > 0.99 && c(10, 4) > 0.99, "consistent and same luma")
        #expect(c(26, 4) == 0 && c(30, 4) == 0, "forward/backward disagree")
        #expect(c(10, 13) < 0.01, "luma mismatch")
        #expect(field.values[(4 * w + 10) * 4] == -2, "the vector is kept")
    }

    // MARK: Smoother

    /// A cut, a gap, a frame without a target and a change of targets each start over: that frame keeps its own
    /// depth exactly.
    @Test func historyResetsAtCutsGapsNoTargetAndTargetChanges() throws {
        let still = flow(64, 48) { _, _ in SIMD3(0, 0, 1) }
        let d0 = depth(64, 48) { x, y in pattern(x, y) }
        let d1 = depth(64, 48) { x, y in pattern(x, y) + 0.02 * Float((x + y) % 2) }
        func run(_ second: (inout DepthSmoother) throws -> DepthSmoother.Step) throws -> DepthSmoother.Step {
            var smoother = smoother(64, 48)
            _ = try smoother.step(frame: 0, shot: 0, targets: [1], depth: d0, flow: nil, mask: everywhere)
            return try second(&smoother)
        }
        let cut = try run { try $0.step(frame: 1, shot: 1, targets: [1], depth: d1, flow: still, mask: everywhere) }
        let gap = try run { try $0.step(frame: 2, shot: 0, targets: [1], depth: d1, flow: still, mask: everywhere) }
        let noTarget = try run {
            $0.skip()
            return try $0.step(frame: 1, shot: 0, targets: [1], depth: d1, flow: still, mask: everywhere)
        }
        let newTarget = try run {
            try $0.step(frame: 1, shot: 0, targets: [1, 2], depth: d1, flow: still, mask: everywhere)
        }
        let noFlow = try run { try $0.step(frame: 1, shot: 0, targets: [1], depth: d1, flow: nil, mask: everywhere) }
        for (name, step) in [("cut", cut), ("gap", gap), ("no target", noTarget), ("new target", newTarget),
            ("no flow", noFlow)] {
            #expect(step.reset && step.residual == nil, "\(name)")
            #expect(read(step.depth) == read(materialised(d1)), "\(name): the frame keeps its own depth")
        }
        let same = try run { try $0.step(frame: 1, shot: 0, targets: [1], depth: d1, flow: still, mask: everywhere) }
        #expect(!same.reset && same.residual != nil)
    }

    /// The model rescales its relative depth from one frame to the next (here ×2 + 1). This frame is brought onto the
    /// history's scale before the blend, so the result is this frame's depth under one scale and shift (no trail of
    /// the previous frame's shape), and the jump itself is damped.
    @Test func aScaleJumpIsDampedWithoutTrails() throws {
        var smoother = smoother(64, 48)
        let d0 = depth(64, 48) { pattern($0, $1) }
        _ = try smoother.step(frame: 0, shot: 0, targets: [1], depth: d0, flow: nil, mask: everywhere)
        let step = try smoother.step(
            frame: 1, shot: 0, targets: [1], depth: depth(64, 48) { 2 * pattern($0, $1) + 1 },
            flow: flow(64, 48) { _, _ in SIMD3(0, 0, 1) }, mask: everywhere)
        let out = read(step.depth).flatMap { $0 }, before = read(materialised(d0)).flatMap { $0 }
        let fit = try #require(DepthCrop.fit(crop: before, full: out))
        let worst = zip(before, out).map { abs(fit.scale * $0 + fit.shift - $1) }.max() ?? 1
        #expect(worst < 0.005, "not one scale of this frame's depth: \(worst)")
        #expect(fit.scale > 1.05 && fit.scale < 1.6, "scale jump 2× came through as \(fit.scale)×")
    }

    /// A scale change that lasts (the person walks towards the camera) comes through within a few frames.
    @Test func aLastingScaleChangeComesThrough() throws {
        var smoother = smoother(64, 48)
        _ = try smoother.step(
            frame: 0, shot: 0, targets: [1], depth: depth(64, 48) { pattern($0, $1) }, flow: nil, mask: everywhere)
        let later = depth(64, 48) { 2 * pattern($0, $1) + 1 }
        var out: [[Float]] = []
        for n in 1...16 {
            out = read(
                try smoother.step(
                    frame: n, shot: 0, targets: [1], depth: later, flow: flow(64, 48) { _, _ in SIMD3(0, 0, 1) },
                    mask: everywhere
                ).depth)
        }
        let target = read(materialised(later))
        for y in stride(from: 0, to: 48, by: 7) {
            for x in stride(from: 0, to: 64, by: 9) {
                #expect(abs(out[y][x] - target[y][x]) < 0.02 * target[y][x], "x \(x) y \(y): \(out[y][x])")
            }
        }
    }

    /// The person moved 4 px (right on a landscape frame, down on a portrait one); the noise this frame adds is
    /// damped along the motion, so the result is nearer the true moved surface than this frame's depth. Where the
    /// flow has no confidence (newly revealed pixels), this frame's depth is kept, on the history's scale.
    @Test(arguments: [Motion(w: 64, h: 48, dx: 4, dy: 0), Motion(w: 48, h: 64, dx: 0, dy: 4)])
    func motionIsFollowedAndUntrustedPixelsKeepTheirDepth(_ motion: Motion) throws {
        let (w, h, dx, dy) = (motion.w, motion.h, motion.dx, motion.dy)
        let truth = { (x: Int, y: Int) in pattern(x - dx, y - dy) }
        // Zero-mean shimmer: no scale or shift can explain it away.
        let noise = { (x: Int, y: Int) -> Float in (x + y) % 2 == 0 ? 0.02 : -0.02 }
        var smoother = smoother(w, h)
        _ = try smoother.step(
            frame: 0, shot: 0, targets: [1], depth: depth(w, h) { pattern($0, $1) }, flow: nil, mask: everywhere)
        // Untrusted: the strip the motion revealed and the first column band.
        let untrusted = { (x: Int, y: Int) in x < dx + 6 && y < dy + 6 || x < 8 }
        let current = depth(w, h) { truth($0, $1) + noise($0, $1) }
        let step = try smoother.step(
            frame: 1, shot: 0, targets: [1], depth: current,
            flow: flow(w, h) { x, y in SIMD3(Float(-dx), Float(-dy), untrusted(x, y) ? 0 : 1) }, mask: everywhere)
        let out = read(step.depth), raw = read(materialised(current))
        var before: Float = 0, after: Float = 0
        var kept: [(raw: Float, out: Float)] = []
        for y in 0..<h {
            for x in 0..<w {
                if untrusted(x, y) {
                    kept.append((raw[y][x], out[y][x]))
                } else if x >= dx + 1, y >= dy + 1 {
                    before += abs(raw[y][x] - truth(x, y))
                    after += abs(out[y][x] - truth(x, y))
                }
            }
        }
        // Untrusted pixels are this frame's depth under the one scale and shift of the whole frame: nothing blended.
        let fit = try #require(DepthCrop.fit(crop: kept.map(\.raw), full: kept.map(\.out)))
        let worst = kept.map { abs(fit.scale * $0.raw + fit.shift - $0.out) }.max() ?? 1
        #expect(worst < 0.003, "untrusted pixels blended: \(worst)")
        #expect(after < before * 0.6, "error \(before) → \(after)")
        let residual = try #require(step.residual)
        #expect(residual.smoothed < residual.raw)
    }

    // MARK: Helpers

    struct Motion: Sendable, CustomTestStringConvertible {
        let w: Int, h: Int, dx: Int, dy: Int
        var testDescription: String { "\(w)×\(h) moved (\(dx), \(dy))" }
    }

    private var everywhere: MaskGrid { MaskGrid(side: 8, cells: [Bool](repeating: true, count: 64)) }

    private func smoother(_ w: Int, _ h: Int) -> DepthSmoother {
        DepthSmoother(settings: .init(tuning: Tuning()), width: w, height: h, context: context)
    }

    private func pattern(_ x: Int, _ y: Int) -> Float {
        1 + 0.3 * sin(Float(x) / 5) * cos(Float(y) / 7) + 0.004 * Float(x)
    }

    /// A one-channel float image; `value` by column and row, row 0 at the top.
    private func depth(_ w: Int, _ h: Int, _ value: (Int, Int) -> Float) -> CIImage {
        let values = (0..<h).flatMap { y in (0..<w).map { value($0, y) } }
        return CIImage(
            bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 4,
            size: CGSize(width: w, height: h), format: .Rf, colorSpace: nil)
    }

    /// A field with (u, v, confidence) by column and row.
    private func flow(_ w: Int, _ h: Int, _ value: (Int, Int) -> SIMD3<Float>) -> FlowField {
        FlowField(
            width: w, height: h,
            values: (0..<h).flatMap { y in
                (0..<w).flatMap { x -> [Float] in
                    let f = value(x, y)
                    return [f.x, f.y, f.z, 0]
                }
            })
    }

    /// The image through half floats, as the smoother keeps every frame.
    private func materialised(_ image: CIImage) -> CIImage {
        var smoother = smoother(Int(image.extent.width), Int(image.extent.height))
        return (try? smoother.step(frame: 0, shot: 0, targets: [], depth: image, flow: nil, mask: everywhere).depth)
            ?? image
    }

    private func read(_ image: CIImage) -> [[Float]] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [Float](repeating: 0, count: w * h)
        context.render(
            image, toBitmap: &pixels, rowBytes: w * 4, bounds: image.extent, format: .Rf, colorSpace: nil)
        return (0..<h).map { y in Array(pixels[(y * w)..<((y + 1) * w)]) }
    }

    /// Smooth colour waves, content moved by (dx, dy) pixels, rows top-down.
    private func texture(_ w: Int, _ h: Int, dx: Int, dy: Int) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = Double(x - dx), t = Double(y - dy)
                bytes[(y * w + x) * 4] = UInt8(127 + 120 * sin(s * 0.21) * cos(t * 0.17))
                bytes[(y * w + x) * 4 + 1] = UInt8(127 + 120 * sin(s * 0.11 + t * 0.19))
                bytes[(y * w + x) * 4 + 2] = UInt8(127 + 120 * cos(s * 0.07 - t * 0.13))
            }
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
