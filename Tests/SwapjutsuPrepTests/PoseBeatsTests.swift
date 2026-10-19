import CoreGraphics
import Testing

@testable import SwapjutsuPrep

/// The moves read from body poses; Vision itself is not run.
@Suite struct PoseBeatsTests {
    func poses(_ facing: [PoseBeats.Facing], x: (Int) -> Double = { _ in 0.5 }) -> [PoseBeats.Pose] {
        facing.enumerated().map { i, f in
            PoseBeats.Pose(time: Double(i) * 0.25, facing: f, root: CGPoint(x: x(i), y: 0.4), torso: 0.2, legs: 2)
        }
    }

    @Test func facingFollowsTheShouldersAndTheFace() {
        let left = CGPoint(x: 0.6, y: 0.7), right = CGPoint(x: 0.4, y: 0.7)
        #expect(PoseBeats.facing(leftShoulder: left, rightShoulder: right, torso: 0.3, faceKeypoints: 3) == .camera)
        #expect(PoseBeats.facing(leftShoulder: right, rightShoulder: left, torso: 0.3, faceKeypoints: 0) == .away)
        // A spin's mislabelled sides with the face in view stay facing the camera.
        #expect(PoseBeats.facing(leftShoulder: right, rightShoulder: left, torso: 0.3, faceKeypoints: 3) == .camera)
        let narrow = CGPoint(x: 0.52, y: 0.7)
        #expect(PoseBeats.facing(leftShoulder: narrow, rightShoulder: right, torso: 0.3, faceKeypoints: 2) == .side)
    }

    /// A spin: facing runs with a turn at each change, and a one-sample blip folded into its neighbours.
    @Test func aSpinGivesRunsAndTurns() {
        let samples = poses([.camera, .camera, .side, .camera, .camera, .away, .away, .camera, .camera])
        let result = PoseBeats.beats(samples, duration: 2.25)
        #expect(
            result.map(\.move) == [
                "faces the camera", "turns away from the camera", "back to the camera",
                "turns back towards the camera", "faces the camera",
            ])
        #expect(result[2].start == 1.25 && result[2].end == 1.75)
        #expect(result.last?.end == 2.25)
    }

    @Test func backAndForthIsASwayAndOneWayIsAMove() {
        let sway = poses(Array(repeating: .camera, count: 6)) { [0.3, 0.6, 0.3, 0.6, 0.3, 0.3][$0] }
        #expect(PoseBeats.travel(sway).map(\.move) == ["sways side to side"])
        let walk = poses(Array(repeating: .camera, count: 4)) { 0.8 - 0.15 * Double($0) }
        #expect(PoseBeats.travel(walk).map(\.move) == ["moves towards the frame's left"])
    }

    @Test func keyframesCoverTheClipAndStayUnderTheLimit() {
        let one = PoseBeats(beats: [.init(start: 0, end: 7, move: "faces the camera")], people: 1, duration: 7)
        #expect(one.keyframeTimes(duration: 7) == [0, 0.875, 2.625, 4.375, 6.125])
        let many = PoseBeats(
            beats: (0..<20).map { .init(start: Double($0), end: Double($0), move: "x") }, people: 1, duration: 20)
        #expect(many.keyframeTimes(duration: 20).count == 8)
    }
}
