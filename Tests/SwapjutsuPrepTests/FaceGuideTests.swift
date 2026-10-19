import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// The face guide is drawn only on faces large enough to carry it, only where the person is painted, and the prompt
/// explains its lines only when some were drawn.
struct FaceGuideTests {
    let side = 32
    let renderer = ControlRenderer(tuning: Tuning(), context: CIContext())

    @Test func linesAreDrawnOnlyOnFacesLargeEnough() {
        var tuning = Tuning()
        tuning.faceGuideMinHeight = 0.05
        var tally = FaceGuideTally(tuning, frame: CGSize(width: 270, height: 480))
        #expect(tally.faces([face(height: 10), face(height: 40)]).map(\.height) == [40])
        #expect(tally.faces([face(height: 23)]).isEmpty)
        #expect(tally.faces([]).isEmpty)
        #expect(tally.frames == 1)
        #expect(tally.summary.hasPrefix("Face guide on 1 frames; target faces 2.1–8.3 %"))
    }

    /// Off: a real render drew the lines onto the face despite the prompt.
    @Test func theDefaultIsOff() {
        #expect(!PrepOptions().faceGuide)
    }

    /// A line across the whole frame shows on the painted target (x < 12) and nowhere on the background.
    @Test func linesStayInsideThePaintedTarget() throws {
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let range = try #require(ShotDepthRange([0...1]))
        let original = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: extent)
        let depth = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let bytes = (0..<side).flatMap { _ in (0..<side).map { $0 < 12 ? UInt8(255) : 0 } }
        let target = CIImage(
            bitmapData: Data(bytes), bytesPerRow: side, size: extent.size, format: .L8, colorSpace: nil)
        let masks = renderer.masks(
            targets: [(target, 1)], inFront: [], depth: depth, ramp: 0.05, objects: nil, extent: extent)
        let line = FaceLandmarks(regions: [
            .init(name: "faceContour", points: [CGPoint(x: 0, y: 16.5), CGPoint(x: 32, y: 16.5)], closed: false)
        ])
        let background = renderer.greyDepth(depth, range: range)
        for back in [nil, background] {
            let plain = rgba(
                try renderer.composite(original: original, background: back, depth: depth, range: range, masks: masks))
            let drawn = rgba(
                try renderer.composite(
                    original: original, background: back, depth: depth, range: range, masks: masks, faces: [line]))
            // Row 15 top-down is y 16 bottom-up, where the line runs.
            #expect(drawn[15][4].prefix(3).allSatisfy { $0 > 200 }, "\(drawn[15][4])")
            for x in 16..<side { #expect(drawn[15][x] == plain[15][x], "x \(x): \(drawn[15][x])") }
        }
    }

    @Test func thePromptExplainsTheLinesOnlyWhenSomeWereDrawn() {
        let pipeline = Pipeline(options: PrepOptions(), modelURL: URL(filePath: "/dev/null"))
        #expect(pipeline.seedancePrompt(people: 1, hasAudio: false, guided: true).contains("White lines on the faces"))
        #expect(!pipeline.seedancePrompt(people: 1, hasAudio: false, guided: false).contains("White lines"))
    }

    @Test func manifestsWithoutTheFaceGuideRecordDecode() throws {
        #expect(try manifest(extra: "").faceGuide == nil)
        let guide = try manifest(extra: #", "faceGuide": {"frames": 96, "minFaceHeight": 0.05}"#).faceGuide
        #expect(guide == Manifest.FaceGuide(frames: 96, minFaceHeight: 0.05))
    }

    // MARK: Helpers

    private func face(height: CGFloat) -> FaceLandmarks {
        FaceLandmarks(regions: [
            .init(name: "faceContour", points: [CGPoint(x: 0, y: 100), CGPoint(x: 10, y: 100 + height)], closed: false)
        ])
    }

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

    private func rgba(_ image: CIImage) -> [[[UInt8]]] {
        let pixels = renderRGBA(image, width: side, height: side, context: CIContext())
        return (0..<side).map { y in (0..<side).map { x in Array(pixels[(y * side + x) * 4..<(y * side + x) * 4 + 4]) }
        }
    }
}
