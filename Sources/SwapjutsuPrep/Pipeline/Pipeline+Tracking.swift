import CoreImage
import Foundation

/// A target's mask on one frame: what the render, the depth scale and the quality metrics read.
struct TargetMask {
    let identity: Int
    /// Key in `MaskCache`.
    let key: String
    let grid: MaskGrid
    /// Vision's detection of the target on this frame, if any: its depth crop is keyed by it.
    let detection: String?
    /// Vision's face on this frame, when Vision found the target here.
    let face: FaceLandmarks?
}

/// The target masks of every frame: Vision's, with the shots the tracker took over replaced.
struct TargetMasks {
    var perFrame: [[TargetMask]]
    var tracking: Manifest.Tracking

    /// Vision's target detections, frame by frame.
    static func vision(_ decision: Decision, frames: Int) -> [[TargetMask]] {
        var perFrame = [[TargetMask]](repeating: [], count: frames)
        for t in decision.tracklets where decision.targets.contains(t.identity) {
            for d in t.detections where d.frame < frames {
                perFrame[d.frame].append(
                    TargetMask(
                        identity: t.identity, key: d.key, grid: d.grid, detection: d.key, face: d.face))
            }
        }
        return perFrame
    }
}

extension MaskTracking {
    public var timings: [String: Double] { [:] }
}

extension Pipeline {
    /// Follows each target through each shot from its first Vision mask there, or both ways from its best-scored one
    /// (`TrackingTuning.chooseSeed`). A shot takes the tracked masks
    /// only as a whole and only when the tracker kept the target (see `TrackingTuning`); otherwise, and when no
    /// tracker loads, it keeps Vision's, with the reason in the manifest. Vision's masks stay in the cache as they
    /// are; tracked ones are stored beside them (`t<target>_<frame>`).
    func trackTargets(_ source: VideoSource, decision: Decision, work: Workspace) async throws -> TargetMasks {
        let vision = TargetMasks.vision(decision, frames: source.frameCount)
        func visionOnly(_ tracker: String?, unavailable: String?) -> TargetMasks {
            TargetMasks(perFrame: vision, tracking: .init(tracker: tracker, unavailable: unavailable, shots: []))
        }
        guard let load = stages.tracking else { return visionOnly(nil, unavailable: "off") }
        var tracker: any MaskTracking
        let loadStart = Date()
        do { tracker = try await load() } catch {
            if error is CancellationError { throw error }
            log("Tracking unavailable, keeping Vision's masks: \(error)")
            return visionOnly(nil, unavailable: "\(error)")
        }
        timings["tracking load"] = Date().timeIntervalSince(loadStart)
        if decision.uprights.contains(where: \.isTurned) { tracker = UprightTracking(tracker) }

        let seeds = seedFrames(decision, vision: vision)
        let corrections = try userCorrections(decision, frames: source.frameCount, work: work)
        guard !seeds.isEmpty || !corrections.isEmpty else { return visionOnly(tracker.name, unavailable: nil) }

        let start = Date()
        let run = try await follow(
            source, tracker: tracker, seeds: Seeds(frames: seeds, corrections: corrections), vision: vision,
            decision: decision, work: work)
        timings["tracking"] = Date().timeIntervalSince(start)
        for (part, seconds) in tracker.timings { timings["tracking \(part)"] = seconds }
        return accept(run, vision: vision, decision: decision, frames: source.frameCount, tracker: tracker.name)
    }

    /// Each target's crop in each shot (shot → target), around its Vision boxes there.
    private func trackingCrops(_ decision: Decision, frames: Int, size: CGSize) -> [Int: [Int: TrackingCrop]] {
        var boxes: [[Int]: [CGRect]] = [:]
        for t in decision.tracklets where decision.targets.contains(t.identity) {
            for d in t.detections where d.frame < frames {
                boxes[[decision.shot(of: d.frame), t.identity], default: []].append(d.box)
            }
        }
        let tuning = options.tracking
        var crops: [Int: [Int: TrackingCrop]] = [:]
        for (key, shotBoxes) in boxes {
            crops[key[0], default: [:]][key[1]] = TrackingCrop.around(
                shotBoxes, frame: size, margin: tuning.cropMargin, minShare: tuning.cropMinShare)
        }
        return crops
    }

