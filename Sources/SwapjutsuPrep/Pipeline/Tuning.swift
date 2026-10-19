import CoreGraphics

/// Every threshold the pipeline uses, in one place. Values were calibrated on the clips in
/// `Tests/SwapjutsuPrepTests/Fixtures/fixtures.json` (docs/TESTING.md); change them only together with a fixture run.
public struct Tuning: Sendable {
    /// Working frame rate and the longest side of the working frame, as Seedance inputs are prepared.
    public var fps: Int32 = 24
    public var maxSide: CGFloat = 960
    /// Seedance and Genjutsu take 4–30 s; longer sources are trimmed.
    public var maxSeconds: Double = 30
    /// Seedance 2.5 rejects reference videos with fewer pixels per frame (854 × 480 just passes).
    public var minPixels: CGFloat = 409_600

    /// Two consecutive frames are a shot cut when their whole-frame feature prints are this far apart, or their
    /// colour histograms are `cutColour` apart. The histogram catches cuts between near-identical framings
    /// (same backdrop, same angle) that feature prints miss; inside a shot it stays under 0.01.
    public var cutDistance: Float = 0.6
    public var cutColour: Float = 0.05
    /// A shot shorter than this many frames is a false cut (a flash, a transition frame) and joins a neighbour
    /// (`ShortShots`). A sixth of a second at 24 fps; the shortest real shot on the fixtures is 8 frames.
    public var minShotFrames = 4
    /// Which way up each shot stands (`Upright`) is probed on its first frame and every this many frames after.
    public var orientationProbeEvery = 24
    /// A shot is turned when the votes for one turn reach `orientationMinVotes` (about one clear face) and
    /// `orientationMargin` times the votes for the shot as filmed.
    public var orientationMinVotes = 1.0
    public var orientationMargin = 2.0
    /// Masks are compared on a square occupancy grid of this many cells per side.
    public var grid = 96
    /// A detection smaller than this share of the frame is a speck and is dropped.
    public var minPersonArea = 0.005
    /// Minimum mask IoU between consecutive frames to continue a tracklet inside a shot.
    public var trackIoU = 0.2
    /// A tracklet is split when its person's clothing colours jump by more than this between frames: a missed cut
    /// or one person stepping into another's place.
    public var trackSplitColour: Float = 0.25
    /// Holes in a person's instance mask up to twice this share of the frame width are closed before the matte
    /// fills them.
    public var closeRadius: CGFloat = 0.06
    /// A detection is confirmed by a face or a human rectangle covering this share of its mask box. A tracklet with
    /// fewer than `minConfirmed` of its detections confirmed is a false positive (a cup, a seat) and is dropped;
    /// partly visible people stay, because their tracklet is confirmed in its other frames.
    public var humanCoverage = 0.3
    public var minConfirmed = 0.2

    /// Identity distance = printWeight · print/1.2 + colourWeight · colour. Generic feature prints follow pose and
    /// framing more than the person, so clothing colour carries most of the weight.
    public var printWeight: Float = 0.2
    public var colourWeight: Float = 0.8
    /// Average-linkage distance below which two groups of tracklets are the same person.
    public var mergeDistance: Float = 0.33
    /// Tracklets shorter than this do not form identities; they join the nearest one that looks alike and is absent
    /// from their frames, else they stay a person of their own, whom `--target all` leaves alone (`Pipeline.everyone`).
    public var minTrackletFrames = 3
    /// A nearest non-merged pair closer than mergeDistance + this margin is reported as ambiguous.
    public var ambiguityMargin: Float = 0.05

    /// `@Video1` carries the soundtrack pitched by this many semitones (0 keeps it as is).
    public var pitchSemitones: Float = 3
    /// `@Video1` carries only the voice, with the music bed and ambience removed, as in the reference workflow.
    public var isolateVoice = true

    /// The face guide draws a target's landmark lines only on frames where they span at least this share of the
    /// frame height, brows to chin (`FaceLandmarks.height`): on a smaller face nine polylines crowd into a few
    /// pixels and read as noise on the depth. Measured on 960-high frames (blonde cloister, studio-duo, velvet-dancer,
    /// crowd-interaction, all faces drawn): Vision's target faces span 3.4–13.2 %, and the lines stay distinct down to
    /// the smallest, 33 px; 3 % keeps all of them. Note: the line width follows the frame width, so on a 480-high
    /// landscape frame 3 % is 14 px under 1.8 px lines; not measured, raise this if such faces smear.
    public var faceGuideMinHeight: CGFloat = 0.03

