import AVFoundation
import CoreImage
import Synchronization
import Testing

@testable import SwapjutsuPrep

/// The stage seams: caches, input sizing, option checks, swapping a stage and cancelling a run.
@Suite struct StageTests {
    /// `CIImage(cvPixelBuffer:)` tags a one-channel half buffer as Gray Gamma 2.2 and linearises it (0.5 reads as
    /// 0.214). The cache must hand back the model's own values, the ones the control video is painted from.
    @Test func depthCacheKeepsRawValues() throws {
        let dir = try scratch("depth")
        defer { try? FileManager.default.removeItem(at: dir) }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_OneComponent16Half, nil, &made)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        let row = CVPixelBufferGetBytesPerRow(buffer) / 2
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float16.self)
        for i in 0..<(row * 4) { base[i] = 0.5 }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let cache = DepthCache(directory: dir)
        try cache.store(DepthMap(buffer: buffer, toFrame: .identity), frame: 0)
        let loaded = try cache.load(frame: 0, size: CGSize(width: 4, height: 4), format: .half)
        #expect(abs(pixel(loaded) - 0.5) < 1e-3)
    }

    @Test func maskCacheRoundTripsAndRefusesTruncation() throws {
        let dir = try scratch("masks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = MaskCache(directory: dir)
        let size = CGSize(width: 8, height: 6)
        try cache.store(
            CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size)), key: "0_0", context: CIContext())
        #expect(pixel(try cache.load(key: "0_0", size: size)) > 0.99)
        #expect(throws: PrepError.self) { try cache.load(key: "0_0", size: CGSize(width: 9, height: 6)) }
        #expect(throws: PrepError.self) { try cache.load(key: "1_0", size: size) }
    }

    /// Seedance rejects frames under 409,600 px; a small clip is scaled up to that, with even sides.
    @Test func aSmallClipIsUpscaledForSeedance() async throws {
        let dir = try scratch("small")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await writeClip(in: dir, size: CGSize(width: 320, height: 180), seconds: 1)
        let source = try await VideoSource.open(clip, tuning: Tuning())
        #expect(source.upscaled)
        #expect(source.size.width * source.size.height >= Tuning().minPixels)
        #expect(Int(source.size.width) % 2 == 0 && Int(source.size.height) % 2 == 0)
        #expect(abs(source.size.width / source.size.height - 16 / 9) < 0.01)
    }

    @Test func impossibleOptionsAreRefusedUpFront() {
        var options = PrepOptions()
        options.tuning.maxSeconds = 99
        #expect(throws: PrepError.self) { try options.validate() }
        options.tuning.maxSeconds = .nan
        #expect(throws: PrepError.self) { try options.validate() }
        options = PrepOptions()
        options.target = .ids([0])
        #expect(throws: PrepError.self) { try options.validate() }
        #expect(throws: Never.self) { try PrepOptions().validate() }
    }

    /// Any stage can be replaced: here a segmenter that never finds anyone, and a flat depth model, so the run needs
    /// no Vision people and no Core ML model, and must end in exactly `noPerson`.
    @Test func aSwappedSegmenterDrivesTheRun() async throws {
        let dir = try scratch("swap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await writeClip(in: dir, size: CGSize(width: 854, height: 480), seconds: 4.2)
        var stages = PrepStages.standard(tuning: Tuning(), depthModel: URL(filePath: "/dev/null"))
        stages.shots = NoCuts()
        stages.orientation = AsFilmed()
        stages.people = Nobody()
        stages.depth = { FlatDepth() }
        let pipeline = Pipeline(options: PrepOptions(), stages: stages)
        await #expect(throws: PrepError.noPerson) {
            try await pipeline.run(video: clip, output: dir.appending(path: "out"))
        }
    }

    /// Cancelling the task that awaits `run` stops it within a frame or two and leaves no control video. Counted in
    /// frames, not seconds: a loaded runner may take a while to get to the cancel, but not to more frames.
    @Test func cancellingStopsTheRun() async throws {
        let dir = try scratch("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await writeClip(in: dir, size: CGSize(width: 854, height: 480), seconds: 4.2)
        var stages = PrepStages.standard(tuning: Tuning(), depthModel: URL(filePath: "/dev/null"))
        // Stand-ins only: a cold Vision model load would measure Vision, not the pipeline's cancellation. The optical
        // flow is Vision too, and an in-flight request cannot be interrupted, so it stays off.
        stages.shots = NoCuts()
        stages.orientation = AsFilmed()
        let people = Slow()
        stages.people = people
        stages.depth = { FlatDepth() }
        var options = PrepOptions()
        options.tuning.depthSmoothing = 0
        let out = dir.appending(path: "out")
        let run = Task { [options] in
            try await Pipeline(options: options, stages: stages).run(video: clip, output: out)
        }
        try await Task.sleep(for: .milliseconds(300))
        let analysed = people.frames
        run.cancel()
        let result = await run.result
        #expect(people.frames - analysed <= 2, "\(people.frames - analysed) frames after the cancel")
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "control.mp4").path))
    }

    @Test func aCharacterImageWithoutAPersonIsLeftAlone() throws {
        let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
        let plain = try #require(CIContext().createCGImage(CIImage(color: .gray).cropped(to: rect), from: rect))
        #expect(try VisionCutout().cutout(plain) == nil)
    }

    @Test func cutoutFramesStayWithinSeedancesAspect() {
        let tall = VisionCutout.frame(CGRect(x: 100, y: 0, width: 100, height: 1000))
        let wide = VisionCutout.frame(CGRect(x: 0, y: 100, width: 1000, height: 100))
        #expect(tall.width == 500 && tall.midX == 150)
        #expect(wide.height == 500 && wide.midY == 150)
    }

    // MARK: Mask tracking
    //
    // A two-shot clip (written at 12 fps; prep reads it at 24) with two stand-in people: A (identity 1,
    // larger, left) and B (identity 2, right). Vision misses A on frames 10–12, and A moves right in the second shot.
    // The stand-in tracker echoes each object's seed mask on every frame of its shot, or loses the objects in
    // `loses`.

    /// The tracker's masks reach mask.mp4, including frames Vision missed, and each shot is seeded afresh. B, which
    /// the tracker loses, falls back to Vision for its own shots only, with the reason in the manifest.
    @Test func aTrackerRecoversFramesVisionMissedAndALostTargetFallsBack() async throws {
        let tracker = Echo(loses: [2])
        let (manifest, mask) = try await trackedRun(tracker)
        let tracking = try #require(manifest.tracking)
        #expect(tracking.tracker == "Echo" && tracking.unavailable == nil)
        for shot in tracking.shots {
            let (source, fallback) = shot.target == 1 ? ("tracked", nil) : ("vision", "lost")
            #expect(shot.source == source && shot.fallback == fallback)
        }
        #expect(tracking.shots.first { $0.shot == 0 && $0.target == 1 }?.recoveredFrames == 3)
        #expect(mask(11, Self.aLeft) > 0.5, "A is in mask.mp4 on a frame only the tracker has")
        #expect(mask(11, Self.b) > 0.5, "B keeps Vision's mask")
        // Shot reset: the second shot starts over from its own seeds, where A has moved.
        #expect(tracker.shots == 2)
        #expect(tracker.seeded == [[1, 2], [1, 2]])
        #expect(mask(35, Self.aRight) > 0.5 && mask(35, Self.aLeftOnly) < 0.5)
        // Each target is tracked in a crop around its boxes in that shot (A at x 180–400 in the second).
        let a = try #require(tracker.crops.last?[1])
        #expect(a.x <= 180 && a.x + a.width >= 400 && a.x + a.width < 600)
        #expect(tracking.shots.allSatisfy { $0.crop != nil })
    }

    /// A tracker that cannot load leaves Vision's masks, as no tracker does: the frames Vision missed stay empty,
    /// with the reason in the manifest.
    @Test func aTrackerThatCannotLoadKeepsVisionMasks() async throws {
        let (failed, mask) = try await trackedRun(nil, load: { throw PrepError.model("no models") })
        #expect(failed.tracking?.tracker == nil)
        #expect(failed.tracking?.unavailable?.contains("no models") == true)
        #expect(mask(11, Self.aLeft) < 0.5 && mask(15, Self.aLeft) > 0.5)
    }

    static let aLeft = CGPoint(x: 150, y: 240)
    static let aLeftOnly = CGPoint(x: 120, y: 240)
    static let aRight = CGPoint(x: 400, y: 240)
    static let b = CGPoint(x: 680, y: 240)

    /// Runs the two-shot clip with `tracker` (or `load`) and returns the manifest and a reader of mask.mp4's value at
    /// a frame and point.
    private func trackedRun(
        _ tracker: Echo?, load: (() async throws -> any MaskTracking)? = nil
    ) async throws -> (Manifest, (Int, CGPoint) -> Float) {
        let dir = try scratch("track")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = try await writeClip(in: dir, size: CGSize(width: 854, height: 480), seconds: 4.2, fps: 12)
        var stages = PrepStages.standard(tuning: Tuning(), depthModel: URL(filePath: "/dev/null"))
        stages.shots = CutAt(frame: 25)
        stages.orientation = AsFilmed()
        stages.people = TwoPeople()
        stages.faces = NoFaces()
        stages.appearance = ColourBySide()
        stages.depth = { FlatDepth() }
        stages.voice = nil
        if let tracker { stages.tracking = { tracker } } else { stages.tracking = load }
        var options = PrepOptions()
        options.target = .all
        options.review = false
        options.tuning.pitchSemitones = 0
        options.tuning.isolateVoice = false
        // Vision's hand and body pose and optical flow aren't what these tests check. The body pose model alone takes
        // half a minute to load on a fresh runner.
        options.tuning.handLift = 0
        options.tuning.depthSmoothing = 0
        options.matteOutline = true
        let out = dir.appending(path: "out")
        let manifest = try await Pipeline(options: options, stages: stages).run(video: clip, output: out)
        #expect(manifest.identities.count == 2)
        let source = try await VideoSource.open(out.appending(path: "mask.mp4"), tuning: Tuning())
        let context = CIContext()
        var values: [Int: [Float]] = [:]
        try await source.forEachFrame { n, frame in
            var row = [Float](repeating: 0, count: 854 * 4)
            context.render(
                frame, toBitmap: &row, rowBytes: 854 * 16, bounds: CGRect(x: 0, y: 240, width: 854, height: 1),
                format: .RGBAf, colorSpace: nil)
            values[n] = row
        }
        let read = { (n: Int, p: CGPoint) -> Float in values[n].map { $0[Int(p.x) * 4] } ?? -1 }
        return (manifest, read)
    }

    /// Echoes each object's seed on every frame of its shot; objects in `loses` are never seen after their seed.
    private final class Echo: MaskTracking {
        let name = "Echo"
        let loses: Set<Int>
        private var objects: [Int: [UInt8]] = [:]
        private(set) var shots = 0
        private(set) var seeded: [[Int]] = []
        private(set) var crops: [[Int: TrackingCrop]] = []

        init(loses: Set<Int> = []) { self.loses = loses }

        func startShot(crops: [Int: TrackingCrop]) {
            objects = [:]
            self.crops.append(crops)
            shots += 1
            seeded.append([])
        }

        func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
            var out: [Int: TrackedMask] = [:]
            for (id, mask) in objects {
                out[id] = loses.contains(id) ? TrackedMask(score: -1, mask: nil) : TrackedMask(score: 1, mask: mask)
            }
            for (id, mask) in seeds {
                objects[id] = mask
                seeded[seeded.count - 1] = (seeded[seeded.count - 1] + [id]).sorted()
                out[id] = TrackedMask(score: 1, mask: mask)
            }
            return out
        }
    }

    /// A at x 80–300 in the first shot and 180–400 in the second (missing on frames 10–12), B at x 600–750.
    private final class TwoPeople: PersonSegmenting {
        private var frame = 0

        func analyse(_ image: CIImage) throws -> FrameAnalysis {
            defer { frame += 1 }
            let e = image.extent
            let a = CGRect(x: frame < 25 ? 80 : 180, y: 60, width: 220, height: 360)
            let b = CGRect(x: 600, y: 90, width: 150, height: 300)
            let boxes = (10...12).contains(frame) ? [b] : [a, b]
            let black = CIImage(color: .black).cropped(to: e)
            return FrameAnalysis(
                people: boxes.map { CIImage(color: .white).cropped(to: $0).composited(over: black) },
                humans: boxes.map {
                    CGRect(
                        x: $0.minX / e.width, y: $0.minY / e.height, width: $0.width / e.width,
                        height: $0.height / e.height)
                }, faces: [])
        }
    }

    private final class CutAt: ShotDetecting {
        let frame: Int
        private var n = 0
        init(frame: Int) { self.frame = frame }
        func isCut(_ image: CIImage) throws -> Bool {
            defer { n += 1 }
            return n == frame
        }
    }

    private struct NoFaces: FaceLocating {
        func face(
            in frame: CIImage, person: MaskGrid, personBox: CGRect, frameFaces: [DetectedFace]
        ) throws
            -> FaceLandmarks?
        { nil }
    }

    /// Left of centre is one look, right of centre another.
    private struct ColourBySide: AppearanceDescribing {
        func appearance(of frame: CIImage, mask: CIImage, box: CGRect) throws -> Appearance {
            var colour = [Float](repeating: 0, count: 192)
            colour[box.midX < frame.extent.midX ? 0 : 1] = 1
            return Appearance(colour: colour)
        }
    }

    private struct AsFilmed: OrientationProbing {
        func votes(_ frames: [CIImage]) throws -> [Int: Double] { [:] }
    }

    private struct NoCuts: ShotDetecting {
        mutating func isCut(_ frame: CIImage) throws -> Bool { false }
    }

    private struct Nobody: PersonSegmenting {
        func analyse(_ frame: CIImage) throws -> FrameAnalysis { FrameAnalysis(people: [], humans: [], faces: []) }
    }

    private final class Slow: PersonSegmenting, Sendable {
        private let count = Mutex(0)
        var frames: Int { count.withLock { $0 } }

        func analyse(_ frame: CIImage) throws -> FrameAnalysis {
            count.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.05)
            return FrameAnalysis(people: [], humans: [], faces: [])
        }
    }

    private struct FlatDepth: DepthEstimating {
        func depth(of frame: CIImage) throws -> DepthMap {
            var made: CVPixelBuffer?
            CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_OneComponent16Half, nil, &made)
            guard let buffer = made else { throw PrepError.model("no buffer") }
            let scale = CGAffineTransform(scaleX: frame.extent.width / 8, y: frame.extent.height / 8)
            return DepthMap(buffer: buffer, toFrame: scale)
        }
    }

    private func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swapjutsu-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeClip(in dir: URL, size: CGSize, seconds: Double, fps: Int32 = 24) async throws -> URL {
        let url = dir.appending(path: "clip.mp4")
        let writer = try VideoWriter(url: url, size: size, fps: fps, context: CIContext())
        for _ in 0..<Int((seconds * Double(fps)).rounded(.up)) {
            try writer.append(CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)))
        }
        try await writer.finish()
        return url
    }

    private func pixel(_ image: CIImage) -> Float {
        var values = [Float](repeating: 0, count: 4)
        CIContext().render(
            image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
            colorSpace: nil)
        return values[0]
    }
}
