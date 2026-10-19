import CoreGraphics
import Testing

@testable import SwapjutsuPrep

/// The tracking crop's geometry: the union of boxes, the margin, the square widening, clamping to the frame, and
/// masks into and out of the crop. Boxes are bottom-left (as `PersonDetection.box`), crops top-down.
struct TrackingCropTests {
    @Test func unionWithMarginWidenedToSquare() {
        // Union x 100–250, y 100–350 (150 × 250); margin 0.1 × 250 = 25 → 200 × 300, widened to 300 × 300.
        let crop = TrackingCrop.around(
            [CGRect(x: 100, y: 100, width: 100, height: 200), CGRect(x: 150, y: 150, width: 100, height: 200)],
            frame: CGSize(width: 1000, height: 1000), margin: 0.1, minShare: 0)
        #expect(crop == TrackingCrop(x: 25, y: 625, width: 300, height: 300))
    }

    @Test func shiftedInsideTheFrameAtAnEdge() {
        // 120 × 120 around a box against the right edge: moved left to end at the frame's edge.
        let crop = TrackingCrop.around(
            [CGRect(x: 900, y: 200, width: 100, height: 100)], frame: CGSize(width: 1000, height: 500), margin: 0.1,
            minShare: 0)
        #expect(crop == TrackingCrop(x: 880, y: 190, width: 120, height: 120))
    }

    @Test func squareLimitedByANarrowFrame() {
        // A tall person in a portrait frame: the square would be 960 wide, the frame allows 540.
        let crop = TrackingCrop.around(
            [CGRect(x: 0, y: 100, width: 100, height: 800)], frame: CGSize(width: 540, height: 960), margin: 0.1,
            minShare: 0)
        #expect(crop == TrackingCrop(x: 0, y: 0, width: 540, height: 960))
    }

    @Test func smallPersonGetsTheMinimumSide() {
        let crop = TrackingCrop.around(
            [CGRect(x: 500, y: 250, width: 10, height: 10)], frame: CGSize(width: 1000, height: 500), margin: 0.1,
            minShare: 0.5)
        #expect(crop == TrackingCrop(x: 380, y: 120, width: 250, height: 250))
    }

    @Test func noCropWithoutABox() {
        #expect(TrackingCrop.around([], frame: CGSize(width: 100, height: 100), margin: 0.1, minShare: 0) == nil)
        #expect(TrackingCrop.around([.zero], frame: CGSize(width: 100, height: 100), margin: 0.1, minShare: 0) == nil)
    }

    @Test func masksIntoAndOutOfTheCrop() {
        // A 4 × 3 frame, the crop is the 2 × 2 block at column 1, row 1.
        let crop = TrackingCrop(x: 1, y: 1, width: 2, height: 2)
        let frame: [UInt8] = Array(0..<12)
        #expect(crop.cut(frame, frameWidth: 4) == [5, 6, 9, 10])
        #expect(crop.place([1, 2, 3, 4], frameWidth: 4, frameHeight: 3) == [0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0])
        #expect(crop.imageRect(frameHeight: 3) == CGRect(x: 1, y: 0, width: 2, height: 2))
        #expect(crop.fits(width: 4, height: 3))
        #expect(!crop.fits(width: 2, height: 3))
    }
}
