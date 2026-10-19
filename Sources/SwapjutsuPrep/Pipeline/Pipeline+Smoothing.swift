import CoreImage

/// The final per-frame depth of the targets: what the shot scale is measured on and the control video paints.
struct FinalDepth {
    let ranges: [Int: ShotDepthRange]
    /// With the background replaced, the grey scale per shot (`ControlRenderer.greyDepth`): measured like `ranges`
    /// but over the whole frame, since the targets' scale would clamp most of the scene to its far end. Fixed per
    /// shot from the same depth, so the scene's grey cannot flicker against the targets' colours. Empty otherwise.
    var scenes: [Int: ShotDepthRange] = [:]
    /// The person crops' fits onto the full-frame maps, for the shots that take crops.
    let fits: [String: DepthFit]
    /// Frames whose smoothed depth is in the cache; the others paint their per-frame depth.
    let smoothed: Set<Int>
    let residual: DepthResidual?
}

/// Mean motion-compensated per-pixel depth change between consecutive target frames, on the shot scale.
struct DepthResidual {
    let raw: Double
    let smoothed: Double
}

extension Pipeline {
    /// The optical flow pass, unless smoothing is off.
    func flowPass(_ source: VideoSource, work: Workspace) -> FlowPass? {
        let tuning = options.tuning
        guard tuning.depthSmoothing > 0 else { return nil }
        return FlowPass(
            source: source, cache: FlowCache(directory: work.depth.directory), tuning: tuning, context: context)
    }

    /// Each target frame's depth (full frame with the fitted crops merged), smoothed along the optical flow when
    /// `flows` is there (#17), then one colour scale per shot from it: measured on the targets only, so the
    /// background never flattens them, and fixed, so the scale cannot flicker.
    ///
    /// Smoothing sits here, after the crops are merged and before the shot scale, rather than on the raw model maps
    /// or in the render: the crop merge changes the relief under the target, so smoothing earlier would let it
    /// shimmer again; the scale must be measured on the depth that is painted; and the edge refinement of the render
    /// (`DepthEdges`) must run after it, on this frame's mask, or the previous frames' silhouettes would trail.
    func finalDepth(
        _ decision: Decision, targets: TargetMasks, depth: DepthResult, flows: FlowResult?, extent: CGRect,
        work: Workspace
    ) throws -> FinalDepth {
        let fits = try cropFits(decision, targets: targets, depth: depth, extent: extent, work: work)
        if let flows { (timings["flow"], timings["flow vision"]) = (flows.seconds, flows.vision) }
        return try timed("depth smoothing") {
            let flowCache = FlowCache(directory: work.depth.directory)
            var smoother = flows.map {
                DepthSmoother(
                    settings: .init(tuning: options.tuning), width: $0.width, height: $0.height, context: context)
            }
            var tally = SmoothingTally()
            for (n, masks) in targets.perFrame.enumerated() {
                guard !masks.isEmpty, depth.frames.contains(n) else {
                    smoother?.skip()
                    continue
                }
                try Task.checkCancellation()
                // Core Image and Metal objects of each frame go with it, as in the frame loops.
                try autoreleasepool {
                    let shot = decision.shot(of: n)
                    var map = try paintedDepth(
                        frame: n, people: masks.compactMap(\.detection), depth: depth, fits: fits, extent: extent,
                        work: work)
                    if var active = smoother, let flows {
                        let flow =
                            flows.frames.contains(n)
                            ? try timed("io") { try flowCache.load(frame: n, width: flows.width, height: flows.height) }
                            : nil
                        let step = try active.step(
                            frame: n, shot: shot, targets: Set(masks.map(\.identity)), depth: map, flow: flow,
                            mask: union(masks.map(\.grid)))
                        smoother = active
                        try timed("io") { try work.depth.store(smoothed: step.half, frame: n) }
                        tally.add(step, frame: n, shot: shot)
                        map = step.depth
                    }
                    for m in masks {
                        if let range = depthRange(depthSamples(map, mask: m.grid, context: context)) {
                            tally.ranges[shot, default: []].append(range)
                        }
                    }
                    if options.background == .replace, let scene = sceneRange(map) { tally.scenes[shot, default: []].append(scene) }
                }
            }
            let final = tally.result(fits: fits)
            if smoother != nil {
                log(
                    "Depth smoothing: \(final.smoothed.count) frames, \(tally.resets) history resets"
                        + (final.residual.map { String(format: ", residual %.4f → %.4f", $0.raw, $0.smoothed) } ?? ""))
            }
            return final
        }
    }
}

extension Pipeline {
    /// 2nd–98th percentile of `depth` over the whole frame, on the mask grid.
    func sceneRange(_ depth: CIImage) -> ClosedRange<Float>? {
        let side = options.tuning.grid
        let all = MaskGrid(side: side, cells: [Bool](repeating: true, count: side * side))
        return depthRange(depthSamples(depth, mask: all, context: context))
    }
}

/// What the smoothing loop collects, frame by frame.
private struct SmoothingTally {
    var ranges: [Int: [ClosedRange<Float>]] = [:]
    var scenes: [Int: [ClosedRange<Float>]] = [:]
    var smoothed = Set<Int>()
    var resets = 0
    /// Per frame: its shot and the residual before and after smoothing, in depth units.
    private var residuals: [(shot: Int, values: (raw: Float, smoothed: Float))] = []

    mutating func add(_ step: DepthSmoother.Step, frame n: Int, shot: Int) {
        smoothed.insert(n)
        if step.reset { resets += 1 }
        if let r = step.residual { residuals.append((shot, r)) }
    }

    /// The shot scales, and the residuals on them: depth units over each shot's span.
    func result(fits: [String: DepthFit]) -> FinalDepth {
        let shots = ranges.compactMapValues(ShotDepthRange.init)
        let scaled = residuals.compactMap { r in
            shots[r.shot].map {
                (Double(r.values.raw / ($0.high - $0.low)), Double(r.values.smoothed / ($0.high - $0.low)))
            }
        }
        let count = Double(scaled.count)
        let residual =
            scaled.isEmpty
            ? nil
            : DepthResidual(raw: scaled.map(\.0).reduce(0, +) / count, smoothed: scaled.map(\.1).reduce(0, +) / count)
        return FinalDepth(
            ranges: shots, scenes: scenes.compactMapValues(ShotDepthRange.init), fits: fits, smoothed: smoothed,
            residual: residual)
    }
}
