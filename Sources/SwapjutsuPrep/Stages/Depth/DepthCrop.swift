import Accelerate
import CoreImage

/// Depth at more detail on a person: a second inference on a crop around them, at the model's full input size, merged
/// into the full-frame map. The full-frame pass stays the reference: the crop's values are fitted onto it under the
/// person's mask (depth is relative, so the two passes differ by a scale and a shift), which keeps the per-shot
/// colour scale and the frame-to-frame consistency of the full-frame pass and adds the crop's finer relief.
enum DepthCrop {
    /// The person box padded by `depthCropPadding` of its size and `depthCropMargin` of the frame width: room for
    /// the mask dilation, the depth ring around the silhouette and the feathered crop edge.
    static func padded(_ person: CGRect, in extent: CGRect, tuning: Tuning) -> CGRect {
        let margin = extent.width * tuning.depthCropMargin
        return person.insetBy(
            dx: -(person.width * tuning.depthCropPadding + margin),
            dy: -(person.height * tuning.depthCropPadding + margin)
        )
        .intersection(extent)
    }

    /// The crop that holds `need`, kept inside the frame and on whole pixels, with an aspect between the frame's and
    /// the model input's (`modelAspect`, width / height of the landscape input, turned like the frame): the model
    /// squeezes it no more than it squeezes the whole frame (a 9:16 frame turned sideways into the 4:3 input). Nil
    /// when it would cover more than `maxShare` of the frame: the full-frame pass already sees the person at nearly
    /// the same scale, so a second inference adds little.
    static func box(
        containing need: CGRect, in extent: CGRect, modelAspect: CGFloat, maxShare: Double
    ) -> CGRect? {
        guard !need.isNull, need.width >= 1, need.height >= 1, extent.width >= 1, extent.height >= 1 else {
            return nil
        }
        let frameAspect = extent.width / extent.height
        let model = (frameAspect >= 1) == (modelAspect >= 1) ? modelAspect : 1 / modelAspect
        let aspect = min(max(need.width / need.height, min(frameAspect, model)), max(frameAspect, model))
        var size = need.size
        if size.width / size.height < aspect {
            size.width = size.height * aspect
        } else {
            size.height = size.width / aspect
        }
        // Past a frame side, the crop keeps that side and is squeezed like the full frame along it.
        size = CGSize(width: min(size.width, extent.width), height: min(size.height, extent.height))
        let x = min(max(need.midX - size.width / 2, extent.minX), extent.maxX - size.width)
        let y = min(max(need.midY - size.height / 2, extent.minY), extent.maxY - size.height)
        let box = CGRect(x: x, y: y, width: size.width, height: size.height).integral.intersection(extent)
        guard Double(box.width * box.height) <= maxShare * Double(extent.width * extent.height) else { return nil }
        return box
    }

    /// Last frame's crop when it still holds `need` and is not much larger than a fresh one (at most 1.5 × its
    /// area; any size when the fresh one would be too large), else `fresh`. A crop that stays put while the person
    /// moves inside it keeps the model's view, and so the fine relief, from shimmering frame to frame, and keeps a
    /// person who grows past `maxShare` in their crop as long as they stay inside it.
    static func stable(_ fresh: CGRect?, need: CGRect, previous: [CGRect]) -> CGRect? {
        let limit = fresh.map { $0.width * $0.height * 1.5 } ?? .infinity
        return previous.filter { $0.contains(need) && $0.width * $0.height <= limit }
            .min { $0.width * $0.height < $1.width * $1.height } ?? fresh
    }

