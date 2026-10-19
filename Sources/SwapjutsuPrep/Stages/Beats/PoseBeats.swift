import AVFoundation
import CoreImage
import Vision

/// The moves of the main person in a clip, timed from Vision's body pose: which way they face, turns, steps,
/// raised arms and crouches. A language model writing the beats of the prompt takes these as its timestamps, so
/// the times come from the video, not from the model's guess. Runs before prep on a few frames a second.
public struct PoseBeats: Sendable, Equatable {
    public enum Facing: String, Sendable, Equatable {
        case camera, side, away
    }

    /// One sampled pose of the largest body on the frame, in Vision's normalized coordinates (bottom-left).
    public struct Pose: Sendable, Equatable {
        public var time: Double
        public var facing: Facing
        /// The hips' centre.
        public var root: CGPoint
        /// Neck (or shoulders' centre) to the hips' centre: the body's scale on screen.
        public var torso: Double
        public var leftArmUp: Bool
        public var rightArmUp: Bool
        /// The lower ankle's distance below the hips, over `torso`: shrinks in a crouch.
        public var legs: Double?

        public init(
            time: Double, facing: Facing, root: CGPoint, torso: Double, leftArmUp: Bool = false,
            rightArmUp: Bool = false, legs: Double? = nil
        ) {
            self.time = time
            self.facing = facing
            self.root = root
            self.torso = torso
            self.leftArmUp = leftArmUp
            self.rightArmUp = rightArmUp
            self.legs = legs
        }
    }

    /// A timed move. `start` and `end` are seconds; a moment has `end == start`.
    public struct Beat: Sendable, Equatable, Codable {
        public let start: Double
        public let end: Double
        public let move: String
    }

    public let beats: [Beat]
    /// Most people on one sampled frame.
    public let people: Int
    /// Seconds analysed.
    public let duration: Double
    /// How much of the largest body the frame shows most of the time (`Framing.label`), nil without a body: a
    /// vision model shown a few small frames calls nearly every clip a full-body shot.
    public var framing: Framing?

    /// The lowest part of the body in the frame.
    public enum Framing: String, Sendable, Equatable, CaseIterable {
        case wide, full, knees, waist, chest, head

        public var label: String {
            switch self {
            case .wide: "wide shot, the whole body small in the frame"
            case .full: "full-body shot"
            case .knees: "knees-up shot"
            case .waist: "waist-up shot"
            case .chest: "chest-up shot"
            case .head: "close-up of the face"
            }
        }
    }

    /// Frames worth showing a vision model over a clip of `duration` seconds: each beat's start, and evenly spaced
    /// frames when there are fewer than `minimum`, at most `limit`, spread over the clip when there are more.
    /// Starts closer than half a second count once.
    public func keyframeTimes(duration: Double, minimum: Int = 4, limit: Int = 8) -> [Double] {
        var times: [Double] = []
        for t in beats.map(\.start).sorted() where times.last.map({ t - $0 >= 0.5 }) ?? true { times.append(t) }
        if times.count < minimum {
            let even = (0..<minimum).map { duration * (Double($0) + 0.5) / Double(minimum) }
            for t in even where !times.contains(where: { abs($0 - t) < 0.5 }) { times.append(t) }
            times.sort()
        }
        guard times.count > limit else { return times }
        return (0..<limit).map { times[$0 * (times.count - 1) / max(1, limit - 1)] }
    }

    /// The beats as prompt lines, "0.0–1.5 s: faces the camera".
    public var lines: [String] {
        beats.map { b in
            b.end > b.start
                ? String(format: "%.1f–%.1f s: %@", b.start, b.end, b.move)
                : String(format: "%.1f s: %@", b.start, b.move)
        }
    }
}

