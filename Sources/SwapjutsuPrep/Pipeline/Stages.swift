import AVFoundation
import CoreImage

// The swap points of the prep. Each stage is one protocol with the macOS-native implementation as its default;
// another tool (SAM 3.1 masks, Video Depth Anything, htdemucs vocals…) replaces one stage by conforming to its
// protocol and being passed in `PrepStages`, without touching the pipeline or the other stages.

/// Finds shot cuts, one frame at a time, in order.
public protocol ShotDetecting {
    /// True when `frame` starts a new shot.
    mutating func isCut(_ frame: CIImage) throws -> Bool
}

/// Which way up the people in one shot stand, for shots filmed sideways (`Upright`).
public protocol OrientationProbing {
    /// Evidence for each clockwise turn (0, 90, 180 or 270 degrees) that stands the people upright, from frames
    /// sampled across one shot (`Tuning.orientationProbeEvery`); empty when nobody is seen.
    func votes(_ frames: [CIImage]) throws -> [Int: Double]
}

/// Splits one frame into people.
public protocol PersonSegmenting {
    func analyse(_ frame: CIImage) throws -> FrameAnalysis
}

/// Face landmarks of one person, for identity confirmation and the lip-sync guide.
public protocol FaceLocating {
    /// The face of the person covering `person`, among `frameFaces` or searched in their head region.
    func face(
        in frame: CIImage, person: MaskGrid, personBox: CGRect, frameFaces: [DetectedFace]
    ) throws
        -> FaceLandmarks?
}

/// What one person looks like, from the pixels inside their mask only.
public protocol AppearanceDescribing {
    func appearance(of frame: CIImage, mask: CIImage, box: CGRect) throws -> Appearance
}

/// Groups tracklets into people across shot cuts.
public protocol IdentityClustering {
    /// - Parameters:
    ///   - frames: the frames each tracklet covers; tracklets that share a frame are never the same person.
    ///   - weights: screen presence of each tracklet, for numbering identities (1 = most present).
    ///   - distance: appearance distance between two tracklets by index, 0 = same look.
    func cluster(frames: [Set<Int>], weights: [Int], distance: (Int, Int) -> Float) -> IdentityResult
}

/// Relative depth of a frame: larger is nearer. Loaded once per run, then called from one task at a time.
public protocol DepthEstimating: Sendable {
    func depth(of frame: CIImage) throws -> DepthMap
    /// The model's input size, landscape; person crops are shaped towards its aspect. Nil: unknown, crops take the
    /// frame's aspect.
    var inputSize: CGSize? { get }
}

extension DepthEstimating {
    public var inputSize: CGSize? { nil }
}

/// Follows target masks through a shot, frame by frame in order, from a seed mask per object. Created once per run
/// and used from one task.
public protocol MaskTracking: AnyObject {
    /// Named in the manifest, as the source of the target masks.
    var name: String { get }
    /// Seconds by part (model, CPU step) so far, for the manifest's timings; empty by default.
    var timings: [String: Double] { get }
    /// Forgets every object: the next frame starts a new shot. Objects in `crops` are tracked inside that part of the
    /// frame for the whole shot (`TrackingCrop`), the others on the full frame; masks are always frame-sized.
    func startShot(crops: [Int: TrackingCrop])
    /// As `startShot(crops:)` for a shot that stands upright after `upright` (nil: as filmed). Frames, seeds and
    /// crops still come in the source's frame; `UprightTracking` turns them, any other tracker ignores the turn.
    func startShot(crops: [Int: TrackingCrop], upright: Upright?)
    /// The masks of every object on `frame`. `seeds` start objects on this frame: frame-sized bytes, rows top-down,
    /// inside where > 127. A seeded object's mask on its seed frame is its seed.
    func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask]
    /// As `step(_:seeds:)`, and `corrections` re-seed tracked objects on this frame (same bytes as seeds) while
    /// keeping their memory: a tracker without corrections ignores them.
    func step(_ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]]) throws -> [Int: TrackedMask]
    /// As `step(_:seeds:corrections:)`; the corrections of the objects in `pinned` are the person's own (#58) and
    /// outrank automatic ones when the tracker's conditioning slots are full.
    func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]], pinned: Set<Int>
    ) throws -> [Int: TrackedMask]
    /// An object's mask on `frame` from one click on it (frame pixels, rows top-down), looked at inside `crop` (nil:
    /// the full frame), for a person's correction; nil when the tracker takes no point prompts. Leaves the tracked
    /// objects as they are.
    func mask(at point: CGPoint, on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]?
    /// As `mask(at:on:crop:)` from several clicks, each on the object (positive) or not; nil when the tracker takes
    /// no such prompt.
    func mask(points: [PromptPoint], on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]?
    /// The frame the next `step` call will be followed by, given just before that call, so a tracker can start on it
    /// while it steps the current one (EdgeTAM encodes it, #20); a hint only, ignored by default.
    func lookahead(_ next: CIImage)
}

