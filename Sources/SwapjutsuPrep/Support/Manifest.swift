import Foundation

/// `manifest.json`: everything the app (or a person) needs to review the prep and submit it to Seedance.
public struct Manifest: Codable, Sendable {
    public struct Shot: Codable, Sendable {
        public let index: Int
        public let start: Int
        public let end: Int
        /// Clockwise degrees (0, 90, 180, 270) the shot was turned to stand its people upright for detection,
        /// tracking and depth (`Upright`); the outputs keep the source's frame. Nil in older manifests: as filmed.
        public var orientation: Int? = nil
    }
    public struct Identity: Codable, Sendable {
        public let id: Int
        public let frames: Int
        public let shots: [Int]
        /// Share of the clip's total person area this identity takes.
        public let screenShare: Double
        public let thumbnail: String?
        public let isTarget: Bool
    }
    public struct Quality: Codable, Sendable {
        /// Frames where a target is visible / all frames.
        public let targetPresence: Double
        /// Mean mask IoU between consecutive frames of the same target tracklet (1 = rock steady).
        public let maskStability: Double
        /// Target detections with face landmarks / target detections.
        public let faceCoverage: Double
        /// Mean frame-to-frame change of the target's mean normalised depth (0 = no flicker).
        public let depthFlicker: Double
        /// Mean motion-compensated change of the painted depth between consecutive frames of a shot, per pixel,
        /// where the optical flow is trusted, inside the target (shot scale 0–1). Unlike `depthFlicker`, a blurred
        /// or shifted map does not hide shimmer from it. Nil without optical flow (smoothing off) or in older
        /// manifests.
        public let depthResidual: Double?
        /// The same on the per-frame depth before smoothing.
        public let depthResidualRaw: Double?
        /// Distance between the two most similar identities kept apart, and the merge threshold.
        public let closestIdentityDistance: Double?
        public let mergeDistance: Double
        /// The median height of the targets' faces, brows to chin (`FaceLandmarks.height`), as a share of the frame
        /// height; nil without faces and in older manifests. A small face is what a 480p draft blurs first.
        public var faceHeight: Double? = nil
    }
    public struct Seedance: Codable, Sendable {
        public let video: String
        /// `brief` as text, without the app's face close-ups and extra references.
        public let prompt: String
        public let durationSeconds: Double
        /// What the prompt is made from, so the app can write it again with the images it uploads; nil in older
        /// manifests, whose `prompt` is used as it is.
        public var brief: ServicePrompt? = nil
    }

    /// Where the target masks came from, shot by shot.
    public struct Tracking: Codable, Sendable {
        /// The tracker that ran (`EdgeTAM`); nil when every target mask is Vision's.
        public let tracker: String?
        /// Why no tracker ran: `off`, or why it could not load (models missing).
        public let unavailable: String?
        public let shots: [TrackedShot]
    }
    /// One target in one shot.
    public struct TrackedShot: Codable, Sendable {
        public let shot: Int
        public let target: Int
        /// `tracked`, or `vision` when the shot fell back.
        public let source: String
        /// Why the shot kept Vision's masks: `lost` (the tracker lost a target Vision still saw for
        /// `TrackingTuning.lostFrames`), `disagrees` (overlap with Vision under `minAgreement`), or the error.
        public let fallback: String?
        public let seedFrame: Int
        /// Frames with a tracked mask.
        public let trackedFrames: Int
        /// Frames the tracker has the target and Vision does not.
        public let recoveredFrames: Int
        /// Frames Vision has the target and the tracker does not, and the longest run of them.
        public let lostFrames: Int
        public let longestLoss: Int
        /// Lost frames of a tracked shot that took Vision's mask instead (`TargetMasks.filled`); nil in older
        /// manifests.
        public let filledFrames: Int?
        /// Mean grid IoU with Vision on frames where both have the target.
        public let agreement: Double?
        /// The part of the frame the tracker saw, `[x, y, width, height]` in pixels with rows top-down
        /// (`TrackingCrop`); nil for the full frame (`TrackingTuning.crop` off).
        public let crop: [Int]?
        /// Frames where the tracker was re-seeded from Vision's mask (`TrackingTuning.reseed`); nil when that is off.
        public let reseeds: [Int]?
        /// Frames the person corrected (#58, `TargetCorrection`); the shot was re-tracked from them and keeps the
        /// tracked masks whatever Vision says. Nil without corrections.
        public let corrections: [Int]?
        /// Runs of frames worth checking (`TrackingFlags`), so the person corrects only those. Nil in older manifests.
        public let flags: [TrackingFlag]?
    }

    public let source: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let shots: [Shot]
    /// Identity per frame per detection index: `timeline[frame]` lists identity ids in detection order.
    public let timeline: [[Int]]
    public let identities: [Identity]
    public let targets: [Int]
    public let quality: Quality
    public let warnings: [String]
    public let seedance: Seedance
    /// Seconds per stage on this machine.
    public let timings: [String: Double]
    /// Nil in manifests written before mask tracking.
    public let tracking: Tracking?
    /// Nil in manifests written before the background could be replaced: kept.
    public var background: BackgroundMode? = nil
    /// Nil with the face guide off, and in manifests written before it was held to a face size.
    public var faceGuide: FaceGuide? = nil

    /// Where the face guide drew its lines.
    public struct FaceGuide: Codable, Sendable, Equatable {
        /// Frames with lines on a target's face; 0 when no face was tall enough, and the prompt says nothing of them.
        public let frames: Int
        /// `Tuning.faceGuideMinHeight` the faces were held to, as a share of the frame height.
        public let minFaceHeight: Double
    }
}
