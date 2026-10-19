import Accelerate
import CoreImage
import Metal

/// Depth smoothed over time along the optical flow (#17). Depth Anything is an image model, so its depth shimmers
/// frame to frame. Each target frame's final depth (full frame with the person crops merged) is blended with the
/// previous smoothed frame, warped onto it by the backward flow F:
///
///     D′_t = (D_t − b) / a,   B_t(p) = D′_t(p) + w(p) · (S_t−1(p + F(p)) − D′_t(p)),   S_t = a_f · B_t + b_f
///     w = strength · confidence · exp(−(r / τ)²),   r = D′_t − S_t−1(p + F)
///
/// - Most of the shimmer is the model's own normalisation: its relative inverse depth changes scale and shift from
///   frame to frame (fits between consecutive duo-cuts frames range 0.5–1.3×), so blending two frames as they are
///   leaves trails, and aligning the history to each new frame keeps every jump. Instead each frame is brought onto
///   the history's scale for the blend: (a, b) is the least-squares fit D_t ≈ a · S_t−1(p + F) + b over trusted
///   pixels of the whole frame (refitted without the worst fifth). The blend is then moved `follow` of the way to this
///   frame's scale (a_f = 1 + follow · (a − 1), b_f = follow · b): the scale is an exponential average of the
///   model's, so a lasting change (a person walking towards the camera) comes through within a few frames while the
///   frame-to-frame jitter does not.
/// - confidence comes with the flow (`OpticalFlow.field`): 0 out of the frame and at disocclusions, so newly
///   revealed pixels take this frame's (aligned) depth.
/// - τ is `tolerance` of the target's depth spread on this frame: depth change the flow missed (a hand coming
///   forward) gives a large r and keeps this frame's depth instead of lagging.
///
/// History resets at shot cuts, after a frame without a smoothed target (a gap, or no target), when the set of
/// targets changes, and where a frame has no flow or no fit: that frame keeps its own depth as it is.
struct DepthSmoother {
    struct Settings: Sendable {
        let strength: Float
        let tolerance: Float
        let follow: Float

        init(tuning: Tuning) {
            strength = tuning.depthSmoothing
            tolerance = tuning.depthSmoothingTolerance
            follow = tuning.depthSmoothingScaleFollow
        }
    }

    /// One frame's smoothed depth, and the motion-compensated change against the previous frame before and after
    /// smoothing (mean |D_t(p) − D_t−1(p + F)|, depth units, over trusted pixels inside the eroded target); nil
    /// after a reset.
    struct Step {
        let depth: CIImage
        /// The same as half floats at the frame size, rows top-down, for the cache.
        let half: Data
        let residual: (raw: Float, smoothed: Float)?
        let reset: Bool
    }

    private struct History {
        let frame: Int
        let shot: Int
        let targets: Set<Int>
        let smoothed: CIImage
        let smoothedSmall: [Float]
        let rawSmall: [Float]
    }

    let settings: Settings
    /// The flow fields' size, where the fit and the metric run.
    let width: Int
    let height: Int
    let context: CIContext
    private var history: History?

    init(settings: Settings, width: Int, height: Int, context: CIContext) {
        self.settings = settings
        self.width = width
        self.height = height
        self.context = context
    }

    /// Forgets the history: the next frame starts afresh (a frame without a target).
    mutating func skip() { history = nil }

