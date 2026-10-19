import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// The footage's folds over the near end of the coloured depth (`ControlRenderer.detailed`): the arm held out to
/// the camera gets its sleeve's folds, the knit's ribs and the silhouette's edge stay out, and the body farther
/// back keeps plain depth.
struct DepthDetailTests {
    // A 50th of the width is 20 px, a 15th 68.
    let width = 1020
    let height = 32
    var extent: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())
    let range: ShotDepthRange

    init() throws { range = try #require(ShotDepthRange([0...1])) }

    /// Folds of 240 px and ribs of 40, in columns: a sleeve near the camera; left of 450 the body at 0.2, right of
    /// it the arm at 0.8; the target's mean depth passed as 0.4, a torso larger than this strip's; the person ends at 900, a `wall` beyond.
    struct Scene {
        var original: CIImage
        var depth: CIImage
        var core: CIImage
    }

    func scene(folds: Float, ribs: Float, wall: Float = 1) -> Scene {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var depth = [Float](repeating: 0, count: width * height)
        var core = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let k = y * width + x
                let luma =
                    x >= 900
                    ? wall : 0.5 + folds * sin(2 * .pi * Float(x) / 240) + ribs * sin(2 * .pi * Float(x) / 40)
                let v = UInt8(max(0, min(255, luma * 255)))
                (pixels[4 * k], pixels[4 * k + 1], pixels[4 * k + 2]) = (v, v, v)
                depth[k] = x < 450 ? 0.2 : 0.8
                core[k] = x < 900 ? 255 : 0
            }
        }
        let size = CGSize(width: width, height: height)
        let rgb = CGColorSpaceCreateDeviceRGB()
        return Scene(
            original: CIImage(
                bitmapData: Data(pixels), bytesPerRow: width * 4, size: size, format: .RGBA8, colorSpace: rgb),
            depth: CIImage(
                bitmapData: depth.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 4, size: size,
                format: .Rf, colorSpace: nil),
            core: CIImage(bitmapData: Data(core), bytesPerRow: width, size: size, format: .L8, colorSpace: nil)
        )
    }

    /// The green channel along the middle row: inferno's red is near its top at the arm's depth.
    func row(_ image: CIImage) -> [Float] {
        let pixels = renderRGBA(image, width: width, height: height, context: CIContext())
        return (0..<width).map { Float(pixels[((height / 2) * width + $0) * 4 + 1]) }
    }

    func spread(_ values: ArraySlice<Float>) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
    }

    @Test func theNearArmGetsItsFoldsAndTheBodyKeepsPlainDepth() {
        let s = scene(folds: 0.15, ribs: 0)
        let (original, depth, core) = (s.original, s.depth, s.core)
        let plain = row(renderer.colouredDepth(depth, range: range))
        let detailed = row(
            renderer.detailed(
                renderer.colouredDepth(depth, range: range), original: original, depth: depth, range: range,
                targets: [DetailTarget(core: core, mean: 0.4)]))
        // The arm: flat before, its folds after, following the footage's (brighter where the footage is).
        #expect(spread(plain[520..<820]) == 0)
        #expect(spread(detailed[520..<820]) > 10)
        let bright = 780, dark = 660
        #expect(sin(2 * .pi * Float(bright) / 240) > 0.9 && detailed[bright] > plain[bright])
        #expect(sin(2 * .pi * Float(dark) / 240) < -0.9 && detailed[dark] < plain[dark])
        // The body farther back is untouched.
        #expect(Array(detailed[0..<390]) == Array(plain[0..<390]))
    }

    /// A white wall or a black one beside the arm: the arm's edge comes out the same.
    @Test func theBackgroundNeverReachesTheEdge() {
        let rows = [Float(1), 0].map { wall in
            let s = scene(folds: 0.15, ribs: 0, wall: wall)
            let (original, depth, core) = (s.original, s.depth, s.core)
            return row(
                renderer.detailed(
                    renderer.colouredDepth(depth, range: range), original: original, depth: depth, range: range,
                    targets: [DetailTarget(core: core, mean: 0.4)]))
        }
        let differences = (450..<900).map { abs(rows[0][$0] - rows[1][$0]) }
        #expect(differences.max() ?? 0 <= 1, "\(differences.suffix(40))")
    }

    @Test func theKnitsRibsStayOut() {
        let folds = scene(folds: 0.15, ribs: 0)
        let ribs = scene(folds: 0, ribs: 0.15)
        let shaded = { (s: Scene) in
            row(
                renderer.detailed(
                    renderer.colouredDepth(s.depth, range: range), original: s.original, depth: s.depth,
                    range: range, targets: [DetailTarget(core: s.core, mean: 0.4)]))
        }
        #expect(spread(shaded(ribs)[520..<820]) < spread(shaded(folds)[520..<820]) / 5)
    }

    /// A person near the camera as a whole, the arm no nearer than the rest (the mean): nothing changes.
    @Test func aPersonNearAsAWholeKeepsPlainDepth() {
        let s = scene(folds: 0.15, ribs: 0)
        let coloured = renderer.colouredDepth(s.depth, range: range)
        let detailed = renderer.detailed(
            coloured, original: s.original, depth: s.depth, range: range,
            targets: [DetailTarget(core: s.core, mean: 0.8)])
        #expect(row(detailed) == row(coloured))
    }

    /// Off unless asked for: colored depth and the hybrid body render as before.
    @Test func withoutDetailTheCompositeIsUnchanged() throws {
        let s = scene(folds: 0.15, ribs: 0)
        let (original, depth, core) = (s.original, s.depth, s.core)
        let masks = ControlMasks(subject: core, edit: core, matte: core)
        let plain = try renderer.composite(original: original, depth: depth, range: range, masks: masks)
        let detailed = try renderer.composite(
            original: original, depth: depth, range: range, masks: masks,
            detail: [DetailTarget(core: core, mean: 0.4)])
        #expect(row(plain) != row(detailed))
        #expect(Array(row(plain)[0..<390]) == Array(row(detailed)[0..<390]))
    }
}