/// One click of a prompt: frame pixels, rows top-down; positive on the object, negative off it.
public struct PromptPoint: Sendable, Equatable {
    public let point: CGPoint
    public let positive: Bool
    public init(_ point: CGPoint, positive: Bool = true) { (self.point, self.positive) = (point, positive) }
}

extension MaskTracking {
    public func startShot(crops: [Int: TrackingCrop], upright: Upright?) { startShot(crops: crops) }
    public func lookahead(_ next: CIImage) {}

    public func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]]
    ) throws -> [Int: TrackedMask] {
        try step(frame, seeds: seeds)
    }

    public func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]], pinned: Set<Int>
    ) throws -> [Int: TrackedMask] {
        try step(frame, seeds: seeds, corrections: corrections)
    }

    public func mask(at point: CGPoint, on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? { nil }

    /// One positive click goes to `mask(at:on:crop:)`; anything else needs the tracker's own.
    public func mask(points: [PromptPoint], on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
        guard points.count == 1, let only = points.first, only.positive else { return nil }
        return try mask(at: only.point, on: frame, crop: crop)
    }
}

/// Keeps only the voice of a soundtrack, at the same length and timing as the input.
public protocol VoiceIsolating {
    func isolate(_ audio: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer
}

/// Changes pitch without changing length.
public protocol PitchShifting {
    func shift(_ audio: AVAudioPCMBuffer, semitones: Float) throws -> AVAudioPCMBuffer
}

/// The stages of one run. `standard` is the on-device default: Vision, Core ML and Core Audio, nothing to install
/// beyond the depth model.
public struct PrepStages {
    public var shots: any ShotDetecting
    public var orientation: any OrientationProbing
    public var people: any PersonSegmenting
    public var faces: any FaceLocating
    public var appearance: any AppearanceDescribing
    public var identity: any IdentityClustering
    /// Loads the depth model. Called at the start of the run, so loading overlaps decoding and segmentation.
    public var depth: @Sendable () async throws -> any DepthEstimating
    /// Loads the mask tracker, after the targets are known. Nil keeps Vision's masks (`--no-tracking`); a load that
    /// throws keeps them too, with the reason in the manifest.
    public var tracking: (() async throws -> any MaskTracking)?
    /// Nil keeps the whole mix, music included.
    public var voice: (any VoiceIsolating)?
    /// Objects that stay in front of the target in the control video (#56); nil protects other people only.
    public var foreground: (any ForegroundMasking)?
    public var pitch: any PitchShifting
    /// One GPU context shared by every stage that renders.
    public let context: CIContext

    public init(
        shots: any ShotDetecting, orientation: any OrientationProbing, people: any PersonSegmenting, faces: any FaceLocating,
        appearance: any AppearanceDescribing, identity: any IdentityClustering,
        depth: @escaping @Sendable () async throws -> any DepthEstimating, voice: (any VoiceIsolating)?,
        pitch: any PitchShifting, context: CIContext, tracking: (() async throws -> any MaskTracking)? = nil
    ) {
        self.shots = shots
        self.orientation = orientation
        self.people = people
        self.faces = faces
        self.appearance = appearance
        self.identity = identity
        self.depth = depth
        self.tracking = tracking
        self.voice = voice
        self.pitch = pitch
        self.context = context
    }

    /// With `trackingModels`, a folder of the four EdgeTAM models, the target masks are tracked through each shot.
    public static func standard(tuning: Tuning, depthModel: URL, trackingModels: URL? = nil) -> PrepStages {
        var stages = standard(tuning: tuning, depth: { try await DepthAnything(modelURL: depthModel) })
        if let trackingModels {
            let context = stages.context
            stages.tracking = {
                EdgeTAMTracker(models: try await EdgeTAMModels(folder: trackingModels), context: context)
            }
        }
        return stages
    }

    /// The standard stages with depth from `depth`, for a caller that keeps a loaded model across runs.
    public static func standard(
        tuning: Tuning, depth: @escaping @Sendable () async throws -> any DepthEstimating
    ) -> PrepStages {
        let context = CIContext(options: [.cacheIntermediates: false])
        var stages = PrepStages(
            shots: VisionShotDetector(tuning: tuning, context: context),
            orientation: VisionOrientationProbe(),
            people: VisionPersonSegmenter(tuning: tuning, context: context),
            faces: VisionFaceLocator(),
            appearance: MaskedAppearance(context: context),
            identity: AgglomerativeIdentity(tuning: tuning),
            depth: depth,
            voice: AppleVoiceIsolator(),
            pitch: TimePitch(),
            context: context)
        if tuning.occluders.enabled { stages.foreground = OccluderMasking(tuning: tuning.occluders, context: context) }
        return stages
    }
}