    /// Smoothed depth of `frame`. `depth` is the frame's final per-frame depth, placed on the frame (origin zero);
    /// `flow` its backward field (nil: none); `mask` the targets' union.
    mutating func step(
        frame n: Int, shot: Int, targets: Set<Int>, depth: CIImage, flow: FlowField?, mask: MaskGrid
    ) throws -> Step {
        let extent = depth.extent
        let flow = flow.flatMap { $0.width == width && $0.height == height ? $0 : nil }
        let rawSmall = render(depth, width: width, height: height)
        var blended: (image: CIImage, half: Data)?
        if let previous = history, previous.frame == n - 1, previous.shot == shot, previous.targets == targets,
            let flow, settings.strength > 0,
            let (fit, tau) = alignment(current: rawSmall, previous: previous.smoothedSmall, flow: flow, mask: mask)
        {
            let image = try DepthBlendKernel.apply(
                withExtent: extent, inputs: [depth, previous.smoothed, flow.image],
                arguments: [
                    "a": fit.scale, "b": fit.shift, "followA": 1 + settings.follow * (fit.scale - 1),
                    "followB": settings.follow * fit.shift, "strength": settings.strength, "tau": tau,
                    "frame": extent, "flow": CGRect(x: 0, y: 0, width: flow.width, height: flow.height),
                ])
            blended = materialised(image)
        }
        let out = blended ?? materialised(depth)
        let smoothedSmall = blended == nil ? rawSmall : render(out.image, width: width, height: height)
        var residual: (Float, Float)?
        if blended != nil, let previous = history, let flow {
            residual = Self.residuals(
                (rawSmall, previous.rawSmall), (smoothedSmall, previous.smoothedSmall), flow: flow, mask: mask)
        }
        history = History(
            frame: n, shot: shot, targets: targets, smoothed: out.image, smoothedSmall: smoothedSmall,
            rawSmall: rawSmall)
        return Step(depth: out.image, half: out.half, residual: residual, reset: blended == nil)
    }

    /// This frame → history scale (D′ = (D − shift) / scale) and τ on the history's scale; nil when no fit holds. Sampled on
    /// every third pixel each way: a two-parameter fit needs far fewer than the ~7000 samples that leaves.
    private func alignment(
        current: [Float], previous: [Float], flow: FlowField, mask: MaskGrid
    ) -> (DepthFit, Float)? {
        var now: [Float] = [], before: [Float] = [], target: [Float] = []
        let side = mask.side
        mask.cells.withUnsafeBufferPointer { cells in
            let inside = cells.baseAddress.unsafelyUnwrapped
            Plane.with(flow.values, width: width, height: height, channels: 4) { f in
                Plane.with(previous, width: width, height: height) { p in
                    Plane.with(current, width: width, height: height) { c in
                        for y in stride(from: 1, to: height, by: 3) {
                            let row = (y * side / height) * side
                            for x in stride(from: 1, to: width, by: 3) {
                                let k = y * width + x
                                if inside[row + x * side / width] { target.append(c[k, 0]) }
                                guard f[k, 2] >= 0.5 else { continue }
                                now.append(c[k, 0])
                                before.append(p.bilinear(Float(x) + f[k, 0], Float(y) + f[k, 1], 0))
                            }
                        }
                    }
                }
            }
        }
        guard let spread = depthRange(target), var fit = DepthCrop.fit(crop: before, full: now) else { return nil }
        let errors = vDSP.absolute(vDSP.subtract(vDSP.add(fit.shift, vDSP.multiply(fit.scale, before)), now))
        var sorted = errors
        vDSP.sort(&sorted, sortOrder: .ascending)
        let limit = sorted[errors.count * 4 / 5]
        var keptBefore: [Float] = [], keptNow: [Float] = []
        for (i, e) in errors.enumerated() where e <= limit {
            keptBefore.append(before[i])
            keptNow.append(now[i])
        }
        if let refit = DepthCrop.fit(crop: keptBefore, full: keptNow) { fit = refit }
        let tau = settings.tolerance * (spread.upperBound - spread.lowerBound) / fit.scale
        guard tau > 0, tau.isFinite else { return nil }
        return (fit, tau)
    }

