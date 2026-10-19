import CoreImage
import Testing

@testable import SwapjutsuPrep

/// The edge-aware depth at the silhouette: the contaminated band and the ring take the person's depth, nothing else
/// changes, the scale stays, the frame's texture adds no relief, the frame border is no edge, no target is a no-op.
///
/// The person fills x < 40 of a 64 × 48 frame (touching the left, top and bottom borders); the matte is trusted
/// up to 3 px from its edge, so x 37–39 is the band the model smeared and x 40–43 the dilation ring.
struct DepthEdgesTests {
    let w = 64, h = 48
    var settings: DepthEdges.Settings {
        var tuning = Tuning()
        tuning.depthEdgeErosion = 3 / 64
        tuning.depthEdgeReach = 8 / 64
        return DepthEdges.Settings(width: 64, tuning: tuning)
    }

    @Test func theSmearedBandAndTheRingTakeThePersonsDepth() throws {
        // Relief across the body, the background's depth smeared into the band, background at 0.
        let raw = depth { x, _ in x < 37 ? 1 + Float(x) / 100 : x < 40 ? 0.2 : 0 }
        let out = try refined(raw, guide: guide { x, _ in x < 40 ? [128, 128, 128] : [40, 160, 40] })
        let near = 1 + Float(29) / 100...1 + Float(36) / 100
        for y in [0, h / 2, h - 1] {
            for x in 37..<44 { #expect(near.contains(out[y][x]), "x \(x) y \(y): \(out[y][x])") }
            for x in 0..<37 { #expect(out[y][x] == raw[y][x], "trusted depth changed at x \(x) y \(y)") }
            for x in 44..<w { #expect(out[y][x] == 0, "unpainted depth changed at x \(x) y \(y)") }
        }
    }

    /// Stripes in the frame reweight the samples, but every sample is the same flat depth: no relief appears and
    /// the value is exactly the person's.
    @Test func theFramesTextureAddsNoReliefAndKeepsTheScale() throws {
        let raw = depth { x, _ in x < 37 ? 0.7 : x < 40 ? 0.1 : 0 }
        let out = try refined(raw, guide: guide { x, y in (x / 2 + y / 3) % 2 == 0 ? [250, 20, 20] : [10, 10, 200] })
        for row in out { for x in 0..<44 { #expect(abs(row[x] - 0.7) < 1e-5, "x \(x): \(row[x])") } }
    }

    /// The frame, a pixel buffer as the decoder hands it over, steers each band pixel by the colour at that pixel,
    /// also when only some rows are rendered (as when Core Image renders in tiles). Top half red at depth 1, bottom
    /// half blue at 2.
    @Test func theFramesColourSteersTheBandAtTheRightPixels() throws {
        let raw = depth { x, y in x < 37 ? (y < 24 ? 1 : 2) : x < 40 ? 0.2 : 0 }
        let frame = try pixelBuffer { x, y in x < 40 ? (y < 24 ? [230, 20, 20] : [20, 20, 230]) : [40, 160, 40] }
        let out = try refined(raw, guide: frame, rows: 10..<34)
        #expect(out[21][38] < 1.2, "top band pixel: \(out[21][38])")
        #expect(out[26][38] > 1.8, "bottom band pixel: \(out[26][38])")
    }

    /// A part thinner than twice the erosion (a finger, a coat tail) has no trusted sample: it and its ring take the
    /// part's own depth (the nearest one sampled), not the background's 0.
    @Test func aThinPartKeepsItsOwnDepth() throws {
        let raw = depth { x, _ in (20..<24).contains(x) ? (x == 21 ? 0.6 : 0.4) : 0 }
        let out = try refined(raw, guide: guide { _, _ in [128, 128, 128] }, person: { x, _ in (20..<24).contains(x) })
        for x in 20..<28 { #expect((0.4...0.6).contains(out[h / 2][x]), "x \(x): \(out[h / 2][x])") }
    }

    /// A gap between arm and body that the matte closed carries the background's depth, past the far end of the
    /// shot's range: it takes the person's depth around it. Far depth with no person's depth in reach stays.
    @Test func depthPastTheFarEndTakesThePersonsDepthNearby() throws {
        let raw = depth { x, _ in x < 40 && !(31..<33).contains(x) && !(4..<28).contains(x) ? 1 : 0 }
        let gray = guide { _, _ in [128, 128, 128] }
        let out = try refined(raw, guide: gray, floor: 0.5)
        for x in 31..<33 { #expect(abs(out[h / 2][x] - 1) < 1e-5, "gap x \(x): \(out[h / 2][x])") }
        #expect(out[h / 2][16] == 0, "far from the person's depth: kept")
        #expect(try refined(raw, guide: gray)[h / 2][31] == 0, "without a floor nothing changes")
    }

    @Test func withoutATargetTheDepthIsUntouched() throws {
        let raw = depth { x, y in Float(x * y) / 1000 }
        let out = try refined(raw, guide: guide { _, _ in [90, 90, 90] }, person: { _, _ in false })
        #expect(out == raw)
    }

    private func refined(
        _ raw: [[Float]], guide: CIImage, rows: Range<Int>? = nil, person: (Int, Int) -> Bool = { x, _ in x < 40 },
        floor: Float = -.greatestFiniteMagnitude
    ) throws -> [[Float]] {
        let core = mask { x, y in person(x, y) }
        let grown = mask { x, y in person(max(0, x - 4), y) }
        let image = image(raw)
        let out = try DepthEdges.refine(
            depth: image, guide: guide, core: core, grown: grown, settings: settings, floor: floor)
        #expect(out.extent == image.extent)
        let rows = rows ?? 0..<h
        var pixels = [Float](repeating: 0, count: w * h * 4)
        CIContext().render(
            out, toBitmap: &pixels, rowBytes: w * 16,
            bounds: CGRect(x: 0, y: h - rows.upperBound, width: w, height: rows.count), format: .RGBAf, colorSpace: nil)
        return (0..<h).map { y in
            (0..<w).map { rows.contains(y) ? pixels[((y - rows.lowerBound) * w + $0) * 4] : .nan }
        }
    }

    private func depth(_ value: (Int, Int) -> Float) -> [[Float]] { (0..<h).map { y in (0..<w).map { value($0, y) } } }

    private func image(_ rows: [[Float]]) -> CIImage {
        CIImage(
            bitmapData: rows.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 4,
            size: CGSize(width: w, height: h), format: .Rf, colorSpace: nil)
    }

    private func mask(_ inside: (Int, Int) -> Bool) -> CIImage {
        let bytes = (0..<h).flatMap { y in (0..<w).map { inside($0, y) ? UInt8(255) : 0 } }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
    }

    /// A BGRA frame as the decoder hands it over; `colour` gives RGB by column and row (row 0 at the top).
    private func pixelBuffer(_ colour: (Int, Int) -> [UInt8]) throws -> CIImage {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, w, h, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let c = colour(x, y)
                for (k, v) in [c[2], c[1], c[0], 255].enumerated() { base[y * row + x * 4 + k] = v }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return CIImage(cvPixelBuffer: buffer)
    }

    private func guide(_ colour: (Int, Int) -> [UInt8]) -> CIImage {
        let bytes: [UInt8] = (0..<h).flatMap { y in (0..<w).flatMap { x -> [UInt8] in colour(x, y) + [255] } }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
