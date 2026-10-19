import Accelerate
import CoreImage
import CoreML
import Foundation

/// One object's mask on one frame, from a `MaskTracking` tracker.
public struct TrackedMask: Sendable {
    /// Above 0 when the tracker sees the object on this frame.
    public let score: Float
    /// Soft 0–255, frame-sized, rows top-down; nil when the object is not on this frame (`score` ≤ 0).
    public let mask: [UInt8]?

    public init(score: Float, mask: [UInt8]?) {
        self.score = score
        self.mask = mask
    }
}

/// EdgeTAM's video tracker (`EdgeTAMModels`), as SAM 2 runs it: each object is seeded once per shot and followed
/// with a memory bank of its seed frame and its six most recent frames.
///
/// The seed mask goes through the memory encoder as confident logits (±10, object score 10), and through the
/// initializer for the object pointer as one interior point (nearest the mask's centroid). The ±10 and the 10 are what
/// SAM 2 gives a mask prompt (`_use_mask_as_output`) and what our initializer returns for the mask itself. A pointer
/// from the mask too, so that memory and pointer share one prompt, gains on orange-jacket and loses on
/// crowd-interaction (benchmarks/README.md, Section 7.12), so the point stays. Each later frame's bank
/// holds the frames 1…6 back in slots 0–5 with temporal index = frames back (`MemoryBank.spatial`), and the seed in
/// slot 6 with temporal index 6; spatial positions are the memory positions plus that temporal position; the pointer
/// bank holds the seed's pointer in slot 0 and the 15 most recent pointers after it; empty slots get an attention
/// bias of −30000, which only the community propagator reads (`Bank`). Corrections (re-seeds from Vision, #13) join the seed as conditioning frames at temporal index 6 in slots 5
/// and 4, and their pointers follow the seed's, so fewer recent frames fit (`BankLayout`); with no correction the
/// bank is as above. The soft mask is the sigmoid of the 1024² logits sampled bilinearly to the frame.
///
/// The image encoder runs once per frame for all objects; the rest per object. With `encodeAhead`, the next frame's
/// encoding (`lookahead`) runs on its own queue while this frame propagates (`FrameEncoding`). The bank assembly and the logits
/// resize run on the CPU with Accelerate, about 0.3–0.5 ms and 2.6–5 ms a frame on an M4 (in Debug builds too; #21):
/// cheap next to the 55–60 ms of the two per-frame models, so not moved to the GPU.
public final class EdgeTAMTracker: MaskTracking {
    public let name = "EdgeTAM"
    let models: EdgeTAMModels
    let context: CIContext
    /// Seconds summed over the run, by model and by CPU step (`seed`, `prepare`, `bank`, `resize`).
    public private(set) var timings: [String: Double] = [:]
    public private(set) var calls: [String: Int] = [:]
    private var objects: [Int: Object] = [:]
    private var crops: [Int: TrackingCrop] = [:]
    let encoding: FrameEncoding
    /// The frame the next `step` is followed by (`lookahead`), encoded while that step propagates.
    private var upcoming: CIImage?
    /// Frames stepped since the shot started: the frame index of a conditioning frame within its sweep.
    private var frameIndex = 0

    static let side = 1024
    let reseed: TrackingTuning.Reseed
    /// Encode the next frame while the current one propagates (`TrackingTuning.encodeAhead`, `FrameEncoding`). It
    /// may change between steps; the `step ahead` and `step in turn` timings are a step's wall time, by whether its
    /// frame was encoded ahead.
    public var encodeAhead: Bool
    /// The current step's frame was encoded ahead.
    var steppedAhead = false
    /// Corrections taken (`step`'s `corrections`), over the run.
    public private(set) var corrected = 0
    /// The community propagator's `rotary_weight`: all ones, made once.
    private var rotaryWeight: MLMultiArray?

    struct Memory {
        let features: MLMultiArray
        let positions: MLMultiArray
    }