    /// Each target's seed frame in each shot ([shot, target] → frame): its first Vision mask there, or with
    /// `TrackingTuning.chooseSeed` the best of its masks there by `SeedChoice`.
    private func seedFrames(_ decision: Decision, vision: [[TargetMask]]) -> [[Int]: Int] {
        var seeds: [[Int]: Int] = [:]
        guard options.tracking.chooseSeed else {
            for (n, masks) in vision.enumerated() {
                for m in masks where seeds[[decision.shot(of: n), m.identity]] == nil {
                    seeds[[decision.shot(of: n), m.identity]] = n
                }
            }
            return seeds
        }
        var candidates: [[Int]: [SeedCandidate]] = [:]
        for t in decision.tracklets where decision.targets.contains(t.identity) {
            for d in t.detections where d.frame < vision.count {
                candidates[[decision.shot(of: d.frame), t.identity], default: []].append(
                    SeedCandidate(
                        frame: d.frame, grid: d.grid, face: d.face != nil, overlap: Self.overlap(d, decision)))
            }
        }
        for (key, list) in candidates {
            if let best = SeedChoice.best(list, tuning: options.tracking) { seeds[key] = best.frame }
        }
        return seeds
    }

    /// The largest share of a detection's box covered by another person's box on its frame.
    private static func overlap(_ d: PersonDetection, _ decision: Decision) -> Double {
        let area = max(1, d.box.width * d.box.height)
        return decision.perFrame[d.frame].filter { $0.key != d.key }.map {
            let i = $0.box.intersection(d.box)
            return i.isNull ? 0 : Double(i.width * i.height / area)
        }.max() ?? 0
    }

    /// Re-seeding from Vision (`TrackingTuning.reseed`): which Vision target masks are confident, shot by shot
    /// (`ReseedConfidence`), from the face, the other people's boxes and the identity of each detection.
    private func visionReseeding(
        _ decision: Decision, vision: [[TargetMask]], bounds: [Int], size: CGSize, work: Workspace
    ) -> VisionReseeding {
        let tuning = options.tracking.reseed
        var lookAlike = Set<Int>()
        if let (a, b, d) = decision.result.closestSeparate,
            d < options.tuning.mergeDistance + options.tuning.ambiguityMargin
        {
            lookAlike = [a, b]
        }
        // Alone on the frame (as measured) or by box overlap; unknown counts as crowded.
        func overlap(_ d: PersonDetection?) -> Double {
            guard let d else { return 1 }
            if tuning.aloneOnFrame { return decision.perFrame[d.frame].count > 1 ? 1 : 0 }
            return Self.overlap(d, decision)
        }
        let detections = Dictionary(decision.perFrame.joined().map { ($0.key, $0) }) { a, _ in a }
        var confident = Set<[Int]>()
        for s in 0..<(bounds.count - 1) {
            let frames = Array(bounds[s]..<min(bounds[s + 1], vision.count))
            for id in decision.targets.sorted() {
                let observations = frames.map { n -> VisionObservation? in
                    let mine = vision[n].filter { $0.identity == id }
                    guard let m = mine.first else { return nil }
                    let d = m.detection.flatMap { detections[$0] }
                    return VisionObservation(
                        grid: m.grid, face: m.face != nil, overlap: overlap(d),
                        unambiguous: mine.count == 1 && d?.confirmed == true && !lookAlike.contains(id))
                }
                for (n, doubt) in zip(frames, ReseedConfidence.doubts(observations, tuning: tuning)) where doubt == nil
                {
                    confident.insert([n, id])
                }
            }
        }
        let (side, context) = (options.tuning.grid, context)
        return VisionReseeding(
            tuning: tuning,
            vision: { _, id, n in
                vision[n].first { $0.identity == id }.map { ($0.grid, confident.contains([n, id])) }
            },
            mask: { _, id, n in
                guard let m = vision[n].first(where: { $0.identity == id }) else {
                    throw PrepError.model("no Vision mask of target \(id) on frame \(n)")
                }
                return [UInt8](try work.masks.bytes(key: m.key, size: size))
            },
            grid: {
                MaskGrid(bytes: $0, width: Int(size.width), height: Int(size.height), side: side, context: context)
            })
    }

    /// The person's corrections in the prep folder (`TargetCorrections`) by [shot, target], in the order made; those
    /// of people who are not targets, or of frames past the clip, are left out.
    private func userCorrections(
        _ decision: Decision, frames: Int, work: Workspace
    ) throws -> [[Int]: [TargetCorrection]] {
        var out: [[Int]: [TargetCorrection]] = [:]
        for c in try TargetCorrections.load(from: work.output) {
            guard decision.targets.contains(c.identity), (0..<frames).contains(c.frame) else {
                log("Skipping the correction of person \(c.identity) on frame \(c.frame): not a target frame")
                continue
            }
            out[[decision.shot(of: c.frame), c.identity], default: []].append(c)
        }
        // The conditioning slots: the seed and `BankLayout.maxCorrections` more, the latest made.
        return out.mapValues { Array($0.suffix(1 + BankLayout.maxCorrections)) }
    }