extension PoseBeats {
    /// Samples `url` at `rate` frames a second (up to `maxSeconds`) and reads the beats of the largest body.
    public static func analyse(video url: URL, rate: Double = 4, maxSeconds: Double = 30) async throws -> PoseBeats {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw PrepError.noVideoTrack(url) }
        let duration = min(try await asset.load(.duration).seconds, maxSeconds)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 24)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 24)
        var poses: [Pose] = [], people = 0, framings: [Framing] = []
        for time in Swift.stride(from: 0, to: duration, by: 1 / rate) {
            let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let request = VNDetectHumanBodyPoseRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            let bodies = request.results ?? []
            people = max(people, bodies.count)
            if let framing = bodies.compactMap(Self.framing).max(by: { $0.height < $1.height })?.framing {
                framings.append(framing)
            }
            if let pose = bodies.compactMap({ Self.pose($0, time: time) }).max(by: { $0.torso < $1.torso }) {
                poses.append(pose)
            }
        }
        return PoseBeats(
            beats: beats(poses, duration: duration), people: people, duration: duration,
            framing: Self.most(framings))
    }

    /// The framing that holds on the most samples; nil without any.
    static func most(_ framings: [Framing]) -> Framing? {
        Framing.allCases.map { f in (f, framings.filter { $0 == f }.count) }.filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }

    /// A body's framing from the lowest of its joints the frame shows, with the height its joints span: a whole
    /// body under a third of the frame's height is a wide shot.
    static func framing(_ body: VNHumanBodyPoseObservation) -> (framing: Framing, height: Double)? {
        guard let points = try? body.recognizedPoints(.all) else { return nil }
        let seen = points.filter { $0.value.confidence >= 0.3 && (0.01...0.99).contains($0.value.location.y) }
        guard let top = seen.values.map(\.location.y).max(), let bottom = seen.values.map(\.location.y).min()
        else { return nil }
        let has = { (names: [VNHumanBodyPoseObservation.JointName]) in names.contains { seen[$0] != nil } }
        let height = Double(top - bottom)
        let framing: Framing
        if has([.leftAnkle, .rightAnkle]) {
            framing = height < 0.33 ? .wide : .full
        } else if has([.leftKnee, .rightKnee]) {
            framing = .knees
        } else if has([.leftHip, .rightHip]) {
            framing = .waist
        } else if has([.leftShoulder, .rightShoulder]) {
            framing = .chest
        } else if has([.nose, .leftEye, .rightEye]) {
            framing = .head
        } else {
            return nil
        }
        return (framing, height)
    }

    static func pose(_ body: VNHumanBodyPoseObservation, time: Double) -> Pose? {
        guard let points = try? body.recognizedPoints(.all) else { return nil }
        func at(_ name: VNHumanBodyPoseObservation.JointName, _ confidence: Float = 0.3) -> CGPoint? {
            points[name].flatMap { $0.confidence >= confidence ? $0.location : nil }
        }
        guard let ls = at(.leftShoulder), let rs = at(.rightShoulder), let lh = at(.leftHip), let rh = at(.rightHip)
        else { return nil }
        let shoulders = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
        let root = CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
        let torso = Double(hypot((at(.neck) ?? shoulders).x - root.x, (at(.neck) ?? shoulders).y - root.y))
        guard torso > 0.02 else { return nil }
        let face = [at(.nose), at(.leftEye), at(.rightEye)].compactMap { $0 }.count
        let facing = Self.facing(
            leftShoulder: ls, rightShoulder: rs, torso: torso, faceKeypoints: face)
        let lowest = [at(.leftAnkle), at(.rightAnkle)].compactMap { $0 }.map(\.y).min()
        return Pose(
            time: time, facing: facing, root: root, torso: torso,
            leftArmUp: at(.leftWrist).map { $0.y > ls.y } ?? false,
            rightArmUp: at(.rightWrist).map { $0.y > rs.y } ?? false,
            legs: lowest.map { Double(root.y - $0) / torso })
    }

    /// Facing the camera, the person's left shoulder is on the image's right; from behind, on its left. Narrow
    /// shoulders for the torso's length are a profile. With the face's keypoints seen, it is never "away".
    static func facing(
        leftShoulder ls: CGPoint, rightShoulder rs: CGPoint, torso: Double, faceKeypoints: Int
    )
        -> Facing
    {
        let width = Double(ls.x - rs.x)
        if abs(width) < 0.45 * torso { return faceKeypoints >= 2 ? .side : (faceKeypoints == 0 ? .away : .side) }
        if width > 0 { return .camera }
        return faceKeypoints >= 2 ? .camera : .away
    }
}

