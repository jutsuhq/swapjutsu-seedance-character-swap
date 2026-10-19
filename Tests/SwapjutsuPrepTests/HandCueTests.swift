import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// The hand cue: a hand at the torso's depth gets painted nearer, so its shape shows in the coloured depth, and
/// nothing else changes.
struct HandCueTests {
    let side = 64
    let range: ShotDepthRange

    init() throws { range = try #require(ShotDepthRange([0...1])) }

    let hand = HandCue.Hand(
        wrist: CGPoint(x: 32, y: 12),
        fingers: [16, 24, 32, 40, 48].map { x in [CGPoint(x: x, y: 26), CGPoint(x: x, y: 40), CGPoint(x: x, y: 50)] })

    @Test func aHandOnTheTorsoShowsAsNearerDepth() throws {
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let mask = try #require(HandCue.mask([hand], extent: extent))
        let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())
        let original = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let depth = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let everywhere = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        let masks = renderer.masks(
            targets: [(everywhere, 0)], inFront: [], depth: depth, ramp: 0.05, objects: nil, extent: extent)
        let flat = rgba(try renderer.composite(original: original, depth: depth, range: range, masks: masks))
        let cued = rgba(
            try renderer.composite(original: original, depth: depth, range: range, masks: masks, hands: mask))
        let painted = rgba(mask)
        let inside = try #require(points(painted) { $0 > 250 }.first)
        let outside = try #require(points(painted) { $0 < 5 }.first)
        #expect(cued[inside.y][inside.x] != flat[inside.y][inside.x], "\(inside) \(cued[inside.y][inside.x]) \(flat[inside.y][inside.x]) \(painted[inside.y][inside.x])")
        #expect(cued[outside.y][outside.x] == flat[outside.y][outside.x])
        // Five fingers: five separate runs of white across the row through the middle joints.
        let row = painted[side - 1 - 40].map { $0[0] > 128 }
        #expect(zip(row, row.dropFirst()).filter { !$0 && $1 }.count == 5)
    }

    @Test func noHandsNoMask() {
        #expect(HandCue.mask([], extent: CGRect(x: 0, y: 0, width: 8, height: 8)) == nil)
    }

    private func points(_ image: [[[UInt8]]], where test: (UInt8) -> Bool) -> [(x: Int, y: Int)] {
        (0..<side).flatMap { y in (0..<side).compactMap { x in test(image[y][x][0]) ? (x, y) : nil } }
    }

    private func rgba(_ image: CIImage) -> [[[UInt8]]] {
        let pixels = renderRGBA(image, width: side, height: side, context: CIContext())
        return (0..<side).map { y in (0..<side).map { x in Array(pixels[(y * side + x) * 4..<(y * side + x) * 4 + 4]) }
        }
    }
}
