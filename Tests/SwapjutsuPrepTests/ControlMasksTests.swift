import CoreImage
import Testing

@testable import SwapjutsuPrep

/// The control video's three masks (#56): the order of another person against the target, the edit region's
/// growth per shot, and how protected pixels leave the subject matte and the edit region.
struct ControlMasksTests {
    let side = 32

    // MARK: Occlusion

    /// The target fills columns 4–15, the other person columns 14–25 (two shared columns). Depth: larger = nearer.
    private func order(target: Float, other: Float, span: Float = 1) -> Occlusion? {
        let depth = (0..<side * side).map { k -> Float in k % side < 15 ? target : other }
        return Occlusion.order(
            target: grid { x, _ in (4..<16).contains(x) }, other: grid { x, _ in (14..<26).contains(x) }, reach: 1,
            depth: { depth }, span: span, tuning: Tuning())
    }

    @Test func aNearerNeighbourIsInFrontWithTheThresholdHalfwayBetween() {
        let result = order(target: 0.4, other: 0.8)
        #expect(abs((threshold(result) ?? 0) - 0.6) < 1e-5, "\(String(describing: result))")
    }

    @Test func aFartherNeighbourIsBehindAndACloseCallIsBeside() {
        #expect(order(target: 0.8, other: 0.4) == .behind)
        #expect(order(target: 0.5, other: 0.55) == .beside)
        // The same difference on a narrow shot span is a clear order.
        #expect(abs((threshold(order(target: 0.5, other: 0.55, span: 0.2)) ?? 0) - 0.525) < 1e-5)
    }

    @Test func someoneFarAwayTheTargetItselfOrAFragmentIsNoOccluder() {
        let tuning = Tuning()
        let target = grid { x, _ in x < 8 }
        let far = Occlusion.order(
            target: target, other: grid { x, _ in x > 24 }, reach: 2, depth: { [] }, span: 1, tuning: tuning)
        #expect(far == nil)
        let same = Occlusion.order(
            target: target, other: grid { x, _ in x < 9 }, reach: 2, depth: { [] }, span: 1, tuning: tuning)
        #expect(same == nil, "a mask covering most of the target is the target under another identity")
        let fragment = Occlusion.order(
            target: target, other: grid { x, y in (8..<10).contains(x) && y < 4 }, reach: 2, depth: { [] }, span: 1,
            tuning: tuning)
        #expect(fragment == nil, "a mask under a quarter of the target's is a fragment: a hand split off, a headrest")
    }

    @Test func tooLittleContactIsBesideWithoutReadingDepth() {
        let result = Occlusion.order(
            target: grid { x, _ in x < 8 }, other: grid { x, y in (11..<15).contains(x) && y < 16 }, reach: 2,
            depth: {
                Issue.record("depth read without contact")
                return []
            }, span: 1, tuning: Tuning())
        #expect(result == .beside)
    }

    // MARK: Edit region

    /// One radius per target and shot, from the larger of extent and motion, clamped to the floor and ceiling.
    @Test func theEditRadiusIsOnePerShotAndClamped() {
        var tuning = Tuning()
        tuning.maskDilation = 0.01
        tuning.editMaxDilation = 0.05
        tuning.editExtent = 0.125
        tuning.editMotion = 0
        let size = CGSize(width: 1000, height: 1000)
        // Shot 0: a still target 1/4 of the frame tall; shot 1: a tiny one; target 2 is in shot 0 only.
        let tall = target(1) { x, y in x < 8 && y < 8 }, tiny = target(1) { x, y in x == 0 && y == 0 }
        let other = target(2) { x, y in x > 20 && y > 20 }
        let frames = [[tall, other], [tall, other], [tiny], [tiny]]
        let radii = EditRegion.radii(frames, shot: { $0 < 2 ? 0 : 1 }, size: size, tuning: tuning)
        #expect(radii[[0, 1]] == 31.25, "⅛ × 250 px")
        #expect(radii[[1, 1]] == 10, "floor: 1 % of the width")
        #expect(radii[[0, 2]] == 42.96875, "⅛ × 343.75 px")
        tuning.editExtent = 1
        #expect(EditRegion.radii(frames, shot: { $0 < 2 ? 0 : 1 }, size: size, tuning: tuning)[[0, 1]] == 50)
    }

