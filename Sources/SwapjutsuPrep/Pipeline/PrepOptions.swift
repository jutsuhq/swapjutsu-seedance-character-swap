import Foundation

/// Which people to replace.
public enum TargetSelection: Sendable, Equatable {
    /// The identity with the largest screen presence.
    case main
    case all
    case ids([Int])
}

/// What the control video does with everything but the targets.
public enum BackgroundMode: String, Sendable, Codable {
    /// The original pixels stay, and Seedance keeps them.
    case keep
    /// Painted with grey depth, people in front of the targets included, so Seedance gets the scene's layout and
    /// camera motion but nothing of its look, and puts the place from the image after the characters there.
    case replace
}

/// What the control video shows of the targets. Colored depth is a stencil: a hand in a pocket stays a fist, and
/// Seedance draws stumps. The hybrid modes show the footage's own pixels instead (Higgsfield sends real pixels, and its
/// renders keep the source's hands and even earrings); the head stays colored depth, so the face comes only from the
/// character image.
public enum ControlMode: String, Sendable, Codable, CaseIterable {
    /// The targets painted with colored depth.
    case depth
    /// Colored depth, but the targets' hands are the footage's pixels (`Pipeline.hybridMasks`).
    case hybridHands = "hybrid-hands"
    /// The targets are the footage's pixels but for the head, which stays colored depth.
    case hybridBody = "hybrid-body"
}

public struct PrepOptions: Sendable {
    public var target: TargetSelection = .main
    /// Face landmark lines over the target's painted face (`Tuning.faceGuideMinHeight`), for the head turn, gaze and
    /// expression a flat depth blob hides. Off by default: in a Seedance 2.5 render with the guide, the prompt
    /// sentence telling it never to draw the lines, and a face close-up, the lines were drawn onto the face in nearly
    /// every frame.
    public var faceGuide = false
    public var background = BackgroundMode.keep
    public var control = ControlMode.depth
    /// Paint the targets inside their mattes, the outline of the clothes they wear, instead of the silhouette drawn
    /// from their skeleton and box (`BodyOutline`).
    public var matteOutline = false
    public var review = true
    public var tuning = Tuning()
    public var tracking = TrackingTuning()
    public init() {}
}

/// When a shot keeps Vision's target masks instead of the tracker's.
public struct TrackingTuning: Sendable {
    /// The tracker lost the target this many frames in a row while Vision still saw it (half a second at 24 fps).
    public var lostFrames = 12
    /// The tracked mask overlaps Vision's by less than this mean grid IoU over the shot: it follows something else.
    /// Measured agreement on the benchmark clips is 0.81–0.99.
    public var minAgreement = 0.5
    /// Track each target inside one fixed crop per shot (`TrackingCrop`) instead of the full frame squeezed into
    /// EdgeTAM's 1024² input, so a tall frame or a small person keeps its resolution. The crop is the union of the
    /// target's Vision boxes over the shot.
    public var crop = true
    /// Margin added on every side of the union of boxes, as a share of the union's longer side.
    public var cropMargin = 0.1
    /// The crop's side is at least this share of the frame's shorter side.
    public var cropMinShare = 0.0

    // MARK: Seed choice (`SeedChoice`)

    /// Seed each target at its best-scored frame in a shot (`SeedChoice`) and track it both ways from there
    /// (`TwoWayTracking`), instead of forward from its first Vision mask. Off: on the benchmark (#8) the score keeps
    /// pilot-cockpit's headrest, which Vision includes on about 80 % of its frames, and picks worse seeds for
    /// orange-jacket and driver-car. A seed from a clean frame (frame 72 of pilot-cockpit, by hand) does drop it.
    public var chooseSeed = false
    /// Frames either side of a candidate whose masks its stability is measured against (a quarter second).
    public var seedWindow = 6
    /// Off the shot's median mask area by this share, a candidate's area term reaches 0.
    public var seedAreaTolerance = 0.25
    /// Weights of the seed terms: a face, area near the median, stable neighbours, nobody else on the box.
    public var seedWeights = SeedWeights()

    public struct SeedWeights: Sendable {
        public var face = 1.0
        public var area = 1.0
        public var stability = 2.0
        public var alone = 1.0
        public init() {}
    }

    /// EdgeTAM encodes the next frame while it propagates the current one (`FrameEncoding`, #20): the image encoder
    /// does not read the memory bank, so the masks are byte for byte the same. With all four models on the Neural
    /// Engine a tracked frame takes 12–27 % less on an M4 (median per clip), both package sets: the encoder waits
    /// behind the propagator and our CPU work.
    public var encodeAhead = true