    /// Mean |a(p) − b(p + F(p))| of the two pairs, over trusted pixels (confidence ≥ ½) on every other row and
    /// column inside `mask`'s eroded cells; nil with none.
    static func residuals(
        _ first: ([Float], [Float]), _ second: ([Float], [Float]), flow: FlowField, mask: MaskGrid
    ) -> (Float, Float)? {
        let w = flow.width, h = flow.height, side = mask.side
        let core = eroded(mask)
        var one: Float = 0, two: Float = 0, count = 0
        core.withUnsafeBufferPointer { cells in
            let inside = cells.baseAddress.unsafelyUnwrapped
            Plane.with(flow.values, width: w, height: h, channels: 4) { f in
                Plane.with(first.0, width: w, height: h) { c1 in
                    Plane.with(first.1, width: w, height: h) { p1 in
                        Plane.with(second.0, width: w, height: h) { c2 in
                            Plane.with(second.1, width: w, height: h) { p2 in
                                for y in stride(from: 0, to: h, by: 2) {
                                    let row = (y * side / h) * side
                                    for x in stride(from: 0, to: w, by: 2) {
                                        let k = y * w + x
                                        guard inside[row + x * side / w], f[k, 2] >= 0.5 else { continue }
                                        let qx = Float(x) + f[k, 0], qy = Float(y) + f[k, 1]
                                        one += abs(c1[k, 0] - p1.bilinear(qx, qy, 0))
                                        two += abs(c2[k, 0] - p2.bilinear(qx, qy, 0))
                                        count += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return count == 0 ? nil : (one / Float(count), two / Float(count))
    }

    /// The mask without its outer cells: the metric skips the silhouette, where the depth model smears.
    private static func eroded(_ mask: MaskGrid) -> [Bool] {
        let s = mask.side
        return mask.cells.indices.map { k in
            let x = k % s, y = k / s
            return mask.cells[k] && x > 0 && y > 0 && x < s - 1 && y < s - 1 && mask.cells[k - 1]
                && mask.cells[k + 1] && mask.cells[k - s] && mask.cells[k + s]
        }
    }

    /// `image` rendered once into half floats and read back from them, so the history never grows a Core Image
    /// graph frame after frame.
    private func materialised(_ image: CIImage) -> (image: CIImage, half: Data) {
        let e = image.extent
        let w = Int(e.width), h = Int(e.height)
        var data = Data(count: w * h * 2)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: w * 2, bounds: e, format: .Rh, colorSpace: nil)
        }
        let back = CIImage(bitmapData: data, bytesPerRow: w * 2, size: e.size, format: .Rh, colorSpace: nil)
        return (back.transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)), data)
    }

    /// `image` scaled to `width` × `height`, one float per pixel, rows top-down.
    private func render(_ image: CIImage, width: Int, height: Int) -> [Float] {
        let e = image.extent
        var out = [Float](repeating: 0, count: width * height)
        let fitted = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
        context.render(
            fitted, toBitmap: &out, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .Rf, colorSpace: nil)
        return out
    }
}

/// The Metal side of `DepthSmoother`: brings this frame onto the history's scale, warps the previous smoothed depth
/// by the flow, blends it in and moves the result part of the way back to this frame's scale. Compiled from
/// source once on first use, as `DepthEdgeKernel`.
final class DepthBlendKernel: CIImageProcessorKernel {
    private struct Params {
        var a: Float
        var b: Float
        var followA: Float
        var followB: Float
        var strength: Float
        var tau: Float
        var frame: SIMD2<Float>
        var flow: SIMD2<Float>
    }

    private static let pipeline: Result<MTLComputePipelineState, Error> = Result {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PrepError.model("no Metal device") }
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "blendDepth") else {
            throw PrepError.model("depth blend kernel missing")
        }
        return try device.makeComputePipelineState(function: function)
    }

    override class var outputFormat: CIFormat { .Rf }

    override class func formatForInput(at input: Int32) -> CIFormat { input == 2 ? .RGBAf : .Rf }

    /// The current depth under the output; the history and the flow whole, since a vector may point anywhere.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        switch input {
        case 0: outputRect
        case 1: arguments?["frame"] as? CGRect ?? outputRect
        default: arguments?["flow"] as? CGRect ?? outputRect
        }
    }