    /// Runs the tracker over the clip (`TwoWayTracking`), each target in its crop of each shot when
    /// `TrackingTuning.crop` is on, storing each tracked mask in the cache as it comes. Target shots the person
    /// corrected are left out of that pass and re-tracked from their corrections afterwards (`CorrectedTracking`).
    private func follow(
        _ source: VideoSource, tracker: any MaskTracking, seeds: Seeds, vision: [[TargetMask]], decision: Decision,
        work: Workspace
    ) async throws -> TrackingRun {
        var run = TrackingRun()
        let crops = options.tracking.crop ? trackingCrops(decision, frames: source.frameCount, size: source.size) : [:]
        run.crops = crops
        let bounds = [0] + decision.cuts + [source.frameCount]
        var shotSeeds: [Int: [Int: Int]] = [:]
        for (key, frame) in seeds.frames where seeds.corrections[key] == nil {
            shotSeeds[key[0], default: [:]][key[1]] = frame
            run.tracks[key] = ShotTrack(seedFrame: frame)
        }
        let shots = (0..<(bounds.count - 1)).map {
            TwoWayTracking.Shot(
                start: bounds[$0], end: bounds[$0 + 1], seeds: shotSeeds[$0] ?? [:], crops: crops[$0] ?? [:],
                upright: decision.uprights[$0])
        }
        var found: [[Int]: [Found]] = [:]
        let reseeding =
            options.tracking.reseed.enabled
            ? visionReseeding(decision, vision: vision, bounds: bounds, size: source.size, work: work) : nil
        let twoWay = TwoWayTracking(
            tracker: tracker, shots: shots, backward: options.tracking.chooseSeed, context: context,
            seedMask: { _, id, n in
                guard let m = vision[n].first(where: { $0.identity == id }) else {
                    throw PrepError.model("no Vision mask of target \(id) on frame \(n)")
                }
                return [UInt8](try work.masks.bytes(key: m.key, size: source.size))
            },
            emit: { [self] n, s, id, result in
                let seen = vision[n].first { $0.identity == id }
                let mask = try result.mask.flatMap {
                    try store($0, identity: id, frame: n, size: source.size, seen: seen, work: work)
                }
                found[[s, id], default: []].append(Found(frame: n, mask: mask, score: result.score))
            }, reseeding: reseeding)
        try await source.forEachFrame { n, frame in
            try twoWay.feed(n, frame)
            if n % 48 == 0 { log("  tracked \(n)/\(source.frameCount)") }
        }
        try twoWay.finish()
        for (s, error) in twoWay.failed.sorted(by: { $0.key < $1.key }) {
            log("Tracking failed in shot \(s), keeping Vision's masks there: \(error)")
            run.failed[s] = error
        }
        let again = Retrack(
            source: source, bounds: bounds, uprights: decision.uprights, tracker: tracker, vision: vision, reseeding: reseeding, work: work)
        found.merge(try await retrackCorrected(seeds.corrections, crops: crops, again, run: &run)) { $1 }
        if let reseeding {
            for c in reseeding.corrections { run.tracks[[c.shot, c.object]]?.reseeds.append(c.frame) }
            if !reseeding.corrections.isEmpty { log("Re-seeded \(reseeding.corrections.count) times from Vision") }
        }
        run.record(found, vision: vision)
        return run
    }

