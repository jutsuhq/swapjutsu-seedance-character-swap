import CoreImage

extension Pipeline {
    /// Writes the control, mask and review videos and the identity thumbnails; returns the targets' mean depth
    /// per frame, for the flicker metric, and where the face guide drew lines.
    func render(
        _ source: VideoSource, decision: Decision, targets: TargetMasks, depth: DepthResult, final: FinalDepth,
        hybrid: HybridMasks? = nil, work: Workspace
    ) async throws -> (depthMeans: [Int: Float], guide: FaceGuideTally) {
        let output = work.output
        let renderer = ControlRenderer(tuning: options.tuning, context: context)
        let writer = { (url: URL) in
            try VideoWriter(url: url, size: source.size, fps: source.fps, context: self.context)
        }
        let control = try writer(work.file("control-silent.mp4"))
        let maskVideo = try writer(output.appendingPathComponent("mask.mp4"))
        let review = options.review ? try writer(output.appendingPathComponent("review.mp4")) : nil
        let writers = [control, maskVideo] + (review.map { [$0] } ?? [])
        var depthMeans: [Int: Float] = [:]
        let tuning = options.tuning
        let radii = EditRegion.radii(targets.perFrame, shot: decision.shot(of:), size: source.size, tuning: tuning)
        var (occlusion, guide, held) = (OcclusionState(), FaceGuideTally(tuning, frame: source.size), HandCue.Hold())
        var bodies = options.matteOutline ? BodyOutline.Track() : try await skeletons(source, targets, decision)
        var targetFrames = 0
        do {
            try await source.forEachFrame { n, frame in
                let people = try decision.perFrame[n].compactMap { d -> PlacedPerson? in
                    guard let id = decision.identityOf[d.key] else { return nil }
                    let mask = try timed("io") { try work.masks.load(key: d.key, size: source.size) }
                    return PlacedPerson(detection: d, mask: mask, identity: id)
                }
                try writeThumbnails(people, frame: frame, decision: decision, output: output)
                let chosen = try targets.perFrame[n].map { m in
                    (target: m, mask: try timed("io") { try work.masks.load(key: m.key, size: source.size) })
                }
                let shot = decision.shot(of: n)
                let range = chosen.isEmpty ? nil : final.ranges[shot]
                let raw = try range.map { _ in
                    try finalMap(
                        frame: n, people: chosen.compactMap(\.target.detection), depth: depth, final: final,
                        extent: frame.extent, work: work)
                }
                let radius = { (id: Int) in radii[[shot, id]] ?? EditRegion.minimum(source.size, tuning: tuning) }
                targetFrames += chosen.count
                let outlines =
                    timed("outline") {
                        Self.silhouettes(
                            options.matteOutline || range == nil ? nil : chosen, frame: n, shot: shot,
                            extent: frame.extent, bodies: &bodies, radius: radius)
                    } ?? chosen.map { ($0.mask, nil) }
                let frameTargets = FrameTargets(
                    n: n, shot: shot, chosen: chosen, outlines: outlines, raw: raw, range: range, extent: frame.extent)
                let (masks, matte) = try timed("masks") {
                    try controlMasks(frameTargets, people, decision, renderer, &occlusion, radius: radius)
                }
                let background = try grey(
                    raw, placed: { try placedDepth(frame: n, depth: depth, extent: frame.extent, work: work) },
                    scene: final.scenes[shot], people: chosen.isEmpty ? nil : masks.edit, renderer: renderer)
                var out = background ?? frame
                if let range, let raw {
                    depthMeans[n] = range.meanInside(raw, mask: union(chosen.map(\.target.grid)), context: context)
                    let hands = try handMask(frame, n, shot, chosen.map(\.target), &held)
                    let painted = Self.painted(raw, chosen.map(\.mask), outlines, range: range, renderer: renderer)
                    out = try renderer.composite(
                        original: frame, background: background, depth: painted, range: range, masks: masks,
                        faces: options.faceGuide ? guide.faces(chosen.compactMap(\.target.face)) : [], hands: hands,
                        detail: options.control == .hybridHands ? details(chosen, raw, range) : [])
                    out = try hybridFrame(out, original: frame, n: n, masks: masks, hybrid: hybrid, work: work)
                }
                try timed("encode") {
                    try control.append(out)
                    try maskVideo.append(matte)
                    try review?.append(
                        renderer.review(original: frame, people: reviewed(people, chosen, targets: decision.targets)))
                }
                if n % 48 == 0 { log("  rendered \(n)/\(source.frameCount)") }
            }
        } catch {
            for w in writers { w.cancel() }
            throw error
        }
        for w in writers { try await w.finish() }
        if let summary = occlusion.summary(radii: radii) { log(summary) }
        if let summary = held.summary(of: source.frameCount) { log(summary) }
        if let summary = bodies.summary(of: targetFrames) { log(summary) }
        return (depthMeans, guide)
    }