    // MARK: Re-seeding from Vision (`VisionReseeding`)

    /// Re-seeding the tracker from Vision's mask when it drifts away from a confident one (#13).
    public var reseed = Reseed()

    /// When a Vision mask becomes a correction: confidence (`ReseedConfidence`), drift (`DriftMonitor`) and the
    /// conditioning slots (`ConditioningMemory`, `BankLayout`).
    ///
    /// Measured on the ground-truth clips (#13; Vision's eroded mask as the source, no face,
    /// alone = nobody else on the frame): orange-jacket 0.741 → 0.791 (min 0.399 → 0.545, one correction at frame
    /// 119, the hands come back), driver-car 0.824 → 0.830 (min 0.753 → 0.781); the other six unchanged, because
    /// Vision is never confident where they drift (crowd-interaction, dance-duo, retro-dance-trio: other people on
    /// the frame) or never disagrees enough (studio-duo, pilot-cockpit, blonde-hair-swap: Vision is the one missing
    /// hair and hand, `maxVisionCovered`). Without `forgetRecent` orange-jacket only reached 0.752. Looser
    /// stability (0.7), cover (0.95) and area (0.5) changed nothing; drift IoU 0.6 never fires.
    public struct Reseed: Sendable {
        public var enabled = true
        // Drift
        /// The tracked mask overlaps Vision's by less than this grid IoU…
        public var driftIoU = 0.7
        /// …and holds less than this share of Vision's mask (more means Vision is the one missing parts).
        public var maxVisionCovered = 0.85
        /// A Vision mask over this many times the tracked area is Vision merging people, not drift.
        public var maxAreaRatio = 2.5
        /// Drift frames in a row before a correction is due.
        public var driftFrames = 3
        /// Frames after a correction before the next one.
        public var cooldown = 12
        // Confidence
        /// Trust Vision only on frames where nobody else is detected, as measured. Off: another person's box may
        /// cover up to `maxOverlap` of the target's (not measured on ground truth: it needs a new Vision prep).
        public var aloneOnFrame = true
        /// Box overlap with another person the target may have when `aloneOnFrame` is off.
        public var maxOverlap = 0.1
        /// Ask for a face on the target where the caller knows (the prep does).
        public var requireFace = true
        /// Vision has the target on this many frames before, each overlapping the next by `minStability`.
        public var stabilityFrames = 3
        public var minStability = 0.85
        /// The mask's area is within this share of Vision's median area over `areaWindow` frames.
        public var areaTolerance = 0.2
        public var areaWindow = 24
        // Memory
        /// Corrections kept as conditioning frames beside the seed (at most `BankLayout.maxCorrections`).
        public var maxCorrections = 2
        /// Drop the recent frames from memory at a correction: they hold the drifted mask.
        public var forgetRecent = true
        public init() {}
    }

    // MARK: Frames to check (`TrackingFlags`)

    /// Which frames of a target shot the manifest flags for the person to check and correct (#58).
    public var flags = Flags()

    public struct Flags: Sendable {
        /// The mask's area changes by more than this share of the larger of two consecutive frames.
        public var areaChange = 0.35
        /// The mask covers more than this share of another person's mask.
        public var overlap = 0.3
        /// The tracker's object score (a logit; above 0 the object is there) is under this.
        public var minScore: Float = 1
        /// Runs of flagged frames kept per shot, the longest first.
        public var maxRuns = 8
        public init() {}
    }

    public init() {}
}

extension PrepOptions {
    /// Throws `invalidOption` for settings no clip can satisfy, before any file is written.
    public func validate() throws {
        let t = tuning
        guard t.maxSeconds.isFinite, (4...30).contains(t.maxSeconds) else {
            throw PrepError.invalidOption("max seconds must be 4–30 (Seedance's range), got \(t.maxSeconds)")
        }
        guard t.pitchSemitones.isFinite, (-12...12).contains(t.pitchSemitones) else {
            throw PrepError.invalidOption("pitch must be −12…12 semitones, got \(t.pitchSemitones)")
        }
        guard t.fps > 0, t.maxSide >= 64, t.grid >= 8 else {
            throw PrepError.invalidOption("fps, max side and grid must be positive")
        }
        if case .ids(let ids) = target {
            guard !ids.isEmpty, ids.allSatisfy({ $0 >= 1 }) else {
                throw PrepError.invalidOption("target ids are 1-based person numbers, got \(ids)")
            }
        }
    }
}
