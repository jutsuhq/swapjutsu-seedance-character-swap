import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// The replaced background (`BackgroundMode.replace`): no pixel of the original frame survives outside the target,
/// people in front included, and the grey keeps inferno's direction without reaching its ends.
struct BackgroundTests {
    let side = 32
    let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())
    let range: ShotDepthRange

    init() throws { range = try #require(ShotDepthRange([0...1])) }

    @Test func greyDepthIsGreyAndNearIsLighter() {
        // Far (0) at the left, near (1) at the right.
        let grey = renderer.greyDepth(floats { x, _ in Float(x) / Float(side - 1) }, range: range)
        let pixels = rgba(grey)
        let far = pixels[side / 2][0], near = pixels[side / 2][side - 1]
        for pixel in [far, near] { #expect(pixel[0] == pixel[1] && pixel[1] == pixel[2], "\(pixel)") }
        #expect(near[0] > far[0])
        // Mid greys only: 0.12…0.88 of 255.
        #expect(far[0] >= 28 && near[0] <= 227, "far \(far) near \(near)")
    }

    /// The target (x < 12) is painted with coloured depth; a person in front (x 8–11, top rows) and everything else
    /// take the grey background. The original is pure green, so any green pixel left is the old scene.
    @Test func nothingOfTheOriginalSurvivesOutsideTheTarget() throws {
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let original = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let depth = floats { _, y in y < 16 ? 1 : 0.5 }
        let masks = renderer.masks(
            targets: [(mask { x, _ in x < 12 }, 3)], inFront: [(mask { x, _ in (8..<12).contains(x) }, 0.75)],
            depth: depth, ramp: 0.05, objects: nil, extent: extent)
        let background = renderer.greyDepth(depth, range: range)
        let out = rgba(
            try renderer.composite(original: original, background: background, depth: depth, range: range, masks: masks)
        )
        for y in 0..<side {
            for x in 0..<side {
                let p = out[y][x].map(Int.init)
                #expect(!(p[1] > p[0] + 40 && p[1] > p[2] + 40), "green at x \(x) y \(y): \(p)")
            }
        }
        // Far from the target: exactly the grey.
        let grey = rgba(background)
        #expect(out[24][28] == grey[24][28] && out[4][28] == grey[4][28])
        // The person in front, nearer than the target where they overlap: grey too, part of the old scene.
        let front = out[4][9]
        #expect(front[0] == front[1] && front[1] == front[2], "\(front)")
        // Inside the target: inferno, not grey.
        let target = out[24][2]
        #expect(target[0] != target[2], "\(target)")
    }

    /// A block the matte took in from far behind the person (a sign behind an arm), wider than the edge fill
    /// reaches: it shows the background, not near-black inferno, and the person around it stays painted.
    @Test func backgroundTheMatteTookInIsNotPainted() throws {
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let original = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let depth = floats { x, y in (4..<16).contains(x) && (10..<22).contains(y) ? 0 : 0.6 }
        let masks = renderer.masks(
            targets: [(mask { x, _ in x < 20 }, 3)], inFront: [], depth: depth, ramp: 0.05, objects: nil,
            extent: extent)
        let background = renderer.greyDepth(depth, range: range)
        let out = rgba(
            try renderer.composite(original: original, background: background, depth: depth, range: range, masks: masks)
        )
        #expect(out[16][10] == rgba(background)[16][10], "\(out[16][10])")
        let person = out[4][10]
        #expect(person[0] != person[2], "\(person)")
    }

    @Test func withoutABackgroundTheOriginalStays() throws {
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let original = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let depth = floats { _, _ in 0.5 }
        let masks = renderer.masks(
            targets: [(mask { x, _ in x < 12 }, 3)], inFront: [], depth: depth, ramp: 0.05, objects: nil,
            extent: extent)
        let out = rgba(try renderer.composite(original: original, depth: depth, range: range, masks: masks))
        #expect(out[16][28] == [0, 255, 0, 255])
    }

    @Test func manifestsWithoutTheModeAreKept() throws {
        #expect(try manifest(extra: "").background == nil)
        #expect(try manifest(extra: #", "background": "replace""#).background == .replace)
    }

    // MARK: Helpers

    private func manifest(extra: String) throws -> Manifest {
        let json = """
            {"source": "clip.mp4", "width": 64, "height": 64, "fps": 24, "frames": 12, "shots": [],
             "timeline": [], "identities": [], "targets": [1], "warnings": [],
             "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                         "mergeDistance": 0.33},
             "seedance": {"video": "control.mp4", "prompt": "", "durationSeconds": 0.5},
             "timings": {}\(extra)}
            """
        return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    }

    /// Rows top-down.
    private func mask(_ inside: (Int, Int) -> Bool) -> CIImage {
        let bytes = (0..<side).flatMap { y in (0..<side).map { inside($0, y) ? UInt8(255) : 0 } }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: side, size: CGSize(width: side, height: side), format: .L8,
            colorSpace: nil)
    }

    private func floats(_ value: (Int, Int) -> Float) -> CIImage {
        let values = (0..<side).flatMap { y in (0..<side).map { value($0, y) } }
        return CIImage(
            bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: side * 4,
            size: CGSize(width: side, height: side), format: .Rf, colorSpace: nil)
    }

    private func rgba(_ image: CIImage) -> [[[UInt8]]] {
        let pixels = renderRGBA(image, width: side, height: side, context: CIContext())
        return (0..<side).map { y in (0..<side).map { x in Array(pixels[(y * side + x) * 4..<(y * side + x) * 4 + 4]) }
        }
    }
}