extension PoseBeats {
    /// Facing runs, turns between them, arm raises, crouches and travel across the frame, in time order.
    static func beats(_ poses: [Pose], duration: Double) -> [Beat] {
        guard let first = poses.first, let last = poses.last else { return [] }
        let step = poses.count > 1 ? (last.time - first.time) / Double(poses.count - 1) : 0.25
        var beats: [Beat] = []
        let facing = Self.stable(poses.map(\.facing))
        var runStart = 0
        for i in 1...poses.count where i == poses.count || facing[i] != facing[runStart] {
            let end = i == poses.count ? duration : poses[i].time
            beats.append(Beat(start: poses[runStart].time, end: end, move: Self.words(facing[runStart])))
            if i < poses.count {
                beats.append(
                    Beat(start: poses[i].time, end: poses[i].time, move: Self.turn(facing[runStart], facing[i])))
            }
            runStart = i
        }
        beats += runs(poses, step: step, duration: duration) { $0.leftArmUp && $0.rightArmUp }
            .map { Beat(start: $0, end: $1, move: "both arms raised") }
        beats += runs(poses, step: step, duration: duration) { $0.leftArmUp != $0.rightArmUp }
            .map { range in
                let left = poses.filter { $0.time >= range.0 && $0.time < range.1 && $0.leftArmUp }.count
                let right = poses.filter { $0.time >= range.0 && $0.time < range.1 && $0.rightArmUp }.count
                return Beat(start: range.0, end: range.1, move: "\(left >= right ? "left" : "right") arm raised")
            }
        let legs = poses.compactMap(\.legs).sorted()
        if legs.count >= 4 {
            let standing = legs[legs.count * 3 / 4]
            beats += runs(poses, step: step, duration: duration) { ($0.legs ?? standing) < 0.75 * standing }
                .map { Beat(start: $0, end: $1, move: "crouches low") }
        }
        beats += travel(poses)
        return beats.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// One-sample blips (a mislabelled profile) take their neighbours' facing.
    static func stable(_ facing: [Facing]) -> [Facing] {
        var out = facing
        for i in facing.indices.dropFirst().dropLast()
        where facing[i - 1] == facing[i + 1] && facing[i] != facing[i - 1] {
            out[i] = facing[i - 1]
        }
        return out
    }

    /// Time ranges where `test` holds on two samples or more in a row.
    static func runs(_ poses: [Pose], step: Double, duration: Double, _ test: (Pose) -> Bool) -> [(Double, Double)] {
        var out: [(Double, Double)] = [], start: Int?
        for i in 0...poses.count {
            let on = i < poses.count && test(poses[i])
            if on, start == nil { start = i }
            if !on, let s = start {
                if i - s >= 2 { out.append((poses[s].time, min(duration, poses[i - 1].time + step))) }
                start = nil
            }
        }
        return out
    }

    /// Sideways travel of the hips by more than one torso length within two seconds, as "moves towards the frame's
    /// left". Back-and-forth moves of under a second each, one after another, are one "sways side to side".
    static func travel(_ poses: [Pose]) -> [Beat] {
        // Each move's `move` is the side it heads to, "left" or "right", until the wording below.
        var moves: [Beat] = [], anchor = 0
        for i in poses.indices.dropFirst() {
            let dx = Double(poses[i].root.x - poses[anchor].root.x)
            let scale = (poses[i].torso + poses[anchor].torso) / 2
            if abs(dx) > scale, poses[i].time - poses[anchor].time <= 2 {
                moves.append(Beat(start: poses[anchor].time, end: poses[i].time, move: dx < 0 ? "left" : "right"))
                anchor = i
            } else if poses[i].time - poses[anchor].time > 2 {
                anchor = i
            }
        }
        var beats: [Beat] = [], i = 0
        while i < moves.count {
            var j = i
            while j + 1 < moves.count, moves[j + 1].move != moves[j].move, moves[j + 1].start - moves[j].end < 0.3,
                moves[j].end - moves[j].start < 1, moves[j + 1].end - moves[j + 1].start < 1
            {
                j += 1
            }
            let move = j > i ? "sways side to side" : "moves towards the frame's \(moves[i].move)"
            beats.append(Beat(start: moves[i].start, end: moves[j].end, move: move))
            i = j + 1
        }
        return beats
    }

    static func words(_ facing: Facing) -> String {
        switch facing {
        case .camera: "faces the camera"
        case .side: "in profile"
        case .away: "back to the camera"
        }
    }

    static func turn(_ from: Facing, _ to: Facing) -> String {
        switch (from, to) {
        case (_, .away): "turns away from the camera"
        case (.away, _): "turns back towards the camera"
        case (_, .side): "turns to profile"
        default: "turns to face the camera"
        }
    }
}
