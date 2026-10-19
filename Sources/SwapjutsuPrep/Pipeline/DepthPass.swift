import CoreImage

/// Depth of every working frame into the cache, on its own decoder and task, while the people pass runs. The model
/// loads first, overlapping the first frames of segmentation; the estimate for frames with nobody in them is
/// cheap next to waiting for segmentation to say who is there.
///
/// Beside it, a second decoder follows the people pass a few frames behind: as each frame's person boxes arrive,
/// it runs the model again on a crop around each of the largest people (`DepthCrop`). Segmentation is the slower
/// pass, so both depth loops finish before it does. They share the model under a lock.
///
/// The model sees each shot turned upright (`ShotPlan`), full frames and crops alike; each map's placement turns it
/// back onto the source's frame.
struct DepthPass: Sendable {
    let source: VideoSource
    let plan: ShotPlan
    let cache: DepthCache
    let feed: PeopleFeed
    let tuning: Tuning
    let load: @Sendable () async throws -> any DepthEstimating
    let log: @Sendable (String) -> Void

    init(
        source: VideoSource, plan: ShotPlan, cache: DepthCache, feed: PeopleFeed, tuning: Tuning,
        load: @escaping @Sendable () async throws -> any DepthEstimating, log: @escaping (String) -> Void
    ) {
        self.source = source
        self.plan = plan
        self.cache = cache
        self.feed = feed
        self.tuning = tuning
        self.load = load
        // The log closure only forwards lines; callers pass thread-safe sinks (the CLI writes to stdout, the app
        // hops to the main actor).
        nonisolated(unsafe) let forward = log
        self.log = { forward($0) }
    }

    @concurrent func run() async throws -> DepthResult {
        let loadStart = Date()
        let model = Locked(try await load())
        let modelLoad = Date().timeIntervalSince(loadStart)
        async let full = fullFrames(model)
        let crops = try await withTaskExecutorPreference(feed.executor) { try await personCrops(model) }
        let maps = try await full
        let (frames, format) = (maps.frames, maps.format)
        guard let first = maps.first else { throw PrepError.model("no depth output") }
        guard crops.sizes.allSatisfy({ $0 == first.size }), crops.formats.allSatisfy({ $0 == format }) else {
            throw PrepError.model("depth crops differ from the full-frame maps")
        }
        log(
            "Depth: \(frames.count) frames, \(crops.placements.count) person crops, model loaded in \(String(format: "%.1f", modelLoad)) s"
        )
        return DepthResult(
            frames: frames, size: first.size, toFrame: maps.toFrame, crops: crops.placements, format: format,
            modelLoad: modelLoad, inference: maps.inference + crops.inference)
    }

    private struct FullFrames {
        var frames = Set<Int>()
        var first: DepthMap?
        var toFrame: [Int: CGAffineTransform] = [:]
        var format = DepthFormat.half
        var inference = 0.0
    }

    @concurrent private func fullFrames(_ model: Locked) async throws -> FullFrames {
        var maps = FullFrames()
        try await source.forEachFrame { n, frame in
            let upright = plan.upright(of: n)
            let start = Date()
            let map = try model.depth(of: upright.upright(frame))
            maps.inference += Date().timeIntervalSince(start)
            maps.toFrame[n] = map.toFrame.concatenating(upright.toSource)
            guard let mapFormat = DepthFormat(map.buffer) else {
                throw PrepError.model("unsupported depth pixel format")
            }
            if maps.first == nil {
                maps.first = map
                maps.format = mapFormat
            }
            try cache.store(map, frame: n)
            maps.frames.insert(n)
        }
        return maps
    }

    private struct Crops {
        var placements: [String: DepthCropPlacement] = [:]
        var sizes = Set<CGSize>()
        var formats = Set<DepthFormat?>()
        var inference = 0.0
    }

    @concurrent private func personCrops(_ model: Locked) async throws -> Crops {
        var crops = Crops()
        guard tuning.depthCrops > 0 else { return crops }
        let modelAspect = model.inputSize.map { $0.width / $0.height }
        var previous: [CGRect] = []
        try await source.forEachFrame { n, frame in
            guard let people = feed.people(in: n) else { throw CancellationError() }
            var boxes: [CGRect] = []
            for person in people.sorted(by: { $0.box.width * $0.box.height > $1.box.width * $1.box.height })
                .prefix(tuning.depthCrops)
            {
                let need = DepthCrop.padded(person.box, in: frame.extent, tuning: tuning)
                let fresh = DepthCrop.box(
                    containing: need, in: frame.extent,
                    modelAspect: modelAspect ?? frame.extent.width / frame.extent.height,
                    maxShare: tuning.depthCropMaxShare)
                guard let box = DepthCrop.stable(fresh, need: need, previous: previous) else { continue }
                // The crop turns upright with its shot, about its own origin.
                let upright = Upright(degrees: plan.upright(of: n).degrees, size: box.size)
                let start = Date()
                let crop = try model.depth(
                    of: upright.upright(
                        frame.cropped(to: box).transformed(
                            by: CGAffineTransform(translationX: -box.minX, y: -box.minY))))
                crops.inference += Date().timeIntervalSince(start)
                try cache.store(crop, crop: person.key)
                crops.sizes.insert(crop.size)
                crops.formats.insert(DepthFormat(crop.buffer))
                crops.placements[person.key] = DepthCropPlacement(
                    box: box,
                    toFrame: crop.toFrame.concatenating(upright.toSource).concatenating(
                        CGAffineTransform(translationX: box.minX, y: box.minY)))
                boxes.append(box)
            }
            previous = boxes
        }
        return crops
    }
}

/// The depth model behind a lock: the full-frame and crop loops call it from two tasks, and an estimator is
/// used from one task at a time.
private final class Locked: @unchecked Sendable {
    private let model: any DepthEstimating
    private let lock = NSLock()

    init(_ model: any DepthEstimating) { self.model = model }

    var inputSize: CGSize? { model.inputSize }

    func depth(of frame: CIImage) throws -> DepthMap { try lock.withLock { try model.depth(of: frame) } }
}