    /// Least-squares `full ≈ scale · crop + shift` over paired samples. Nil with too few samples, a flat crop or a
    /// non-positive scale (the two passes disagree on which way is near), so that person keeps the full-frame depth.
    static func fit(crop: [Float], full: [Float]) -> DepthFit? {
        guard crop.count == full.count, crop.count >= 16 else { return nil }
        let n = Float(crop.count)
        let meanCrop = vDSP.mean(crop), meanFull = vDSP.mean(full)
        // Centred first, so a large mean does not swamp the variance in single precision.
        let c = vDSP.add(-meanCrop, crop), f = vDSP.add(-meanFull, full)
        let covariance = vDSP.dot(c, f), variance = vDSP.sumOfSquares(c)
        guard variance > 1e-8 * n else { return nil }
        let scale = covariance / variance
        guard scale > 0, scale.isFinite else { return nil }
        return DepthFit(scale: scale, shift: meanFull - scale * meanCrop)
    }

    /// `crop` (placed on the frame) mapped by `fit` and blended into `full` inside `box`, fading to the full-frame
    /// values over `feather` pixels at the crop edges inside the frame, so there is no step where the crop ends.
    /// Edges on the frame border do not fade: a person cut off by the frame keeps the crop's depth up to it.
    static func merge(full: CIImage, crop: CIImage, box: CGRect, fit: DepthFit, feather: CGFloat) -> CIImage {
        let extent = full.extent
        let aligned = crop.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: CGFloat(fit.scale), y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: CGFloat(fit.shift), y: 0, z: 0, w: 1),
            ]
        ).clampedToExtent().cropped(to: extent)
        return aligned.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: full, kCIInputMaskImageKey: weight(box, in: extent, feather)]
        ).cropped(to: extent)
    }

    /// 1 inside the crop, 0 outside it, with a soft ramp `feather` wide just inside each edge that is not on the
    /// frame border.
    static func weight(_ box: CGRect, in extent: CGRect, _ feather: CGFloat) -> CIImage {
        let far = feather * 4
        let minX = box.minX <= extent.minX ? box.minX - far : box.minX + feather
        let minY = box.minY <= extent.minY ? box.minY - far : box.minY + feather
        let maxX = box.maxX >= extent.maxX ? box.maxX + far : box.maxX - feather
        let maxY = box.maxY >= extent.maxY ? box.maxY + far : box.maxY - feather
        let core = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        return CIImage(color: .white).cropped(to: core)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather / 2])
            .cropped(to: box)
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .cropped(to: extent)
    }
}

/// Where one person's depth crop sits: its box on the frame and the transform from the stored map onto the frame.
struct DepthCropPlacement: Sendable {
    let box: CGRect
    let toFrame: CGAffineTransform
}

/// `full ≈ scale · crop + shift`, fitted under the person's mask.
struct DepthFit: Sendable, Equatable {
    let scale: Float
    let shift: Float
}

/// One person's box in one frame, handed from the people pass to the depth pass.
struct PersonBox: Sendable {
    let key: String
    let box: CGRect
}

/// The people pass publishes each frame's person boxes here as it goes; the depth pass, on its own task and a few
/// frames behind, waits for them to place its crops. Waiting blocks the waiting thread, so the crop loop runs on
/// `executor`, a thread of its own outside the Swift concurrency pool: blocked there, it never takes a pool thread
/// away from the people pass (several preps at once would otherwise use up the pool and hang). `close` releases it
/// when the people pass ends, throws or is cancelled.
final class PeopleFeed: @unchecked Sendable {
    let executor = BlockingExecutor(label: "SwapjutsuPrep.depth-crops")

    private let condition = NSCondition()
    private var frames: [Int: [PersonBox]] = [:]
    private var closed = false

    func publish(_ frame: Int, _ people: [PersonBox]) {
        condition.lock()
        frames[frame] = people
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    /// The boxes of `frame`, once published (and forgotten after); nil if the people pass ended without it.
    func people(in frame: Int) -> [PersonBox]? {
        condition.lock()
        defer { condition.unlock() }
        while frames[frame] == nil && !closed { condition.wait() }
        return frames.removeValue(forKey: frame)
    }
}

/// Runs tasks that prefer it on one serial dispatch queue instead of the Swift concurrency pool, for work that has
/// to block a thread (`PeopleFeed.people(in:)`).
final class BlockingExecutor: TaskExecutor {
    private let queue: DispatchQueue

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
