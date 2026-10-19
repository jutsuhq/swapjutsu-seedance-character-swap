import CoreImage
import Foundation
import Testing

@testable import SwapjutsuPrep

/// Shots filmed sideways (`Upright`): the turns themselves, and a run on a clip whose pixels lie on their side.
struct UprightTests {
    let context = CIContext()

    /// Mask bytes turn like the pixels: clockwise, the top-left pixel of a 4 × 2 frame goes to the top-right of the
    /// 2 × 4 upright frame, and turning back restores every byte.
    @Test func bytesTurnClockwiseAndBack() {
        let size = CGSize(width: 4, height: 2)
        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let right = Upright(degrees: 90, size: size)
        #expect(right.upright(bytes: bytes) == [5, 1, 6, 2, 7, 3, 8, 4])
        #expect(Upright(degrees: 180, size: size).upright(bytes: bytes) == [8, 7, 6, 5, 4, 3, 2, 1])
        #expect(Upright(degrees: 270, size: size).upright(bytes: bytes) == [4, 8, 3, 7, 2, 6, 1, 5])
        for degrees in [0, 90, 180, 270] {
            let u = Upright(degrees: degrees, size: size)
            #expect(u.source(bytes: u.upright(bytes: bytes)) == bytes)
        }
    }

    /// Images, rectangles, points and crops all turn the same way as the bytes.
    @Test func imagesRectsPointsAndCropsAgreeWithTheBytes() {
        let size = CGSize(width: 6, height: 4)
        // One white pixel at column 1, row 0 from the top: (1, 3) with the origin at the bottom left.
        let dot = CGRect(x: 1, y: 3, width: 1, height: 1)
        let frame = CIImage(color: .white).cropped(to: dot)
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[1] = 255
        let crop = TrackingCrop(x: 1, y: 0, width: 2, height: 3)
        for degrees in [0, 90, 180, 270] {
            let u = Upright(degrees: degrees, size: size)
            let turned = u.upright(frame)
            #expect(turned.extent == CGRect(origin: .zero, size: u.uprightSize))
            let rendered = gray(turned)
            #expect(rendered == u.upright(bytes: bytes).map { $0 > 127 }, "image vs bytes at \(degrees)°")
            #expect(gray(u.source(turned)) == bytes.map { $0 > 127 }, "image round trip at \(degrees)°")
            // The dot's rectangle from upright pixels back to the source.
            let up = dot.applying(u.toUpright)
            #expect(u.source(up).equalTo(dot))
            // The top-down centre of the dot and a crop around it land on the upright byte.
            let p = u.upright(topDown: CGPoint(x: 1.5, y: 0.5))
            let w = Int(u.uprightSize.width)
            #expect(u.upright(bytes: bytes)[Int(p.y) * w + Int(p.x)] == 255)
            let c = u.upright(crop)
            #expect(c.fits(width: w, height: Int(u.uprightSize.height)))
            let cut = Upright(degrees: degrees, size: CGSize(width: crop.width, height: crop.height))
            #expect(c.cut(u.upright(bytes: bytes), frameWidth: w) == cut.upright(bytes: crop.cut(bytes, frameWidth: 6)))
        }
    }

    /// The tracker sees the turned frame, seed, crop and click, and its masks come back in the source's frame.
    @Test func theTrackerSeesTheShotUpright() throws {
        let size = CGSize(width: 6, height: 4)
        let frame = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        var seed = [UInt8](repeating: 0, count: 24)
        seed[1] = 255
        let base = Recorder()
        let tracker = UprightTracking(base)
        let crop = TrackingCrop(x: 1, y: 0, width: 2, height: 3)
        tracker.startShot(crops: [1: crop], upright: Upright(degrees: 90, size: size))
        let out = try tracker.step(frame, seeds: [1: seed])
        #expect(base.sizes == [CGSize(width: 4, height: 6)])
        #expect(base.crops == [Upright(degrees: 90, size: size).upright(crop)])
        #expect(out[1]?.mask == seed, "the echoed seed comes back where it was")
        // A click at the seed's pixel (top-down 1.5, 0.5) lands on it in the upright frame and comes back there.
        #expect(try tracker.mask(at: CGPoint(x: 1.5, y: 0.5), on: frame, crop: nil) == seed)
        // As filmed: nothing is turned.
        tracker.startShot(crops: [:])
        _ = try tracker.step(frame, seeds: [1: seed])
        #expect(base.sizes.last == size)
    }

