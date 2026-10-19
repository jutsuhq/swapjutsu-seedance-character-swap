import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// Object occluders found without a click (#56): which candidates `OccluderCells` keeps on the grid.
struct OccluderMaskingTests {
    let w = 40, h = 40

    /// The target's body fills columns 8–31 except a 6 × 6 patch at (16…21, 16…21), which is the candidate (no
    /// person to Vision). The body is at depth 0.3–0.5 from top to bottom, the patch at `patch` (larger = nearer).
    private func scene(patch: Float) -> (candidates: CellGrid, body: CellGrid, depth: [Float]) {
        var candidates = CellGrid(w: w, h: h), body = CellGrid(w: w, h: h)
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 8..<32 {
                let k = y * w + x
                let inPatch = (16..<22).contains(x) && (16..<22).contains(y)
                candidates.cells[k] = inPatch
                body.cells[k] = !inPatch
                depth[k] = inPatch ? patch : 0.3 + Float(y) / Float(h) * 0.2
            }
        }
        return (candidates, body, depth)
    }

    private func find(
        _ s: (candidates: CellGrid, body: CellGrid, depth: [Float]), previous: CellGrid?
    )
        -> OccluderCells.Result
    {
        let tuning = OccluderTuning()
        let body = s.body.cells.indices.filter { s.body.cells[$0] }.map { s.depth[$0] }
        guard let stats = OccluderCells.Stats(body, tuning: tuning) else {
            Issue.record("no body")
            return OccluderCells.Result(candidates: s.candidates, kept: nil, reference: nil)
        }
        return OccluderCells.find(
            candidates: s.candidates, body: s.body, depth: s.depth, stats: stats, previous: previous, tuning: tuning)
    }

    @Test func aNearerObjectInsideTheTargetIsKeptFromItsSecondFrame() {
        let s = scene(patch: 0.9)
        let first = find(s, previous: nil)
        #expect(first.kept == nil, "one frame alone must not flash")
        #expect(first.candidates.count == 36)
        let second = find(s, previous: first.candidates)
        #expect(second.kept?.count == 36)
        #expect(second.kept?.cells[18 * w + 18] == true)
        #expect((second.reference?.threshold ?? 0) > 0.4, "the full-resolution cut sits in front of the body there")
    }

    @Test func aPatchVisionMissedAtTheBodysDepthIsNotAnOccluder() {
        let s = scene(patch: 0.42)
        let first = find(s, previous: nil)
        #expect(first.candidates.cells.allSatisfy { !$0 })
        #expect(find(s, previous: first.candidates).kept == nil)
    }

    @Test func aSpeckIsDropped() {
        var s = scene(patch: 0.9)
        s.candidates = CellGrid(w: w, h: h)
        s.candidates.cells[18 * w + 18] = true
        s.candidates.cells[18 * w + 19] = true
        #expect(find(s, previous: s.candidates).kept == nil)
    }

    @Test func gridMorphologyAndComponents() {
        var grid = CellGrid(w: 6, h: 4)
        grid.cells[1 * 6 + 1] = true
        grid.cells[2 * 6 + 4] = true
        #expect(grid.components().count == 2)
        #expect(grid.dilated(by: 1).count == 18)
        #expect(CellGrid(w: 3, h: 3, cells: [Bool](repeating: true, count: 9)).eroded(by: 1).count == 9)
        let around = CellGrid(w: 6, h: 4, cells: [Bool](repeating: true, count: 24)).cells(around: [7], within: 1)
        #expect(around.sorted() == [0, 1, 2, 6, 8, 12, 13, 14])
    }

    @Test func onByDefaultWithAnOffSwitch() {
        let model = URL(filePath: "/dev/null")
        #expect(PrepStages.standard(tuning: Tuning(), depthModel: model).foreground is OccluderMasking)
        var tuning = Tuning()
        tuning.occluders.enabled = false
        #expect(PrepStages.standard(tuning: tuning, depthModel: model).foreground == nil)
    }

    /// A protected object inside the target keeps the background, as a person in front does (#89): the original
    /// frame, or the grey depth when the background is replaced. Never the painted character.
    @Test func aProtectedObjectKeepsTheBackgroundOriginalOrGrey() throws {
        let side = 32, context = CIContext()
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let renderer = ControlRenderer(tuning: Tuning(), context: context)
        let range = try #require(ShotDepthRange([0...1]))
        let image = { (inside: (Int, Int) -> Bool) -> CIImage in
            let bytes = (0..<side).flatMap { y in (0..<side).map { inside($0, y) ? UInt8(255) : 0 } }
            return CIImage(
                bitmapData: Data(bytes), bytesPerRow: side, size: extent.size, format: .L8, colorSpace: nil)
        }
        let original = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let depth = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let masks = renderer.masks(
            targets: [(image { x, _ in x < 20 }, 3)], inFront: [], depth: depth, ramp: 0.05,
            objects: image { x, y in (4..<12).contains(x) && (4..<12).contains(y) }, extent: extent)
        let pixel = { (out: CIImage) -> [UInt8] in
            let p = renderRGBA(out, width: side, height: side, context: context)
            let k = (8 * side + 8) * 4
            return Array(p[k..<k + 4])
        }
        let kept = pixel(try renderer.composite(original: original, depth: depth, range: range, masks: masks))
        #expect(kept == [0, 255, 0, 255], "the original object, not painted: \(kept)")
        let grey = renderer.greyDepth(depth, range: range)
        let replaced = pixel(
            try renderer.composite(original: original, background: grey, depth: depth, range: range, masks: masks))
        #expect(replaced == pixel(grey), "grey like the rest of the old scene: \(replaced)")
    }
}