    private struct Encoded {
        let memory: Memory
        let pointer: MLMultiArray
        let temporal: [[Float]]
    }

    struct Object {
        /// The seed and the corrections (`ConditioningMemory`, `BankLayout`).
        var conditioning: ConditioningMemory<(memory: Memory, pointer: MLMultiArray)>
        /// The temporal position encoding of each bank slot (7 × 64) repeated over the slot's 512 tokens.
        let temporal: [[Float]]
        /// Memory and pointer of the most recent frames.
        var recent = MemoryBank<(memory: Memory, pointer: MLMultiArray)>()
        /// The propagator's bank inputs, refilled every frame (`bank`).
        let bank = BankInputs()
    }

    public init(
        models: EdgeTAMModels, context: CIContext,
        reseed: TrackingTuning.Reseed = TrackingTuning().reseed, encodeAhead: Bool = TrackingTuning().encodeAhead
    ) {
        self.models = models
        self.context = context
        self.encoding = FrameEncoding(models: models, context: context)
        self.encodeAhead = encodeAhead
        self.reseed = reseed
    }

    public func startShot(crops: [Int: TrackingCrop]) {
        objects = [:]
        self.crops = crops
        frameIndex = 0
        upcoming = nil
    }

    /// With `encodeAhead` on, the next `step` starts encoding `next` (in that step's crops) before it propagates.
    public func lookahead(_ next: CIImage) {
        if encodeAhead { upcoming = next }
    }

    public func step(_ frame: CIImage, seeds: [Int: [UInt8]]) throws -> [Int: TrackedMask] {
        try step(frame, seeds: seeds, corrections: [:])
    }