    /// Everyone on the frame for review.mp4: the others by identity, then the targets.
    private func reviewed(
        _ people: [PlacedPerson], _ chosen: [(target: TargetMask, mask: CIImage)], targets: Set<Int>
    ) -> [(mask: CIImage, identity: Int, isTarget: Bool)] {
        people.filter { !targets.contains($0.identity) }.map { ($0.mask, $0.identity, false) }
            + chosen.map { ($0.mask, $0.target.identity, true) }
    }

    /// The targets' hands on frame `n` as the cue's mask (`HandCue`), searched in their boxes grown by a tenth, the
    /// last ones held through a frame or two Vision misses; nil with the cue off or no hand. The real hands of
    /// `hybrid-hands` replace it: lifted depth round the skin would paint the cuff and pocket nearer.
    private func handMask(
        _ frame: CIImage, _ n: Int, _ shot: Int, _ targets: [TargetMask], _ held: inout HandCue.Hold
    ) throws -> CIImage? {
        guard options.tuning.handLift > 0, options.control != .hybridHands else { return nil }
        let found = try timed("hands") { try hands(in: frame, targets: targets) }
        return HandCue.mask(held.hands(found, frame: n, shot: shot), extent: frame.extent)
    }

    func hands(in frame: CIImage, targets: [TargetMask]) throws -> [HandCue.Hand] {
        let size = frame.extent.size
        let hands = try targets.flatMap { target -> [HandCue.Hand] in
            let unit = target.grid.unitBox
            let box = CGRect(
                x: unit.minX * size.width, y: unit.minY * size.height, width: unit.width * size.width,
                height: unit.height * size.height)
            return try HandCue.hands(in: frame, box: box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.1))
        }
        return hands
    }

    /// The whole frame in grey depth for a replaced background, else nil: the targets' depth `raw` where the frame
    /// has them, else the plain per-frame map. A shot without targets has no `scene` scale and takes one from the
    /// frame itself, so no frame of the clip keeps the original pixels.
    private func grey(
        _ raw: CIImage?, placed: () throws -> CIImage, scene: ShotDepthRange?, people: CIImage?,
        renderer: ControlRenderer
    ) throws -> CIImage? {
        guard options.background == .replace else { return nil }
        let map = try raw ?? placed()
        guard let range = scene ?? sceneRange(map).flatMap({ ShotDepthRange([$0]) }) else {
            // Too few samples to scale: flat grey, still nothing of the original.
            return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: map.extent)
        }
        return renderer.settledGrey(map, range: range, people: people)
    }

    /// The control's masks painted from the frame's outlines, a silhouette not grown by the edit region (it holds
    /// it), and the mattes for mask.mp4, as tools that read it erode it back to the person.
    private func controlMasks(
        _ f: FrameTargets, _ people: [PlacedPerson], _ decision: Decision, _ renderer: ControlRenderer,
        _ occlusion: inout OcclusionState, radius: (Int) -> CGFloat
    ) throws -> (ControlMasks, CIImage) {
        occlusion.frame = f.n
        occlusion.continues = f.n > 0 && decision.shot(of: f.n - 1) == f.shot
        let reach = f.chosen.map { radius($0.target.identity) }.max() ?? 0
        let inFront =
            if let range = f.range, let raw = f.raw {
                occluders(
                    people.filter {
                        !decision.targets.contains($0.identity) && decision.bestShot[$0.identity]?.face != nil
                    },
                    targets: f.chosen.map(\.target), depth: raw, range: range,
                    reach: reach, state: &occlusion)
            } else { [(mask: CIImage, threshold: Float)]() }
        let objects = try f.raw.flatMap { try foreground(f.n, $0, f.chosen, people, reach, occlusion.continues) }
        let ramp = f.range.map { ($0.high - $0.low) * options.tuning.occlusionRamp } ?? 1
        let painted = renderer.masks(
            targets: zip(f.chosen, f.outlines).map { ($1.mask, $1.unit == nil ? radius($0.target.identity) : 0) },
            inFront: inFront, depth: f.raw, ramp: ramp, objects: objects, extent: f.extent)
        guard f.outlines.contains(where: { $0.unit != nil }) else { return (painted, painted.matte) }
        let mattes = renderer.masks(
            targets: f.chosen.map { ($0.mask, radius($0.target.identity)) }, inFront: inFront, depth: f.raw,
            ramp: ramp, objects: objects, extent: f.extent)
        return (painted, mattes.matte)
    }

    /// The extra protected mask of `frame` (`PrepStages.foreground`): objects in front of the targets (#56).
    private func foreground(
        _ frame: Int, _ depth: CIImage, _ targets: [(target: TargetMask, mask: CIImage)], _ people: [PlacedPerson],
        _ reach: CGFloat, _ continues: Bool
    ) throws -> CIImage? {
        try stages.foreground?.protectedMask(
            ForegroundFrame(
                index: frame, targets: targets.map(\.mask), people: people.map(\.mask), depth: depth,
                editRadius: reach, continues: continues))
    }

    /// The masks of the other people in front of the targets on this frame and the last (`Occlusion.front`), with
    /// the depth their pixels must be nearer than to stay. The order of each other person within `reach` pixels is
    /// counted in `state`.
    private func occluders(
        _ others: [PlacedPerson], targets: [TargetMask], depth: CIImage, range: ShotDepthRange, reach: CGFloat,
        state: inout OcclusionState
    ) -> [(mask: CIImage, threshold: Float)] {
        let size = depth.extent.size
        let target = union(targets.map(\.grid))
        let unit = target.unitBox
        let near = CGRect(
            x: unit.minX * size.width, y: unit.minY * size.height, width: unit.width * size.width,
            height: unit.height * size.height
        ).insetBy(dx: -2 * reach, dy: -2 * reach)
        // Cheap rejects first: unconfirmed detections and people whose box is nowhere near the target.
        let others = others.filter { $0.detection.confirmed && $0.detection.box.intersects(near) }
        guard !others.isEmpty else { return [] }
        let cell = min(size.width, size.height) / CGFloat(target.side)
        var samples: [Float]?
        func values() -> [Float] {
            if let samples { return samples }
            let all = MaskGrid(side: target.side, cells: [Bool](repeating: true, count: target.cells.count))
            let read = depthSamples(depth, mask: all, context: context)
            samples = read
            return read
        }
        let contact = Occlusion.Contact(target: target, reach: Int((reach / cell).rounded(.up)), tuning: options.tuning)
        return others.compactMap { other in
            guard
                let order = Occlusion.order(
                    contact, other: other.detection.grid, depth: values, span: range.high - range.low)
            else { return nil }
            state.counts[order.label, default: 0] += 1
            guard case .front(let threshold) = order else { return nil }
            defer { state.lastInFront[other.identity] = state.frame }
            guard state.continues, state.lastInFront[other.identity] == state.frame - 1 else { return nil }
            state.counts["protected", default: 0] += 1
            return (other.mask, threshold)
        }
    }

    /// The depth the control video paints on `frame`: smoothed from the cache, else the per-frame depth.
    private func finalMap(
        frame n: Int, people: [String], depth: DepthResult, final: FinalDepth, extent: CGRect, work: Workspace
    ) throws -> CIImage {
        guard final.smoothed.contains(n) else {
            return try paintedDepth(
                frame: n, people: people, depth: depth, fits: final.fits, extent: extent, work: work)
        }
        return try timed("io") { try work.depth.load(smoothed: n, size: extent.size) }
    }

    /// The full-frame depth of `frame` with the fitted crop of each of `people` that has one merged in.
    func paintedDepth(
        frame n: Int, people: [String], depth: DepthResult, fits: [String: DepthFit], extent: CGRect,
        work: Workspace
    ) throws -> CIImage {
        var raw = try placedDepth(frame: n, depth: depth, extent: extent, work: work)
        for key in people {
            guard let fit = fits[key],
                let crop = try placedCrop(key, depth: depth, extent: extent, work: work)
            else { continue }
            raw = DepthCrop.merge(full: raw, crop: crop.image, box: crop.box, fit: fit, feather: feather(extent))
        }
        return raw
    }

    private func writeThumbnails(_ people: [PlacedPerson], frame: CIImage, decision: Decision, output: URL) throws {
        for p in people {
            let d = p.detection
            guard let best = decision.bestShot[p.identity], best.frame == d.frame, best.index == d.index else {
                continue
            }
            let crop = frame.cropped(
                to: d.box.insetBy(dx: -d.box.width * 0.08, dy: -d.box.height * 0.04).intersection(frame.extent))
            // Upright like the person, whichever way the shot was filmed.
            let upright = crop.transformed(by: decision.upright(of: d.frame).toUpright)
            try context.writeJPEGRepresentation(
                of: upright, to: output.appendingPathComponent("identities/\(p.identity).jpg"),
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
    }

    /// `target`'s box in frame pixels, origin bottom-left.
    static func box(of target: TargetMask, in size: CGSize) -> CGRect {
        let unit = target.grid.unitBox
        return CGRect(
            x: unit.minX * size.width, y: unit.minY * size.height, width: unit.width * size.width,
            height: unit.height * size.height)
    }

    /// The masks' maximum; nil without any.
    static func union(_ masks: [CIImage]) -> CIImage? {
        masks.dropFirst().reduce(masks.first) { all, mask in
            all.map { mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) }
        }
    }

    func union(_ grids: [MaskGrid]) -> MaskGrid {
        let side = options.tuning.grid
        var cells = [Bool](repeating: false, count: side * side)
        for grid in grids { for k in cells.indices where grid.cells[k] { cells[k] = true } }
        return MaskGrid(side: side, cells: cells)
    }
}