    /// The targets' hands (`HandCue`) are painted this share of the shot's depth spread nearer than the depth model
    /// put them, so a hand on the torso shows its fingers; 0 turns the cue off.
    public var handLift: Float = 0.2

    /// Target mask grows by at least this share of the frame width so no original edge pixels leak into the control
    /// video; `mask.mp4` is the subject matte grown by exactly this.
    public var maskDilation: CGFloat = 0.006
    /// Edit region (#56), one radius per target and shot (`EditRegion`): the larger of `editExtent` of the target's
    /// median box height and `editMotion` of its typical box movement per frame, at most `editMaxDilation` of the
    /// frame width (the dilated ring still gets the person's depth from `DepthEdges` up to there).
    public var editExtent: CGFloat = 0.006
    public var editMotion: CGFloat = 0.5
    public var editMaxDilation: CGFloat = 0.01
    /// Other people in front of the target (`Occlusion`): their order is the median depth difference of the cells
    /// within `occlusionBand` grid cells of the other mask, at least `occlusionMinCells` a side, against
    /// `occlusionDepthTolerance` of the shot's depth span. A person covering over `occlusionMaxShare` of the target's
    /// cells is the target under another identity, one under `occlusionMinArea` of them a fragment (a hand split off,
    /// a headrest taken for a person); both are ignored, as are detections without a face or body rectangle and
    /// identities never seen with a face. Only a
    /// person in front on two consecutive frames is protected, so a one-frame call cannot flash. A person in front keeps the pixels nearer than
    /// halfway between the two, with a soft step `occlusionRamp` of the span wide.
    public var occlusionBand = 2
    public var occlusionMinCells = 3
    public var occlusionDepthTolerance: Float = 0.1
    public var occlusionMaxShare = 0.5
    public var occlusionMinArea = 0.25
    public var occlusionRamp: Float = 0.05
    /// Objects in front of the target, found without a click (`OccluderMasking`, #56).
    public var occluders = OccluderTuning()
    /// Depth at the silhouette (#15): depth closer than `depthEdgeErosion` of the frame width to the target's mask
    /// edge mixes in the background; it and the dilation ring take the person's depth from within `depthEdgeReach`,
    /// weighted by colour similarity in the frame (`depthEdgeColourSigma`, in √RGB).
    public var depthEdgeErosion: CGFloat = 0.01
    public var depthEdgeReach: CGFloat = 0.02
    public var depthEdgeColourSigma: Float = 0.1
    /// Painted pixels still at or past the far end of the shot's colour range after the edge fill are background
    /// the matte took in (a sign behind an arm, a gap too wide to fill): they would paint near-black, so they show
    /// the background instead, fading in over `depthBehindRamp` of the range's spread.
    public var depthBehindRamp: Float = 0.05

    /// Depth runs a second time on a crop around each of the `depthCrops` largest people in a frame, padded by
    /// `depthCropPadding` of the person's size plus `depthCropMargin` of the frame width, unless the crop would cover
    /// more than `depthCropMaxShare` of the frame. The crop fades into the full-frame depth over `depthCropFeather`
    /// of the frame width. 0 crops turns it off.
    public var depthCrops = 2
    public var depthCropPadding: CGFloat = 0.08
    public var depthCropMargin: CGFloat = 0.04
    public var depthCropMaxShare = 0.6
    public var depthCropFeather: CGFloat = 0.02

    /// Depth smoothed over time along the optical flow (#17): at most `depthSmoothing` of the previous frame's depth,
    /// warped onto this one and aligned to its scale, enters a pixel (0 turns smoothing and the flow off); less where
    /// the flow is unsure, and less where the two differ by more than `depthSmoothingTolerance` of the target's depth
    /// spread on this frame. The blend runs on the smoothed history's depth scale, and `depthSmoothingScaleFollow` of
    /// the way to this frame's scale is taken per frame: the model's frame-to-frame scale jitter is damped, a lasting
    /// change comes through within a few frames. The flow runs at `flowSide` pixels on the longest side; a luma difference of
    /// `flowLumaSigma` (0–1) along a vector cuts its confidence to 37 %.
    public var depthSmoothing: Float = 0.6
    public var depthSmoothingTolerance: Float = 0.1
    public var depthSmoothingScaleFollow: Float = 0.25
    public var flowSide = 320
    public var flowLumaSigma: Float = 0.05

    public init() {}
}