    /// Objects sharing a crop share one encoder run; masks are mapped back into the frame, empty outside the crop.
    /// A correction of a tracked object is encoded as a conditioning frame (as its seed, from the mask's logits and
    /// an interior point) and is its mask on this frame; the frame is not propagated for it.
    public func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]]
    ) throws -> [Int: TrackedMask] {
        try step(frame, seeds: seeds, corrections: corrections, pinned: [])
    }

    /// The corrections of objects in `pinned` (the person's own, #58) take their slots as pinned entries
    /// (`ConditioningMemory`).
    public func step(
        _ frame: CIImage, seeds: [Int: [UInt8]], corrections: [Int: [UInt8]], pinned: Set<Int>
    ) throws -> [Int: TrackedMask] {
        let next = upcoming
        upcoming = nil
        guard !objects.isEmpty || !seeds.isEmpty else { return [:] }
        let began = Date()
        defer {
            frameIndex += 1
            record([(steppedAhead ? "step ahead" : "step in turn", Date().timeIntervalSince(began))])
        }
        let width = Int(frame.extent.width), height = Int(frame.extent.height)
        let full = TrackingCrop(x: 0, y: 0, width: width, height: height)
        var views: [TrackingCrop: [Int]] = [:]
        for id in Set(objects.keys).union(seeds.keys).sorted() {
            let crop = crops[id].flatMap { $0.fits(width: width, height: height) ? $0 : nil } ?? full
            views[crop, default: []].append(id)
        }
        var out: [Int: TrackedMask] = [:]
        for view in try encoded(frame, views: views, full: full, next: next) {
            let (crop, ids, features) = (view.crop, view.ids, view.features)
            for id in ids {
                guard var object = objects[id] else { continue }
                if let correction = corrections[id], seeds[id] == nil {
                    let inCrop = crop == full ? correction : crop.cut(correction, frameWidth: width)
                    let encoded = try encode(inCrop, features: features, width: crop.width, height: crop.height)
                    object.conditioning.correct(
                        (encoded.memory, encoded.pointer), frame: frameIndex, pinned: pinned.contains(id))
                    if reseed.forgetRecent { object.recent = object.recent.emptied }
                    objects[id] = object
                    corrected += 1
                    out[id] = TrackedMask(score: 10, mask: correction.map { $0 > 127 ? 255 : 0 })
                    continue
                }
                let result = try propagate(&object, features: features)
                objects[id] = object
                let mask =
                    result.score > 0
                    ? timed("resize") {
                        Self.frameMask(result.logits, width: crop.width, height: crop.height, crop: crop, frame: full)
                    } : nil
                out[id] = TrackedMask(score: result.score, mask: mask)
            }
            for id in ids {
                guard let seed = seeds[id] else { continue }
                let inCrop = crop == full ? seed : crop.cut(seed, frameWidth: width)
                objects[id] = try start(inCrop, features: features, width: crop.width, height: crop.height)
                out[id] = TrackedMask(score: 10, mask: seed.map { $0 > 127 ? 255 : 0 })
            }
        }
        return out
    }

    /// The initializer's mask for one positive click, thresholded at 0.5: one encoder and one initializer run.
    public func mask(at point: CGPoint, on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
        try mask(points: [PromptPoint(point)], on: frame, crop: crop)
    }

    /// The initializer's mask for clicks on the object and off it, thresholded at 0.5. With one positive click the
    /// initializer picks the best of three masks by predicted IoU, with more the single-mask output (SAM 2).
    public func mask(points: [PromptPoint], on frame: CIImage, crop: TrackingCrop?) throws -> [UInt8]? {
        guard !points.isEmpty else { return nil }
        let width = Int(frame.extent.width), height = Int(frame.extent.height)
        let crop = crop.flatMap { $0.fits(width: width, height: height) ? $0 : nil }
        let view = crop ?? TrackingCrop(x: 0, y: 0, width: width, height: height)
        let encoded = try encoding.features(frame, crops: [crop])
        record(encoded.spent)
        guard let features = encoded.features[crop] else { throw PrepError.model("EdgeTAM encoded no \(view)") }
        let side = Double(Self.side)
        let coords = try Self.array([1, points.count, 2])
        let labels = try MLMultiArray(shape: [1, NSNumber(value: points.count)], dataType: .int32)
        for (i, p) in points.enumerated() {
            coords[2 * i] = NSNumber(value: (Double(p.point.x) - Double(view.x)) * side / Double(view.width))
            coords[2 * i + 1] = NSNumber(value: (Double(p.point.y) - Double(view.y)) * side / Double(view.height))
            labels[i] = p.positive ? 1 : 0
        }
        let out = try timed("initializer") {
            try run(
                models.initializer,
                [
                    "initial_vision_features": try value(features, "initial_vision_features"),
                    "high_res_feature_0": try value(features, "high_res_feature_0"),
                    "high_res_feature_1": try value(features, "high_res_feature_1"),
                    "point_coords": coords, "point_labels": labels,
                ])
        }
        let inCrop = Self.frameMask(try array(out, "high_res_mask"), width: view.width, height: view.height)
        let mask = crop.map { $0.place(inCrop, frameWidth: width, frameHeight: height) } ?? inCrop
        return mask.map { $0 > 127 ? 255 : 0 }
    }

    /// Seeds an object from its mask on this frame.
    private func start(_ seed: [UInt8], features: MLFeatureProvider, width: Int, height: Int) throws -> Object {
        let encoded = try encode(seed, features: features, width: width, height: height)
        return Object(
            conditioning: ConditioningMemory(
                seed: (encoded.memory, encoded.pointer), frame: frameIndex, maxCorrections: reseed.maxCorrections),
            temporal: encoded.temporal)
    }

    /// A conditioning frame from its mask: memory from the mask's confident logits, pointer from an interior point.
    private func encode(
        _ seed: [UInt8], features: MLFeatureProvider, width: Int, height: Int
    ) throws -> Encoded {
        let prompt = try timed("seed") {
            try Self.prompt(seed, width: width, height: height)
        }
        let inputs: [String: Any] = [
            "initial_vision_features": try value(features, "initial_vision_features"),
            "high_res_feature_0": try value(features, "high_res_feature_0"),
            "high_res_feature_1": try value(features, "high_res_feature_1"),
            "point_coords": prompt.coords, "point_labels": prompt.labels,
        ]
        let first = try timed("initializer") { try run(models.initializer, inputs) }
        let memory = try timed("memory_encoder") {
            try run(
                models.memoryEncoder,
                [
                    "raw_vision_features": try value(features, "raw_vision_features"), "high_res_mask": prompt.mask,
                    "object_score": try Self.array([1, 1], fill: 10),
                ])
        }
        return Encoded(
            memory: Memory(
                features: try array(memory, "memory_features"), positions: try array(memory, "memory_positions")),
            pointer: try array(first, "object_pointer"),
            temporal: Self.tiled(Self.floats(try array(memory, "temporal_positions"))))
    }

    func timed<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            timings[key, default: 0] += Date().timeIntervalSince(start)
            calls[key, default: 0] += 1
        }
        return try body()
    }

    func record(_ spent: [(part: String, seconds: Double)]) {
        for (part, seconds) in spent {
            timings[part, default: 0] += seconds
            calls[part, default: 0] += 1
        }
    }

    func run(_ model: MLModel, _ inputs: [String: Any]) throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }

    func value(_ provider: MLFeatureProvider, _ name: String) throws -> MLFeatureValue {
        guard let value = provider.featureValue(for: name) else { throw PrepError.model("EdgeTAM has no \(name)") }
        return value
    }

    func array(_ provider: MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let array = try value(provider, name).multiArrayValue else {
            throw PrepError.model("EdgeTAM \(name) is not an array")
        }
        return array
    }
}

