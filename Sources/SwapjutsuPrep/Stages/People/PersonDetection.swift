import CoreGraphics
import CoreImage

/// What a segmenter sees in one frame.
public struct FrameAnalysis {
    /// One frame-sized mask per person, white = person.
    public let people: [CIImage]
    /// Whole-body human rectangles, unit coordinates with a bottom-left origin.
    public let humans: [CGRect]
    /// Faces found on the whole frame.
    public let faces: [DetectedFace]

    public init(people: [CIImage], humans: [CGRect], faces: [DetectedFace]) {
        self.people = people
        self.humans = humans
        self.faces = faces
    }
}

/// A face found on the whole frame: its box in unit coordinates (bottom-left origin) and its landmarks.
public struct DetectedFace: Sendable {
    public let box: CGRect
    public let landmarks: FaceLandmarks?

    public init(box: CGRect, landmarks: FaceLandmarks?) {
        self.box = box
        self.landmarks = landmarks
    }
}

public struct FaceLandmarks: Sendable {
    /// Named open or closed polylines in working-frame pixels: faceContour, outerLips, innerLips, leftEye, …
    public let regions: [Region]

    public struct Region: Sendable {
        public let name: String
        public let points: [CGPoint]
        public let closed: Bool

        public init(name: String, points: [CGPoint], closed: Bool) {
            self.name = name
            self.points = points
            self.closed = closed
        }
    }

    public init(regions: [Region]) { self.regions = regions }

    /// How tall the landmarks stand, brows to chin, in pixels: Vision's points stop short of the forehead.
    public var height: CGFloat {
        let ys = regions.flatMap(\.points).map(\.y)
        guard let low = ys.min(), let high = ys.max() else { return 0 }
        return high - low
    }
}

/// One person in one frame.
public struct PersonDetection: Sendable {
    public let frame: Int
    /// Position in this frame's detection list; the mask cache keys on (frame, index).
    public let index: Int
    public let grid: MaskGrid
    /// Bounding box in working-frame pixels (bottom-left origin).
    public let box: CGRect
    public let appearance: Appearance
    /// Face landmarks in working-frame pixels, nil when no face was found.
    public let face: FaceLandmarks?
    /// A face or a human body rectangle backs this detection.
    public let confirmed: Bool

    var key: String { "\(frame)_\(index)" }
}