    /// Echoes its seeds; a click becomes a one-pixel mask there.
    private final class Recorder: MaskTracking {
        let name = "Recorder"
        private(set) var sizes: [CGSize] = []
        private(set) var crops: [TrackingCrop] = []

        func startShot(crops: [Int: TrackingCrop]) { self.crops += crops.values }

        func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
            sizes.append(frame.extent.size)
            return seeds.mapValues { TrackedMask(score: 1, mask: $0) }
        }

        func mask(at point: CGPoint, on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
            let w = Int(frame.extent.width)
            var mask = [UInt8](repeating: 0, count: w * Int(frame.extent.height))
            mask[Int(point.y) * w + Int(point.x)] = 255
            return mask
        }
    }

    /// The turn a shot takes: one turn must clearly beat the shot as filmed, and enough votes must back it.
    @Test func aShotTurnsOnlyOnClearVotes() {
        let tuning = Tuning()
        #expect(Pipeline.turn([90: 3, 0: 0.5], tuning: tuning) == 90)
        #expect(Pipeline.turn([90: 3, 0: 2], tuning: tuning) == 0, "under twice the votes as filmed")
        #expect(Pipeline.turn([270: 0.5], tuning: tuning) == 0, "too few votes")
        #expect(Pipeline.turn([:], tuning: tuning) == 0)
    }

    /// A person lying on their side, as a selfie filmed with the phone sideways and saved without a rotation tag.
    /// The stand-in segmenter only finds people standing up, as Vision's masks follow people standing up. The shot
    /// is found turned 90°, the person is found in every frame as in the same clip filmed upright, and mask.mp4
    /// and control.mp4 keep the source's frame with the person where they lie.
    @Test func aSidewaysClipIsTurnedForThePeopleAndKeepsItsFrame() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-upright-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scene = Self.standing(CGSize(width: 480, height: 864))
        let sideways = scene.transformed(by: Upright(degrees: 90, size: CGSize(width: 864, height: 480)).toSource)

        let upright = try await run(scene, in: dir.appending(path: "upright"))
        let turned = try await run(sideways, in: dir.appending(path: "sideways"))
        #expect(upright.manifest.shots.map(\.orientation) == [0])
        #expect(turned.manifest.shots.map(\.orientation) == [90])
        #expect(upright.manifest.quality.targetPresence == 1)
        #expect(turned.manifest.quality.targetPresence == upright.manifest.quality.targetPresence)
        #expect(turned.manifest.width == 864 && turned.manifest.height == 480)
        #expect(turned.controlSize == CGSize(width: 864, height: 480))
        // The body lies at x 264–764, y 180–300 (top-down) in the sideways frame; the far corner is empty.
        #expect(turned.mask(CGPoint(x: 514, y: 240)) > 0.5)
        #expect(turned.mask(CGPoint(x: 60, y: 40)) < 0.5)
    }

    private struct Run {
        let manifest: Manifest
        let controlSize: CGSize
        /// mask.mp4's value on its middle frame at a point (rows top-down).
        let mask: (CGPoint) -> Float
    }

    private func run(_ frame: CIImage, in dir: URL) async throws -> Run {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clip = dir.appending(path: "clip.mp4")
        // 4.2 s, the least prep takes.
        let writer = try VideoWriter(url: clip, size: frame.extent.size, fps: 12, context: context)
        for _ in 0..<51 { try writer.append(frame) }
        try await writer.finish()

        var stages = PrepStages.standard(tuning: Tuning(), depthModel: URL(filePath: "/dev/null"))
        stages.shots = NoCuts()
        stages.orientation = StandingProbe(context: context)
        stages.people = StandingOnly(context: context)
        stages.faces = NoFaces()
        stages.appearance = OneLook()
        stages.depth = { FlatDepth() }
        stages.voice = nil
        var options = PrepOptions()
        options.review = false
        options.tuning.pitchSemitones = 0
        options.tuning.isolateVoice = false
        options.tuning.depthSmoothing = 0
        options.tuning.handLift = 0
        // No skeleton: the body pose model takes half a minute to load on a fresh runner, and the mask is what counts.
        options.matteOutline = true
        let out = dir.appending(path: "out")
        let manifest = try await Pipeline(options: options, stages: stages).run(video: clip, output: out)

        let control = try await VideoSource.open(out.appending(path: "control.mp4"), tuning: Tuning())
        let mask = try await VideoSource.open(out.appending(path: "mask.mp4"), tuning: Tuning())
        var middle: [UInt8] = []
        let size = mask.size
        try await mask.forEachFrame(in: 25..<26) { _, image in
            middle = renderRGBA(image, width: Int(size.width), height: Int(size.height), context: context)
        }
        let read = { (p: CGPoint) -> Float in Float(middle[(Int(p.y) * Int(size.width) + Int(p.x)) * 4]) / 255 }
        return Run(manifest: manifest, controlSize: control.size, mask: read)
    }

    /// A standing person on dark grey: a white body at x 180–300, y 100–600 (origin bottom left) under a red head.
    static func standing(_ size: CGSize) -> CIImage {
        let body = CIImage(color: .white).cropped(to: CGRect(x: 180, y: 100, width: 120, height: 500))
        let head = CIImage(color: .red).cropped(to: CGRect(x: 200, y: 620, width: 80, height: 80))
        return head.composited(over: body)
            .composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: size)))
    }

    /// Whether `frame` (at a 1/8 scale) holds a red head above a white body, and the person's unit box.
    static func standingPerson(_ frame: CIImage, context: CIContext) -> CGRect? {
        let w = Int(frame.extent.width) / 8, h = Int(frame.extent.height) / 8
        let pixels = renderRGBA(frame, width: w, height: h, context: context)
        var head: [CGPoint] = [], body: [CGPoint] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard pixels[i] > 200 else { continue }
                (pixels[i + 1] > 200 ? { body.append(CGPoint(x: x, y: y)) } : { head.append(CGPoint(x: x, y: y)) })()
            }
        }
        guard let headTop = head.map(\.y).min(), let bodyTop = body.map(\.y).min(), headTop < bodyTop else {
            return nil
        }
        let all = head + body
        let (x0, x1) = (all.map(\.x).min() ?? 0, (all.map(\.x).max() ?? 0) + 1)
        let (y0, y1) = (all.map(\.y).min() ?? 0, (all.map(\.y).max() ?? 0) + 1)
        let (fw, fh) = (CGFloat(w), CGFloat(h))
        return CGRect(x: x0 / fw, y: 1 - y1 / fh, width: (x1 - x0) / fw, height: (y1 - y0) / fh)
    }

    /// Finds the person, the white and red pixels, only when they stand upright.
    private struct StandingOnly: PersonSegmenting {
        let context: CIContext

        func analyse(_ frame: CIImage) throws -> FrameAnalysis {
            guard let box = UprightTests.standingPerson(frame, context: context) else {
                return FrameAnalysis(people: [], humans: [], faces: [])
            }
            // Red is high in both the body and the head, low on the grey.
            let mask = frame.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                ]
            )
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5]).cropped(to: frame.extent)
            return FrameAnalysis(people: [mask], humans: [box], faces: [])
        }
    }

    /// Votes for each turn that stands the person up.
    private struct StandingProbe: OrientationProbing {
        let context: CIContext

        func votes(_ frames: [CIImage]) throws -> [Int: Double] {
            var votes: [Int: Double] = [:]
            for frame in frames {
                for degrees in [0, 90, 180, 270] {
                    let turned = Upright(degrees: degrees, size: frame.extent.size).upright(frame)
                    if UprightTests.standingPerson(turned, context: context) != nil { votes[degrees, default: 0] += 1 }
                }
            }
            return votes
        }
    }

    private struct NoCuts: ShotDetecting {
        mutating func isCut(_ frame: CIImage) throws -> Bool { false }
    }

    private struct NoFaces: FaceLocating {
        func face(
            in frame: CIImage, person: MaskGrid, personBox: CGRect, frameFaces: [DetectedFace]
        ) throws -> FaceLandmarks? { nil }
    }

    private struct OneLook: AppearanceDescribing {
        func appearance(of frame: CIImage, mask: CIImage, box: CGRect) throws -> Appearance {
            Appearance(colour: [Float](repeating: 1 / 192, count: 192))
        }
    }

    private struct FlatDepth: DepthEstimating {
        func depth(of frame: CIImage) throws -> DepthMap {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_OneComponent16Half, nil, &made)
            guard let buffer = made else { throw PrepError.model("no buffer") }
            return DepthMap(
                buffer: buffer, toFrame: CGAffineTransform(scaleX: frame.extent.width / 8, y: frame.extent.height / 8))
        }
    }

    /// Whether each pixel of `image` is light, rows top-down.
    private func gray(_ image: CIImage) -> [Bool] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        let pixels = renderRGBA(image, width: w, height: h, context: context)
        return stride(from: 0, to: w * h * 4, by: 4).map { pixels[$0] > 127 }
    }
}