    /// Every corrected target shot re-tracked (`retrack`), its track in `run` with the corrections; a shot whose
    /// re-tracking fails keeps Vision's masks.
    private func retrackCorrected(
        _ corrections: [[Int]: [TargetCorrection]], crops: [Int: [Int: TrackingCrop]], _ again: Retrack,
        run: inout TrackingRun
    ) async throws -> [[Int]: [Found]] {
        var found: [[Int]: [Found]] = [:]
        for (key, list) in corrections.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            var track = ShotTrack(seedFrame: list.map(\.frame).min() ?? 0)
            track.corrections = Set(list.map(\.frame)).sorted()
            do {
                found[key] = try await retrack(key, list, crop: crops[key[0]]?[key[1]], again)
            } catch {
                if error is CancellationError { throw error }
                log("Re-tracking shot \(key[0]) from the corrections failed, keeping Vision's masks there: \(error)")
                track.failure = "\(error)"
            }
            run.tracks[key] = track
        }
        return found
    }

    /// One corrected target shot ([shot, target]) tracked both ways from the person's corrections, the shot re-read
    /// from the clip. The crop is the shot's as Vision's boxes give it, or the full frame when a correction reaches
    /// outside it (the person picked someone Vision did not follow there).
    private func retrack(
        _ key: [Int], _ list: [TargetCorrection], crop: TrackingCrop?, _ again: Retrack
    ) async throws -> [Found] {
        let (source, work, vision) = (again.source, again.work, again.vision)
        let (s, id) = (key[0], key[1])
        let (width, height) = (Int(source.size.width), Int(source.size.height))
        let prompts = try list.map { c -> CorrectedTracking.Correction in
            switch c.kind {
            case .point(let x, let y):
                return .init(frame: c.frame, prompt: .point(CGPoint(x: x * Double(width), y: y * Double(height))))
            case .mask(let file):
                let url = work.output.appending(path: file)
                return .init(
                    frame: c.frame, prompt: .mask(try TargetCorrections.maskBytes(url, width: width, height: height)))
            }
        }
        let inside =
            crop.map { crop in prompts.allSatisfy { CorrectionPreview.contains(crop, $0.prompt, width: width) } }
            ?? false
        log("Re-tracking shot \(s) of person \(id) from \(list.count) correction(s), frames \(list.map(\.frame))")
        var out: [Found] = []
        let driver = CorrectedTracking(
            tracker: again.tracker, context: context, read: { try await source.forEachFrame(in: $0, $1) },
            reseeding: again.reseeding,
            progress: { [log] done, total in if done % 48 == 0 { log("  re-tracked \(done)/\(total)") } })
        let shot = CorrectedTracking.Shot(
            index: s, start: again.bounds[s], end: again.bounds[s + 1], object: id, crop: inside ? crop : nil,
            corrections: prompts, upright: again.uprights[s])
        try await driver.run(shot) { n, result in
            let seen = vision[n].first { $0.identity == id }
            let mask = try result.mask.flatMap {
                try store($0, identity: id, frame: n, size: source.size, seen: seen, work: work)
            }
            out.append(Found(frame: n, mask: mask, score: result.score))
        }
        return out
    }

    /// A tracked mask into the cache; nil when it is empty on the grid.
    private func store(
        _ bytes: [UInt8], identity: Int, frame n: Int, size: CGSize, seen: TargetMask?, work: Workspace
    ) throws -> TargetMask? {
        let grid = MaskGrid(
            bytes: bytes, width: Int(size.width), height: Int(size.height), side: options.tuning.grid,
            context: context)
        guard grid.area > 0 else { return nil }
        let key = "t\(identity)_\(n)"
        try work.masks.store(Data(bytes), key: key)
        return TargetMask(identity: identity, key: key, grid: grid, detection: seen?.detection, face: seen?.face)
    }

    /// Whole shots of tracked masks in place of Vision's where the tracker kept the target, its short losses filled
    /// from Vision (`TargetMasks.filled`).
    private func accept(
        _ run: TrackingRun, vision: [[TargetMask]], decision: Decision, frames: Int, tracker: String
    ) -> TargetMasks {
        let bounds = [0] + decision.cuts + [frames]
        var perFrame = vision
        var report: [Manifest.TrackedShot] = []
        for (key, track) in run.tracks.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            let (s, id) = (key[0], key[1])
            // A shot the person corrected keeps the tracked masks unless re-tracking failed.
            let fallback =
                run.failed[s] ?? track.failure ?? (track.corrections.isEmpty ? track.fallback(options.tracking) : nil)
            var filled: [Int] = []
            if fallback == nil {
                let shot = TargetMasks.filled(
                    tracked: track.masks, vision: vision, identity: id, frames: bounds[s]..<bounds[s + 1],
                    maxAreaRatio: options.tracking.reseed.maxAreaRatio)
                filled = shot.filled
                for n in bounds[s]..<bounds[s + 1] {
                    perFrame[n].removeAll { $0.identity == id }
                    if let m = shot.masks[n] { perFrame[n].append(m) }
                }
            }
            let filledSet = Set(filled)
            let flags = TrackingFlags.flags(
                (bounds[s]..<bounds[s + 1]).map { n in
                    TrackingFlags.Frame(
                        frame: n, mask: perFrame[n].first { $0.identity == id }?.grid,
                        score: fallback == nil && !filledSet.contains(n) ? track.scores[n] : nil,
                        visionSees: vision[n].contains { $0.identity == id }, filled: filledSet.contains(n),
                        others: decision.perFrame[n].filter { decision.identityOf[$0.key] != id }.map(\.grid))
                }, tuning: options.tracking.flags)
            report.append(
                Manifest.TrackedShot(
                    shot: s, target: id, source: fallback == nil ? "tracked" : "vision", fallback: fallback,
                    seedFrame: track.seedFrame, trackedFrames: track.masks.count, recoveredFrames: track.recovered,
                    lostFrames: track.lost, longestLoss: track.longestLoss, filledFrames: filled.count,
                    agreement: track.agreement,
                    crop: run.crops[s]?[id].map { [$0.x, $0.y, $0.width, $0.height] },
                    reseeds: options.tracking.reseed.enabled ? track.reseeds.sorted() : nil,
                    corrections: track.corrections.isEmpty ? nil : track.corrections, flags: flags))
        }
        let kept = report.filter { $0.fallback == nil }.count
        log("Tracked \(kept) of \(report.count) target shots with \(tracker)")
        return TargetMasks(perFrame: perFrame, tracking: .init(tracker: tracker, unavailable: nil, shots: report))
    }
}

