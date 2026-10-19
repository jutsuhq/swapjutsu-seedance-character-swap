import CoreImage
import Testing

@testable import SwapjutsuPrep

/// The person crop for depth: its box, when it falls back to the full frame, the fit onto the full-frame map, and
/// that a crop's map lands back on the right frame pixels, portrait frames included.
struct DepthCropTests {
    let portrait = CGRect(x: 0, y: 0, width: 540, height: 960)
    let landscape = CGRect(x: 0, y: 0, width: 854, height: 480)
    let model: CGFloat = 518.0 / 392

    @Test func aSmallPersonGetsAPaddedCropBetweenTheFrameAndModelAspects() throws {
        let person = CGRect(x: 200, y: 300, width: 80, height: 240)
        let need = DepthCrop.padded(person, in: portrait, tuning: Tuning())
        #expect(need.contains(person) && need.minX < person.minX - 20 && need.minY < person.minY - 20)
        let box = try #require(DepthCrop.box(containing: need, in: portrait, modelAspect: model, maxShare: 0.6))
        #expect(box.contains(need))
        #expect(box == box.integral)
        // A tall person in a 9:16 frame: the crop is as narrow as the frame's own aspect allows, not narrower.
        #expect(abs(box.width / box.height - portrait.width / portrait.height) < 0.01)

        let wide = try #require(
            DepthCrop.box(
                containing: CGRect(x: 400, y: 100, width: 60, height: 200), in: landscape, modelAspect: model,
                maxShare: 0.6))
        // In a 16:9 frame the model's 4:3 is the narrower bound.
        #expect(abs(wide.width / wide.height - model) < 0.01)
    }

    @Test func aCropAtTheFrameEdgeStaysInsideTheFrame() throws {
        let person = CGRect(x: 0, y: 0, width: 120, height: 300)
        let need = DepthCrop.padded(person, in: portrait, tuning: Tuning())
        #expect(need.minX == 0 && need.minY == 0)
        let box = try #require(DepthCrop.box(containing: need, in: portrait, modelAspect: model, maxShare: 0.6))
        #expect(portrait.contains(box) && box.contains(need))
    }

    @Test func aLargePersonKeepsTheFullFrame() {
        let need = DepthCrop.padded(CGRect(x: 60, y: 60, width: 400, height: 800), in: portrait, tuning: Tuning())
        #expect(DepthCrop.box(containing: need, in: portrait, modelAspect: model, maxShare: 0.6) == nil)
        #expect(DepthCrop.box(containing: .null, in: portrait, modelAspect: model, maxShare: 0.6) == nil)
    }

    @Test func theLastCropIsKeptWhileThePersonStaysInside() {
        let last = CGRect(x: 100, y: 100, width: 300, height: 533)
        let need = CGRect(x: 150, y: 150, width: 150, height: 300)
        let fresh = CGRect(x: 140, y: 140, width: 260, height: 462)
        #expect(DepthCrop.stable(fresh, need: need, previous: [last]) == last)
        // Moved out of it: a fresh crop.
        let moved = need.offsetBy(dx: 200, dy: 0)
        #expect(DepthCrop.stable(fresh, need: moved, previous: [last]) == fresh)
        // The person shrank to far less than the last crop: a fresh, tighter one.
        let small = CGRect(x: 150, y: 150, width: 60, height: 100)
        let tight = CGRect(x: 120, y: 120, width: 120, height: 213)
        #expect(DepthCrop.stable(tight, need: small, previous: [last]) == tight)
        // Too large for a fresh crop, but still inside the last one: kept.
        #expect(DepthCrop.stable(nil, need: need, previous: [last]) == last)
        #expect(DepthCrop.stable(nil, need: need, previous: []) == nil)
    }

    @Test func theCropIsFittedOntoTheFullFrameScale() throws {
        let crop: [Float] = (0..<64).map { Float($0) / 64 }
        let full = crop.map { 0.4 * $0 + 0.1 }
        let fit = try #require(DepthCrop.fit(crop: crop, full: full))
        #expect(abs(fit.scale - 0.4) < 1e-4 && abs(fit.shift - 0.1) < 1e-4)
        // Flat, reversed or too few samples: no fit, the person keeps the full-frame depth.
        #expect(DepthCrop.fit(crop: [Float](repeating: 0.3, count: 64), full: full) == nil)
        #expect(DepthCrop.fit(crop: crop, full: crop.map { 1 - $0 }) == nil)
        #expect(DepthCrop.fit(crop: Array(crop.prefix(8)), full: Array(full.prefix(8))) == nil)
    }

    /// The crop fades out at its edges inside the frame and not at the frame border.
    @Test func theCropFadesOnlyInsideTheFrame() {
        let box = CGRect(x: 0, y: 200, width: 300, height: 400)
        let weight = DepthCrop.weight(box, in: portrait, 12)
        #expect(value(weight, 150, 400) > 0.99)
        #expect(value(weight, 1, 400) > 0.99)
        #expect(value(weight, 299, 400) < 0.05)
        #expect(value(weight, 150, 201) < 0.05)
        #expect(value(weight, 400, 400) == 0)
    }

    /// A crop of a portrait frame goes through the model's sideways turn and back, then is moved to its box: an
    /// estimator that returns its input must give back the frame's own values under the crop.
    @Test func aCropMapLandsOnItsFramePixels() throws {
        let frame = gradient(portrait)
        let echo = Echo()
        for box in [CGRect(x: 120, y: 300, width: 240, height: 427), CGRect(x: 40, y: 500, width: 400, height: 225)] {
            let crop = try echo.depth(
                of: frame.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY)))
            let placed = crop.buffer.image.transformed(
                by: crop.toFrame.concatenating(CGAffineTransform(translationX: box.minX, y: box.minY)))
            #expect(abs(placed.extent.minX - box.minX) < 1 && abs(placed.extent.maxY - box.maxY) < 1)
            for (x, y) in [(0.2, 0.2), (0.8, 0.3), (0.5, 0.9), (0.3, 0.6)] {
                let px = box.minX + box.width * x, py = box.minY + box.height * y
                #expect(abs(value(placed, px, py) - value(frame, px, py)) < 0.01, "\(box) at \(x), \(y)")
            }
            // Merged with a fit of 1·crop + 0, the frame's values come back inside the crop.
            let merged = DepthCrop.merge(
                full: CIImage(color: .black).cropped(to: portrait), crop: placed, box: box,
                fit: DepthFit(scale: 1, shift: 0), feather: 10)
            #expect(abs(value(merged, box.midX, box.midY) - value(frame, box.midX, box.midY)) < 0.01)
            #expect(value(merged, box.maxX + 20, box.midY) == 0)
        }
    }

    /// Returns its input's grey value at a 64 × 48 "model" resolution, placed like `DepthAnything`.
    private struct Echo: DepthEstimating {
        func depth(of frame: CIImage) throws -> DepthMap {
            let input = DepthAnything.modelInput(frame)
            let size = CGSize(width: 64, height: 48)
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_OneComponent32Float, nil, &made)
            let buffer = try #require(made)
            let e = input.extent
            CIContext().render(
                input.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    .transformed(by: CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height)),
                to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            return DepthMap(buffer: buffer, toFrame: DepthAnything.toFrame(frame: frame.extent, map: size))
        }
    }

    /// Grey rises along x and, more slowly, along y, so a flip or a turn of either axis shows.
    private func gradient(_ extent: CGRect) -> CIImage {
        let w = Int(extent.width), h = Int(extent.height)
        // Grey: a one-channel render takes the luminance.
        var pixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                // Bitmap rows are top-down; Core Image's y points up.
                let up = Float(h - 1 - y) / Float(h)
                let v = 0.6 * Float(x) / Float(w) + 0.3 * up
                pixels.replaceSubrange((y * w + x) * 4..<(y * w + x + 1) * 4, with: [v, v, v, 1])
            }
        }
        return CIImage(
            bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16,
            size: extent.size, format: .RGBAf, colorSpace: nil)
    }

    private func value(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> Float {
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(
            image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: floor(x), y: floor(y), width: 1, height: 1),
            format: .RGBAf, colorSpace: nil)
        return pixel[0]
    }
}

extension CVPixelBuffer {
    fileprivate var image: CIImage { CIImage(cvPixelBuffer: self, options: [.colorSpace: NSNull()]) }
}
