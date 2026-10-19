import CoreImage

extension Pipeline {
    /// People, faces and appearance, frame by frame, on each shot turned upright (`plan`), with masks, boxes and
    /// faces turned back into the source's frame; the normalised original is written alongside. Each frame's person
    /// boxes go to `feed` for the depth crops.
    func analysePeople(
        _ source: VideoSource, plan: ShotPlan, work: Workspace, feed: PeopleFeed
    ) async throws -> Analysis {
        defer { feed.close() }
        let detectedCuts = Set(plan.detectedCuts)
        var tracker = Tracker(tuning: options.tuning)
        var analysis = Analysis(perFrame: Array(repeating: [], count: source.frameCount))
        let prepared = try VideoWriter(
            url: work.file("prepared-silent.mp4"), size: source.size, fps: source.fps, context: context)
        do {
            try await source.forEachFrame { n, frame in
                try timed("encode") { try prepared.append(frame) }
                if detectedCuts.contains(n) { tracker.cut() }
                let upright = plan.upright(of: n)
                let turned = upright.upright(frame)
                let found = try timed("segmentation") { try stages.people.analyse(turned) }
                var detections: [PersonDetection] = []
                for mask in found.people {
                    if let d = try detect(
                        mask, frame: turned, upright: upright, at: (n, detections.count), found: found, work: work)
                    {
                        detections.append(d)
                    }
                }
                feed.publish(n, detections.map { PersonBox(key: $0.key, box: $0.box) })
                analysis.perFrame[n] = detections
                tracker.add(detections)
                if n % 48 == 0 { log("  analysed \(n)/\(source.frameCount)") }
            }
        } catch {
            prepared.cancel()
            throw error
        }
        try await prepared.finish()
        analysis.cuts = plan.cuts
        analysis.uprights = plan.uprights
        // Tracklets were split at every cut found; those across a dropped one stay apart and identity joins them.
        for tracklet in tracker.tracklets {
            let first = tracklet.detections.first?.frame ?? 0
            tracklet.shot = analysis.cuts.filter { $0 <= first }.count
        }
        analysis.tracklets = tracker.tracklets
        return analysis
    }

    /// One person found on the upright `frame`: faces, confirmation and appearance are judged there, the mask, box
    /// and face are kept in the source's frame.
    private func detect(
        _ mask: CIImage, frame: CIImage, upright: Upright, at: (frame: Int, index: Int), found: FrameAnalysis,
        work: Workspace
    ) throws -> PersonDetection? {
        let tuning = options.tuning
        let grid = timed("segmentation") { MaskGrid(mask: mask, side: tuning.grid, context: context) }
        guard grid.areaShare >= tuning.minPersonArea else { return nil }
        let box = Self.box(grid, in: frame.extent)
        let face = try timed("faces") {
            try stages.faces.face(in: frame, person: grid, personBox: box, frameFaces: found.faces)
        }
        let confirmed = face != nil || found.humans.contains { overlap($0, grid.unitBox) >= tuning.humanCoverage }
        let appearance = try timed("appearance") { try stages.appearance.appearance(of: frame, mask: mask, box: box) }
        let sourceMask = upright.source(mask)
        let sourceGrid =
            upright.isTurned
            ? timed("segmentation") { MaskGrid(mask: sourceMask, side: tuning.grid, context: context) } : grid
        let detection = PersonDetection(
            frame: at.frame, index: at.index, grid: sourceGrid,
            box: upright.isTurned ? Self.box(sourceGrid, in: CGRect(origin: .zero, size: upright.size)) : box,
            appearance: appearance, face: face.map { $0.mapped(upright.source) }, confirmed: confirmed)
        try timed("io") { try work.masks.store(sourceMask, key: detection.key, context: context) }
        return detection
    }

    /// The grid's box in the pixels of a frame with `extent`.
    private static func box(_ grid: MaskGrid, in e: CGRect) -> CGRect {
        let u = grid.unitBox
        return CGRect(x: u.minX * e.width, y: u.minY * e.height, width: u.width * e.width, height: u.height * e.height)
    }
}