/// Each target shot's seed frame ([shot, target]), and the person's corrections of the shots that have them.
private struct Seeds {
    let frames: [[Int]: Int]
    let corrections: [[Int]: [TargetCorrection]]
}

/// One tracked mask as it comes, with the tracker's object score.
private struct Found {
    let frame: Int
    let mask: TargetMask?
    let score: Float
}

/// What re-tracking a corrected shot reads.
private struct Retrack {
    let source: VideoSource
    let bounds: [Int]
    let uprights: [Upright]
    let tracker: any MaskTracking
    let vision: [[TargetMask]]
    let reseeding: VisionReseeding?
    let work: Workspace
}

/// Every target shot of a tracking pass, the shots where the tracker threw, and the crops it tracked in.
private struct TrackingRun {
    var tracks: [[Int]: ShotTrack] = [:]
    var crops: [Int: [Int: TrackingCrop]] = [:]
    var failed: [Int: String] = [:]

    /// Masks come out of order going both ways; the loss streaks are counted in frame order.
    mutating func record(_ found: [[Int]: [Found]], vision: [[TargetMask]]) {
        for (key, masks) in found {
            for f in masks.sorted(by: { $0.frame < $1.frame }) {
                tracks[key]?.record(
                    f.mask, score: f.score, frame: f.frame, vision: vision[f.frame].first { $0.identity == key[1] })
            }
        }
    }
}

/// One target through one shot, while tracking.
private struct ShotTrack {
    let seedFrame: Int
    var masks: [Int: TargetMask] = [:]
    /// Frames re-seeded from Vision (`TrackingTuning.reseed`).
    var reseeds: [Int] = []
    /// Frames the person corrected, and why re-tracking from them failed.
    var corrections: [Int] = []
    var failure: String?
    /// The tracker's object score by frame.
    var scores: [Int: Float] = [:]
    var ious: [Double] = []
    var recovered = 0
    var lost = 0
    var longestLoss = 0
    private var loss = 0

    init(seedFrame: Int) { self.seedFrame = seedFrame }

    var agreement: Double? { ious.isEmpty ? nil : ious.reduce(0, +) / Double(ious.count) }

    /// Nil when the shot can take the tracked masks.
    func fallback(_ tuning: TrackingTuning) -> String? {
        if longestLoss >= tuning.lostFrames { return "lost" }
        if let agreement, agreement < tuning.minAgreement { return "disagrees" }
        return nil
    }

    /// The tracker's mask on `frame`, or nil when it does not see the target there.
    mutating func record(_ mask: TargetMask?, score: Float, frame: Int, vision: TargetMask?) {
        scores[frame] = score
        guard let mask else {
            // Lost only where Vision still sees the target; otherwise both agree it is gone.
            guard vision != nil else { return }
            lost += 1
            loss += 1
            longestLoss = max(longestLoss, loss)
            return
        }
        masks[frame] = mask
        if let vision { ious.append(mask.grid.iou(vision.grid)) } else { recovered += 1 }
        loss = 0
    }
}