    override class func process(
        with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput
    ) throws {
        let pipeline = try pipeline.get()
        guard let inputs, inputs.count == 3, let buffer = output.metalCommandBuffer,
            let target = output.metalTexture, buffer.device === pipeline.device,
            let frame = arguments?["frame"] as? CGRect, let flow = arguments?["flow"] as? CGRect
        else { throw PrepError.model("depth blend kernel needs a Metal context") }
        let textures = inputs.compactMap(\.metalTexture)
        guard textures.count == inputs.count else { throw PrepError.model("depth blend kernel needs Metal textures") }
        guard let encoder = buffer.makeComputeCommandEncoder() else { throw PrepError.model("no Metal encoder") }
        // Each region's top-left corner in top-down pixels of its own image (frame, or flow for the field).
        func origin(_ r: CGRect, in whole: CGRect) -> SIMD2<Int32> {
            SIMD2(Int32(r.minX - whole.minX), Int32(whole.maxY - r.maxY))
        }
        let origins = [
            origin(output.region, in: frame), origin(inputs[0].region, in: frame), origin(inputs[1].region, in: frame),
            origin(inputs[2].region, in: flow),
        ]
        var params = Params(
            a: arguments?["a"] as? Float ?? 1, b: arguments?["b"] as? Float ?? 0,
            followA: arguments?["followA"] as? Float ?? 1, followB: arguments?["followB"] as? Float ?? 0,
            strength: arguments?["strength"] as? Float ?? 0, tau: arguments?["tau"] as? Float ?? 1,
            frame: SIMD2(Float(frame.width), Float(frame.height)), flow: SIMD2(Float(flow.width), Float(flow.height)))
        encoder.setComputePipelineState(pipeline)
        encoder.setTextures(textures + [target], range: 0..<4)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setBytes(origins, length: MemoryLayout<SIMD2<Int32>>.stride * origins.count, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Params { float a; float b; float followA; float followB; float strength; float tau; float2 frame; float2 flow; };

        // Bilinear read at p (top-down pixels of the texture's image, pixel centres on integers), clamped.
        static float4 bilinear(texture2d<float, access::read> t, float2 p, int2 origin) {
            float2 q = p - float2(origin);
            int2 last = int2(t.get_width() - 1, t.get_height() - 1);
            float2 f = floor(q);
            int2 i = int2(f);
            float2 w = q - f;
            float4 a = t.read(uint2(clamp(i, int2(0), last)));
            float4 b = t.read(uint2(clamp(i + int2(1, 0), int2(0), last)));
            float4 c = t.read(uint2(clamp(i + int2(0, 1), int2(0), last)));
            float4 d = t.read(uint2(clamp(i + int2(1, 1), int2(0), last)));
            return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
        }

        kernel void blendDepth(
            texture2d<float, access::read> current [[texture(0)]],
            texture2d<float, access::read> previous [[texture(1)]],
            texture2d<float, access::read> flow [[texture(2)]],
            texture2d<float, access::write> out [[texture(3)]],
            constant Params &p [[buffer(0)]],
            constant int2 *origin [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            int2 at = int2(gid) + origin[0];
            // This frame on the history's scale.
            float d = (current.read(uint2(at - origin[1])).r - p.b) / p.a;
            float2 scale = p.flow / p.frame;
            float4 f = bilinear(flow, (float2(at) + 0.5) * scale - 0.5, origin[3]);
            float2 q = float2(at) + f.xy / scale;
            float confidence = f.z;
            if (q.x < 0.0 || q.y < 0.0 || q.x > p.frame.x - 1.0 || q.y > p.frame.y - 1.0) confidence = 0.0;
            float blended = d;
            if (confidence > 0.0) {
                float before = bilinear(previous, q, origin[2]).r;
                float r = (d - before) / p.tau;
                blended = mix(d, before, p.strength * min(confidence, 1.0) * exp(-r * r));
            }
            // Part of the way back to this frame's scale.
            out.write(float4(p.followA * blended + p.followB, 0, 0, 1), gid);
        }
        """
}

