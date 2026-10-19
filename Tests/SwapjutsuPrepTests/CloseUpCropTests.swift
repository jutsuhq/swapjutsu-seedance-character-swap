import CoreImage
import Testing

@testable import SwapjutsuPrep

/// The face close-up (`FaceCloseUp`): a square around a small face, inside the image, and none for a face large
/// enough already, too small to enlarge, or not there.
struct CloseUpCropTests {
    private let size = CGSize(width: 1024, height: 1536)

    /// The full-body reference: 1024 × 1536 with a 120 px face near the top, about 8 % of the height.
    @Test func aSmallFaceGetsASquareAroundIt() throws {
        let crop = try #require(FaceCloseUp().crop(face: CGRect(x: 452, y: 1300, width: 120, height: 124), in: size))
        #expect(crop.width == crop.height && crop.width == 272)
        #expect(abs(crop.midX - 512) <= 1 && abs(crop.midY - 1362) <= 1)
    }

    @Test func theCloseUpStaysInsideTheImage() throws {
        let corner = try #require(FaceCloseUp().crop(face: CGRect(x: 0, y: 1440, width: 90, height: 90), in: size))
        #expect(corner.minX == 0 && corner.maxY == 1536 && corner.width == 198)
        // A face wider than the image allows: no larger than the shorter side.
        let wide = try #require(
            FaceCloseUp().crop(face: CGRect(x: 100, y: 100, width: 300, height: 300), in: CGSize(width: 500, height: 2000)))
        #expect(wide == CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    @Test func largeOrTinyFacesGetNone() {
        // A portrait: the face is 40 % of the height.
        #expect(FaceCloseUp().crop(face: CGRect(x: 300, y: 600, width: 500, height: 614), in: size) == nil)
        #expect(FaceCloseUp().crop(face: CGRect(x: 500, y: 1400, width: 40, height: 40), in: size) == nil)
    }

    @Test func anImageWithoutAFaceGetsNone() throws {
        let image = try #require(
            CIContext().createCGImage(
                CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.2)), from: CGRect(x: 0, y: 0, width: 400, height: 600)
            ))
        #expect(try FaceCloseUp().closeUp(image) == nil)
    }
}