/// Which target faces the face guide draws, frame by frame, and how tall they all were, for the log.
struct FaceGuideTally {
    /// `Tuning.faceGuideMinHeight` in pixels.
    let minHeight: CGFloat
    let frameHeight: CGFloat
    /// Frames with lines drawn.
    private(set) var frames = 0
    private(set) var heights: [CGFloat] = []

    init(_ tuning: Tuning, frame: CGSize) {
        (minHeight, frameHeight) = (tuning.faceGuideMinHeight * frame.height, frame.height)
    }

    /// The faces of one frame tall enough to draw (`FaceLandmarks.height`).
    mutating func faces(_ faces: [FaceLandmarks]) -> [FaceLandmarks] {
        heights += faces.map(\.height)
        let drawn = faces.filter { $0.height >= minHeight }
        if !drawn.isEmpty { frames += 1 }
        return drawn
    }

    /// "Face guide on 96 frames; target faces 4–21 % of the frame height (median 12 %), lines from 5 %".
    var summary: String {
        let sorted = heights.sorted().map { Double($0 / max(frameHeight, 1)) * 100 }
        let lines = String(format: "lines from %.1f %%", Double(minHeight / max(frameHeight, 1)) * 100)
        guard let low = sorted.first, let high = sorted.last else {
            return "Face guide on 0 frames; no target face found, \(lines)"
        }
        return "Face guide on \(frames) frames; target faces "
            + String(format: "%.1f–%.1f %% of the frame height (median %.1f %%), ", low, high, sorted[sorted.count / 2])
            + lines
    }
}

/// The other people's order over a render: counts for the log, and who was in front on which frame. Protection
/// starts on the second frame in a row in front, so a one-frame call cannot flash.
private struct OcclusionState {
    var counts: [String: Int] = [:]
    /// Identity → the last frame it was in front of a target.
    var lastInFront: [Int: Int] = [:]
    var frame = 0
    /// This frame is in the same shot as the one before.
    var continues = false

    /// The log line: edit radii and how often other people were in front, beside and behind.
    func summary(radii: [[Int]: CGFloat]) -> String? {
        let sizes = radii.values.sorted()
        guard let low = sizes.first, let high = sizes.last else { return nil }
        return "Edit region \(String(format: "%.1f–%.1f", low, high)) px over \(sizes.count) target shots; "
            + "other people in front \(counts["front"] ?? 0) (protected \(counts["protected"] ?? 0)), "
            + "beside \(counts["beside"] ?? 0), behind \(counts["behind"] ?? 0) person-frames"
    }
}
