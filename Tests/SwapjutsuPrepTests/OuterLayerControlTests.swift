import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// The performer's silhouette from their skeleton and box (`BodyOutline`), with their depth carried into it
/// (`ControlRenderer.filled`), and a replaced background that keeps only the old place's coarse layout
/// (`ControlRenderer.settledGrey`).
struct OuterLayerControlTests {
    let side = 128
    var extent: CGRect { CGRect(x: 0, y: 0, width: side, height: side) }
    let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())

    /// A box in Core Image's coordinates, white on black.
    func box(_ rect: CGRect, in extent: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: rect).composited(over: CIImage(color: .black).cropped(to: extent))
    }

    /// The pixel at `x`, `y` (origin bottom-left, as Core Image has it).
    func pixel(_ image: CIImage, _ x: Int, _ y: Int, width: Int? = nil, height: Int? = nil) -> [Int] {
        let (w, h) = (width ?? side, height ?? side)
        let pixels = renderRGBA(image, width: w, height: h, context: CIContext())
        let k = ((h - 1 - y) * w + x) * 4
        return (0..<3).map { Int(pixels[k + $0]) }
    }

    /// A person standing, facing the camera, shoulders 40 px apart at y 100, hips at y 60, knees 35, ankles 10, arms
    /// down to the wrists at y 55; a matte as narrow as a tight top, and a bag hanging off the left hand.
    let skeleton = BodyOutline(joints: [
        .nose: CGPoint(x: 64, y: 112), .neck: CGPoint(x: 64, y: 102),
        .leftShoulder: CGPoint(x: 84, y: 100), .rightShoulder: CGPoint(x: 44, y: 100),
        .leftElbow: CGPoint(x: 88, y: 78), .rightElbow: CGPoint(x: 40, y: 78),
        .leftWrist: CGPoint(x: 90, y: 55), .rightWrist: CGPoint(x: 38, y: 55),
        .leftHip: CGPoint(x: 76, y: 60), .rightHip: CGPoint(x: 52, y: 60), .root: CGPoint(x: 64, y: 60),
        .leftKnee: CGPoint(x: 76, y: 35), .rightKnee: CGPoint(x: 52, y: 35),
        .leftAnkle: CGPoint(x: 76, y: 10), .rightAnkle: CGPoint(x: 52, y: 10),
    ])

    @Test func theSilhouetteComesFromTheSkeletonNotTheClothes() throws {
        let person = CGRect(x: 36, y: 6, width: 56, height: 116)
        let body = box(CGRect(x: 50, y: 10, width: 28, height: 106), in: extent)
        let bag = box(CGRect(x: 108, y: 30, width: 14, height: 20), in: extent)
        let matte = body.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: bag])
        let silhouette = try #require(skeleton.silhouette(matte: matte, box: person))
        let at = { (x: Int, y: Int) in pixel(silhouette, x, y)[0] }
        // Past the tight matte: beside the torso, where a coat or robe hangs, and round the arms.
        #expect(at(92, 85) > 200 && at(40, 70) > 200 && at(88, 62) > 200)
        // The matte stays whole, the bag Vision's skeleton knows nothing of too; nothing else passes the grown box.
        #expect(at(64, 112) > 200 && at(115, 40) > 200)
        #expect(at(125, 85) < 30)
        // The forearm ends at the wrist: no hand-sized round end past it.
        #expect(at(36, 48) < 30 && at(36, 58) > 200)
        #expect(at(20, 60) < 30)
        // A skeleton on the person (the arms on the person's grid, as a whole person's are) fits its grid; one
        // beside it does not.
        let arms = box(CGRect(x: 34, y: 50, width: 60, height: 54), in: extent)
        let whole = body.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: arms])
        let grid = MaskGrid(mask: whole, side: 32, context: CIContext())
        #expect(skeleton.fits(grid, size: extent.size))
        let beside = BodyOutline(joints: skeleton.joints.mapValues { CGPoint(x: $0.x + 50, y: $0.y) })
        #expect(!beside.fits(grid, size: extent.size))
        // No unit, no outline.
        #expect(BodyOutline(joints: [.nose: CGPoint(x: 5, y: 5)]).silhouette(matte: matte, box: person) == nil)
    }

    /// The rim of glasses standing out of a head seen side on is outside the matte; the disc round the eye paints
    /// it, and nothing far from the eye.
    @Test func theEyesDiscsCoverGlassesPastTheMatte() throws {
        var face = skeleton
        face.joints[.leftEye] = CGPoint(x: 60, y: 114)
        let person = CGRect(x: 36, y: 6, width: 56, height: 116)
        let head = box(CGRect(x: 58, y: 104, width: 16, height: 18), in: extent)
        let matte = box(CGRect(x: 52, y: 10, width: 24, height: 94), in: extent)
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: head])
        let silhouette = try #require(face.silhouette(matte: matte, box: person))
        let at = { (x: Int, y: Int) in pixel(silhouette, x, y)[0] }
        // In front of the eye, past the head's side, where the rim stands out; not far past it, nor above the head.
        #expect(at(54, 114) > 200 && pixel(matte, 54, 114)[0] < 30)
        #expect(at(46, 114) < 30 && at(66, 127) < 30)
    }

    /// A frame without a skeleton takes the found ones before and after, moved with the person and mixed by how
    /// near each is; outside them the nearest; another shot nothing.
    @Test func aFrameWithoutASkeletonTakesItsNeighbours() throws {
        var track = BodyOutline.Track()
        let raised = skeleton.moved(by: CGVector(dx: 0, dy: 10))
        track.add(skeleton, identity: 1, shot: 0, frame: 0, anchor: CGPoint(x: 64, y: 64))
        track.add(raised, identity: 1, shot: 0, frame: 10, anchor: CGPoint(x: 64, y: 64))
        // Halfway: 5 px up, and 20 px right with the person.
        let found = track.outline(identity: 1, shot: 0, frame: 5, anchor: CGPoint(x: 84, y: 64))
        let middle = try #require(found)
        let nose = try #require(middle.joints[.nose])
        #expect(abs(nose.x - 84) < 0.001 && abs(nose.y - 117) < 0.001)
        let late = track.outline(identity: 1, shot: 0, frame: 30, anchor: CGPoint(x: 64, y: 64))
        #expect(late == raised.armless)
        // A guessed frame has no arms; a found one keeps them.
        #expect(middle.joints[.leftWrist] == nil && middle.joints[.rightElbow] == nil && middle.joints[.neck] != nil)
        let own = track.outline(identity: 1, shot: 0, frame: 10, anchor: CGPoint(x: 64, y: 64))
        #expect(own?.joints[.leftWrist] != nil)
        let otherShot = track.outline(identity: 1, shot: 1, frame: 5, anchor: CGPoint(x: 64, y: 64))
        let otherPerson = track.outline(identity: 2, shot: 0, frame: 5, anchor: CGPoint(x: 64, y: 64))
        #expect(otherShot == nil && otherPerson == nil)
    }

    /// Past the matte the silhouette takes the person's own depth, not the background's.
    @Test func theSilhouetteTakesThePersonsDepth() throws {
        let range = try #require(ShotDepthRange([0...1]))
        var values = [Float](repeating: 0.1, count: side * side)
        for y in 0..<side { for x in 50..<78 { values[y * side + x] = 0.7 } }
        let depth = CIImage(
            bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: side * 4,
            size: CGSize(width: side, height: side), format: .Rf, colorSpace: nil)
        let matte = box(CGRect(x: 50, y: 0, width: 28, height: side), in: extent)
        let filled = renderer.filled(depth, matte: matte, range: range, sigma: 16)
        let red = { (image: CIImage, x: Int) -> Float in
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(
                image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: 64, width: 1, height: 1),
                format: .RGBAf, colorSpace: nil)
            return pixel[0]
        }
        #expect(abs(red(filled, 86) - 0.7) < 0.02)
        #expect(abs(red(filled, 64) - 0.7) < 0.001)
    }

    /// A thin near thing (a bicycle) goes, the sky at the far end reads no farther than `settledFar`, and the
    /// person's near depth beside the background never brightens it.
    @Test func theReplacedBackgroundKeepsOnlyItsCoarseLayout() throws {
        let (width, height) = (240, 120)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let range = try #require(ShotDepthRange([0...1]))
        func image(_ values: [Float]) -> CIImage {
            CIImage(
                bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 4,
                size: CGSize(width: width, height: height), format: .Rf, colorSpace: nil)
        }
        func flat(_ value: Float) -> CIImage { image([Float](repeating: value, count: width * height)) }
        func depth(person: Float) -> CIImage {
            var values = [Float](repeating: 0.5, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    // Rows top-down: the sky over the top 30 rows, a 3 px pole at x 60, the person at x 150–190.
                    if y < 30 { values[y * width + x] = 0 }
                    if (60..<63).contains(x), y >= 30 { values[y * width + x] = 0.95 }
                    if (150..<190).contains(x), y >= 30 { values[y * width + x] = person }
                }
            }
            return image(values)
        }
        let people = box(CGRect(x: 150, y: 0, width: 40, height: 90), in: extent)
        let at = { (image: CIImage, x: Int, y: Int) in pixel(image, x, y, width: width, height: height)[0] }
        let plain = renderer.greyDepth(depth(person: 0.5), range: range)
        let settled = renderer.settledGrey(depth(person: 1), range: range, people: people)
        // The pole: a bright stripe before, gone after.
        #expect(at(plain, 61, 50) - at(plain, 40, 50) > 60)
        #expect(abs(at(settled, 61, 50) - at(settled, 40, 50)) < 12)
        // The sky: the far end before, at least `settledFar` after.
        let floor = renderer.greyDepth(flat(0.25), range: range)
        #expect(at(plain, 20, 110) < at(floor, 20, 110) - 10)
        #expect(at(settled, 20, 110) >= at(floor, 20, 110) - 1)
        // Beside the person, the background as without the person's near depth.
        let without = renderer.settledGrey(depth(person: 0.5), range: range, people: people)
        #expect(abs(at(settled, 140, 50) - at(without, 140, 50)) <= 1)
    }
}
