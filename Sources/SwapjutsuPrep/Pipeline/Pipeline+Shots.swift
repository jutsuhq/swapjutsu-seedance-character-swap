import CoreImage

/// The shot cuts and which way up each shot stands, from a decode of the clip before the other passes: the people,
/// depth and tracking passes each need a shot's turn from its first frame on.
struct ShotPlan: Sendable {
    /// Every frame where the detector saw a cut; tracklets split at each of these.
    let detectedCuts: [Int]
    /// The cuts left after `ShortShots` absorbed false ones: the first frame of each shot after the first.
    let cuts: [Int]
    /// Per shot of `cuts`.
    let uprights: [Upright]

    func shot(of frame: Int) -> Int { cuts.filter { $0 <= frame }.count }
    func upright(of frame: Int) -> Upright { uprights[shot(of: frame)] }
}

extension Pipeline {
    func planShots(_ source: VideoSource) async throws -> ShotPlan {
        let tuning = options.tuning
        var shots = stages.shots
        var detected: [Int] = []
        // Small copies of the sampled frames: the decoder reuses its buffers.
        var samples: [Int: CIImage] = [:]
        let scale = min(1, 640 / max(source.size.width, source.size.height))
        try await source.forEachFrame { n, frame in
            let cut = try timed("cuts") { try shots.isCut(frame) }
            if cut { detected.append(n) }
            if n == 0 || cut || n % max(1, tuning.orientationProbeEvery) == 0 {
                samples[n] = try ownedCopy(
                    frame.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), context: context)
            }
        }
        let cuts = ShortShots.absorbed(cuts: detected, frameCount: source.frameCount, minFrames: tuning.minShotFrames)
        let bounds = [0] + cuts + [source.frameCount]
        let uprights = try (0..<(bounds.count - 1)).map { s in
            let frames = samples.filter { bounds[s] <= $0.key && $0.key < bounds[s + 1] }.sorted { $0.key < $1.key }
            let votes = try timed("orientation") { try stages.orientation.votes(frames.map(\.value)) }
            return Upright(degrees: Self.turn(votes, tuning: tuning), size: source.size)
        }
        for (s, u) in uprights.enumerated() where u.isTurned {
            log("Shot \(s) is filmed sideways: turned \(u.degrees)° for people, tracking and depth")
        }
        return ShotPlan(detectedCuts: detected, cuts: cuts, uprights: uprights)
    }

    /// The clockwise turn a shot's summed votes call for; 0 unless one turn clearly beats the shot as filmed.
    static func turn(_ votes: [Int: Double], tuning: Tuning) -> Int {
        guard let (degrees, best) = votes.max(by: { $0.value < $1.value }), degrees != 0,
            best >= tuning.orientationMinVotes, best >= tuning.orientationMargin * (votes[0] ?? 0)
        else { return 0 }
        return degrees
    }
}