// One tracked frame, in an extension so the class body stays short.
extension EdgeTAMTracker {
    /// One frame of an object: assembles its bank, runs the propagator and remembers the frame.
    private func propagate(
        _ object: inout Object, features: MLFeatureProvider
    ) throws -> (score: Float, logits: MLMultiArray) {
        let bank = try timed("bank") { try Self.bank(object) }
        var inputs: [String: Any] = [
            "raw_vision_features": try value(features, "raw_vision_features"),
            "high_res_feature_0": try value(features, "high_res_feature_0"),
            "high_res_feature_1": try value(features, "high_res_feature_1"),
            "spatial_bank": bank.spatial, "spatial_positions": bank.positions, "pointer_bank": bank.pointers,
            "attention_bias": bank.bias,
        ]
        if models.takesRotaryWeight {
            if rotaryWeight == nil { rotaryWeight = try Self.array([1, 1792], fill: 1) }
            inputs["rotary_weight"] = rotaryWeight
        }
        let out = try timed("propagator") { try run(models.propagator, inputs) }
        let score = Self.floats(try array(out, "object_score"))[0]
        let memory = Memory(features: try array(out, "memory_features"), positions: try array(out, "memory_positions"))
        object.recent.append((memory, try array(out, "object_pointer")))
        return (score, try array(out, "high_res_mask"))
    }
}

// The image features of a step, in an extension so the class body stays short.
extension EdgeTAMTracker {
    struct View {
        let crop: TrackingCrop
        let ids: [Int]
        let features: MLFeatureProvider
    }

    /// Each view (crop and its objects, by first object) with its image features, and with `next` that frame's
    /// encoding started in the same crops (`FrameEncoding`).
    func encoded(
        _ frame: CIImage, views: [TrackingCrop: [Int]], full: TrackingCrop, next: CIImage?
    ) throws -> [View] {
        let crops = views.keys.map { $0 == full ? nil : $0 }
        let encoded = try encoding.features(frame, crops: crops)
        steppedAhead = encoded.ahead
        record(encoded.spent)
        if let next { encoding.encodeAhead(next, crops: crops) }
        return try views.sorted(by: { $0.value[0] < $1.value[0] }).map { crop, ids in
            guard let features = encoded.features[crop == full ? nil : crop] else {
                throw PrepError.model("EdgeTAM encoded no \(crop)")
            }
            return View(crop: crop, ids: ids, features: features)
        }
    }
}