    @Test func motionWidensTheRegionOfAMovingTarget() {
        var tuning = Tuning()
        tuning.maskDilation = 0.001
        tuning.editExtent = 0
        tuning.editMotion = 0.5
        tuning.editMaxDilation = 1
        // Moves one cell (1000 / 32 px) a frame.
        let frames = (0..<6).map { n in [target(1) { x, _ in (n..<n + 4).contains(x) }] }
        let radii = EditRegion.radii(frames, shot: { _ in 0 }, size: CGSize(width: 1000, height: 1000), tuning: tuning)
        #expect(radii[[0, 1]] == 0.5 * 1000 / 32)
    }

    // MARK: Masks

    /// A person in front keeps their nearer pixels inside the edit region, also where the target's matte took them;
    /// their farther pixels and everything outside the edit region are as without them.
    @Test func protectedPixelsLeaveTheSubjectAndTheEditRegion() {
        let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let subject = image { x, _ in x < 16 ? 255 : 0 }
        // The other person covers x 12–27; their pixels in rows 0–15 are near (1), the rest far (0).
        let other = image { x, _ in (12..<28).contains(x) ? 255 : 0 }
        let depth = floats { _, y in y < 16 ? 1 : 0 }
        let masks = renderer.masks(
            targets: [(subject, 3)], inFront: [(other, 0.5)], depth: depth, ramp: 0.05, objects: nil,
            extent: extent)
        let plain = renderer.masks(
            targets: [(subject, 3)], inFront: [], depth: depth, ramp: 0.05, objects: nil, extent: extent)
        let s = read(masks.subject), e = read(masks.edit), plainEdit = read(plain.edit)
        // Near rows: the occluder, grown by the least dilation (1 px here), takes x ≥ 11 from the target and the
        // edit region alike.
        #expect(s[4][10] > 250 && s[4][11] < 5 && s[4][15] < 5)
        #expect(e[4][10] > 250 && e[4][14] < 5 && e[4][18] < 5)
        // Far rows: as without the other person.
        #expect(s[24][15] > 250 && e[24][17] > 250 && e[24][17] == plainEdit[24][17])
        // Outside the edit region nothing is painted either way.
        #expect(e[4][25] == 0 && plainEdit[4][25] == 0)
        #expect(read(plain.subject) == read(subject.cropped(to: extent)))
    }

    @Test func anObjectMaskIsProtectedLikeAPersonInFront() {
        let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let masks = renderer.masks(
            targets: [(image { x, _ in x < 16 ? 255 : 0 }, 3)], inFront: [], depth: nil, ramp: 1,
            objects: image { x, y in x < 20 && y < 8 ? 255 : 0 }, extent: extent)
        let s = read(masks.subject), e = read(masks.edit), m = read(masks.matte)
        #expect(s[4][2] < 5 && e[4][17] < 5 && m[4][2] < 5)
        #expect(s[20][2] > 250 && e[20][17] > 250 && m[20][16] > 250)
    }

    // MARK: Helpers

    private func threshold(_ order: Occlusion?) -> Float? {
        if case .front(let depth) = order { depth } else { nil }
    }

    private func grid(_ inside: (Int, Int) -> Bool) -> MaskGrid {
        MaskGrid(side: side, cells: (0..<side * side).map { inside($0 % side, $0 / side) })
    }

    private func target(_ identity: Int, _ inside: (Int, Int) -> Bool) -> TargetMask {
        TargetMask(identity: identity, key: "", grid: grid(inside), detection: nil, face: nil)
    }

    /// Rows top-down.
    private func image(_ value: (Int, Int) -> UInt8) -> CIImage {
        let bytes = (0..<side).flatMap { y in (0..<side).map { value($0, y) } }
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

    private func read(_ mask: CIImage) -> [[UInt8]] {
        let pixels = renderRGBA(mask, width: side, height: side, context: CIContext())
        return (0..<side).map { y in (0..<side).map { pixels[(y * side + $0) * 4] } }
    }
}
