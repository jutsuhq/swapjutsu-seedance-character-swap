import CoreImage

extension Pipeline {
    /// Drops false positives, groups tracklets into people and picks who gets replaced.
    func decide(_ analysis: Analysis) throws -> Decision {
        let tuning = options.tuning
        let tracklets = analysis.tracklets.filter { $0.confirmedShare >= tuning.minConfirmed }
        let dropped = Set(
            analysis.tracklets.filter { $0.confirmedShare < tuning.minConfirmed }.flatMap { $0.detections.map(\.key) })
        if !dropped.isEmpty { log("Dropped \(dropped.count) detections in tracklets with no human shape or face") }
        guard !tracklets.isEmpty else { throw PrepError.noPerson }

        // Median appearance distance between samples of two tracklets: robust to a few bad frames.
        let samples = tracklets.map { $0.sample(8).map(\.appearance) }
        let result = timed("identity") {
            stages.identity.cluster(frames: tracklets.map(\.frames), weights: tracklets.map(\.screenArea)) { a, b in
                var values: [Float] = []
                for x in samples[a] { for y in samples[b] { values.append(x.distance(to: y, tuning: tuning)) } }
                return values.sorted()[values.count / 2]
            }
        }
        for (t, id) in zip(tracklets, result.identities) { t.identity = id }
        var identityOf: [String: Int] = [:]
        for t in tracklets { for d in t.detections { identityOf[d.key] = t.identity } }
        let targets: Set<Int>
        switch options.target {
        case .main: targets = [1]
        case .all:
            let frames = (1...result.count).map { id in
                Set(tracklets.filter { $0.identity == id }.flatMap(\.frames)).count
            }
            targets = Self.everyone(frames: frames, minFrames: tuning.minTrackletFrames)
        case .ids(let ids):
            let missing = ids.filter { !(1...result.count).contains($0) }
            guard missing.isEmpty else { throw PrepError.unknownTargets(requested: missing, available: result.count) }
            targets = Set(ids)
        }
        return Decision(
            cuts: analysis.cuts, uprights: analysis.uprights, perFrame: analysis.perFrame.map { $0.filter { !dropped.contains($0.key) } },
            tracklets: tracklets, result: result, identityOf: identityOf, targets: targets,
            bestShot: Self.bestShots(tracklets))
    }

    /// Everyone worth replacing, from each identity's frame count (ids from 1): a person seen in fewer than
    /// `minFrames` frames couldn't form an identity of their own and found no lookalike absent from their frames, so
    /// they are a fragment of someone on screen (a split mask, a hand), not a character Seedance should paint. A clip
    /// of only such people replaces them all.
    static func everyone(frames: [Int], minFrames: Int) -> Set<Int> {
        let lasting = frames.indices.filter { frames[$0] >= minFrames }.map { $0 + 1 }
        return Set(lasting.isEmpty ? Array(1...max(1, frames.count)) : lasting)
    }

    /// Which shots take the person crops, and each crop's fit onto the full-frame map. A shot takes the crops only
    /// when every target detection in it has one that fits; otherwise the whole shot keeps the full-frame depth, so
    /// the relief never changes character mid-shot.
    func cropFits(
        _ decision: Decision, targets: TargetMasks, depth: DepthResult, extent: CGRect, work: Workspace
    ) throws -> [String: DepthFit] {
        try timed("depth range") {
            var perShot: [Int: [(key: String, fit: DepthFit?)]] = [:]
            for (n, masks) in targets.perFrame.enumerated() where depth.frames.contains(n) {
                for m in masks {
                    var fit: DepthFit?
                    // Crops follow Vision's detections; a frame only the tracker has keeps the shot full-frame.
                    if let key = m.detection, let placed = try placedCrop(key, depth: depth, extent: extent, work: work)
                    {
                        let full = try placedDepth(frame: n, depth: depth, extent: extent, work: work)
                        fit = DepthCrop.fit(
                            crop: depthSamples(placed.image, mask: m.grid, context: context),
                            full: depthSamples(full, mask: m.grid, context: context))
                    }
                    perShot[decision.shot(of: n), default: []].append((m.detection ?? m.key, fit))
                }
            }
            var fits: [String: DepthFit] = [:]
            for (shot, samples) in perShot.sorted(by: { $0.key < $1.key }) where samples.allSatisfy({ $0.fit != nil }) {
                for s in samples { fits[s.key] = s.fit }
                let gain = samples.compactMap { depth.crops[$0.key] }
                    .map { Double(extent.width * extent.height / ($0.box.width * $0.box.height)) }
                log(
                    String(
                        format: "Depth shot %d: person crops, %.1f× the model pixels on the target (mean)", shot,
                        gain.reduce(0, +) / Double(max(1, gain.count))))
            }
            return fits
        }
    }

    /// The full-frame depth of `frame`, placed on the frame.
    func placedDepth(frame: Int, depth: DepthResult, extent: CGRect, work: Workspace) throws -> CIImage {
        try timed("io") { try work.depth.load(frame: frame, size: depth.size, format: depth.format) }
            .transformed(by: depth.toFrame[frame] ?? .identity).cropped(to: extent)
    }

    /// A person's depth crop placed on the frame (edge values extended past the crop box), or nil without one.
    func placedCrop(
        _ key: String, depth: DepthResult, extent: CGRect, work: Workspace
    ) throws -> (image: CIImage, box: CGRect)? {
        guard let placement = depth.crops[key] else { return nil }
        let map = try timed("io") { try work.depth.load(crop: key, size: depth.size, format: depth.format) }
        let image = map.transformed(by: placement.toFrame).cropped(to: placement.box).clampedToExtent()
            .cropped(to: extent)
        return (image, placement.box)
    }

    func feather(_ extent: CGRect) -> CGFloat { max(1, extent.width * options.tuning.depthCropFeather) }

    private static func bestShots(_ tracklets: [Tracklet]) -> [Int: PersonDetection] {
        let rank = { (x: PersonDetection) in (x.face == nil ? 0 : 1, x.grid.area) }
        var best: [Int: PersonDetection] = [:]
        for t in tracklets {
            for d in t.detections where best[t.identity].map({ rank(d) > rank($0) }) ?? true { best[t.identity] = d }
        }
        return best
    }
}
