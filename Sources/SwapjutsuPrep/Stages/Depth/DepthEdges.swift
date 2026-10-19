import CoreImage
import Metal

/// Edge-aware depth at the target's silhouette (#15). The model sees the frame at about half the working size and
/// smooths across the person's outline, so the last few pixels inside the mask carry a mix of the person's and the
/// background's depth: painted, a dark line just inside the edge. Those pixels (the mask minus `valid`, the mask
/// eroded by `erosion`) and the dilation ring around the mask take a joint bilateral average of the person's own
/// depth nearby: weighted by distance and by colour similarity in the frame, and only over `valid` samples, so no
/// background depth enters and a strong colour edge on the body (hair, a print, a shadow) can only reweight the
/// person's own values, not add new ones. The result is a convex combination of input depths: the depth scale is
/// unchanged.
///
/// Valid depth passes through untouched, so the body's gradients and its inner depth edges cannot pick up the
/// frame's texture; outside the dilated mask it passes through too. Painted pixels with no valid sample in reach (a
/// part thinner than twice the erosion: a finger, a coat tail) take the nearest depth sampled in the mask within
/// reach, as the dilation ring did before.
///
/// Depth farther than `floor` (the far end of the shot's colour range) is not the person's either: a gap between an
/// arm and the body that the matte closed, or a thin limb the model saw as background, which would paint near-black.
/// It is neither a sample nor kept, and takes the person's depth nearby like the band; with none in reach it stays.
enum DepthEdges {
    struct Settings: Sendable {
        /// Depth closer than this to the mask edge is not trusted as a sample (pixels).
        let erosion: CGFloat
        /// Half-width of the sampling window (pixels).
        let reach: CGFloat
        /// Colour difference (in √RGB) at which a sample's weight falls to 61 %.
        let colourSigma: Float

        init(width: CGFloat, tuning: Tuning) {
            erosion = max(1, width * tuning.depthEdgeErosion)
            reach = max(2, width * tuning.depthEdgeReach)
            colourSigma = tuning.depthEdgeColourSigma
        }
    }

    /// `depth` (placed on the frame) refined around the edges of `core`, guided by `guide` (the frame); `grown` is
    /// the painted area. All share `depth`'s extent.
    static func refine(
        depth: CIImage, guide: CIImage, core: CIImage, grown: CIImage, settings: Settings,
        floor: Float = -.greatestFiniteMagnitude
    ) throws -> CIImage {
        let extent = depth.extent
        // Eroding the clamped mask keeps a person cut off by the frame border whole up to it: the border is not
        // an edge of theirs.
        let valid = core.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: settings.erosion])
            .cropped(to: extent).clampedToExtent()
        let taps = 6
        let step = settings.reach / CGFloat(taps)
        let inputs = [
            depth.clampedToExtent(), guide.clampedToExtent(), valid, grown.clampedToExtent(),
            core.clampedToExtent(),
        ]
        return try DepthEdgeKernel.apply(
            withExtent: extent, inputs: inputs,
            arguments: [
                "taps": taps, "step": Float(step), "spaceSigma": Float(settings.reach / 2),
                "colourSigma": settings.colourSigma, "floor": floor, "pad": Int((settings.reach + 2).rounded(.up)),
            ])
    }
}

/// The Metal side of `DepthEdges`, compiled from source once on first use (SwiftPM builds no `.metallib`).
final class DepthEdgeKernel: CIImageProcessorKernel {
    private struct Params {
        var taps: Int32
        var step: Float
        var spaceSigma: Float
        var colourSigma: Float
        var floor: Float
    }

    nonisolated(unsafe) private static let pipeline: Result<MTLComputePipelineState, Error> = Result {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PrepError.model("no Metal device") }
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "refineDepthEdges") else {
            throw PrepError.model("depth edge kernel missing")
        }
        return try device.makeComputePipelineState(function: function)
    }

    override class var outputFormat: CIFormat { .Rf }

    override class func formatForInput(at input: Int32) -> CIFormat {
        switch input {
        case 0: .Rf
        case 1: .RGBA8
        default: .R8
        }
    }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        let pad = CGFloat(arguments?["pad"] as? Int ?? 0)
        return outputRect.insetBy(dx: -pad, dy: -pad)
    }

    override class func process(
        with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput
    ) throws {
        let pipeline = try pipeline.get()
        guard let inputs, inputs.count == 5, let buffer = output.metalCommandBuffer,
            let target = output.metalTexture, buffer.device === pipeline.device
        else { throw PrepError.model("depth edge kernel needs a Metal context") }
        let textures = inputs.compactMap(\.metalTexture)
        guard textures.count == inputs.count else { throw PrepError.model("depth edge kernel needs Metal textures") }
        guard let encoder = buffer.makeComputeCommandEncoder() else { throw PrepError.model("no Metal encoder") }
        // Texture rows run top-down. An input's region holds at least the ROI and may be larger: the frame, a pixel
        // buffer, can come whole.
        let offsets = inputs.map {
            SIMD2(Int32(output.region.minX - $0.region.minX), Int32($0.region.maxY - output.region.maxY))
        }
        var params = Params(
            taps: Int32(arguments?["taps"] as? Int ?? 0), step: arguments?["step"] as? Float ?? 1,
            spaceSigma: arguments?["spaceSigma"] as? Float ?? 1, colourSigma: arguments?["colourSigma"] as? Float ?? 1,
            floor: arguments?["floor"] as? Float ?? -.greatestFiniteMagnitude)
        encoder.setComputePipelineState(pipeline)
        encoder.setTextures(textures + [target], range: 0..<6)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        // Per input: its texel = output texel + offset.
        encoder.setBytes(offsets, length: MemoryLayout<SIMD2<Int32>>.stride * offsets.count, index: 1)
        // Square 8 × 8 groups: the work is a thin band along the silhouette, so groups that straddle it stay few.
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Params { int taps; float step; float spaceSigma; float colourSigma; float floor; };

        kernel void refineDepthEdges(
            texture2d<float, access::read> depth [[texture(0)]],
            texture2d<float, access::read> guide [[texture(1)]],
            texture2d<float, access::read> valid [[texture(2)]],
            texture2d<float, access::read> grown [[texture(3)]],
            texture2d<float, access::read> core [[texture(4)]],
            texture2d<float, access::write> out [[texture(5)]],
            constant Params &p [[buffer(0)]],
            constant int2 *offset [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            int2 at = int2(gid);
            float d = depth.read(uint2(at + offset[0])).r;
            float keep = d >= p.floor ? valid.read(uint2(at + offset[2])).r : 0.0;
            if (keep >= 0.999 || grown.read(uint2(at + offset[3])).r <= 0.001) {
                out.write(float4(d, 0, 0, 1), gid);
                return;
            }
            int2 dLast = int2(depth.get_width() - 1, depth.get_height() - 1);
            int2 gLast = int2(guide.get_width() - 1, guide.get_height() - 1);
            int2 vLast = int2(valid.get_width() - 1, valid.get_height() - 1);
            float3 g = sqrt(max(guide.read(uint2(at + offset[1])).rgb, 0.0));
            float s = 0.5 / (p.spaceSigma * p.spaceSigma), r = 0.5 / (p.colourSigma * p.colourSigma);
            int2 cLast = int2(core.get_width() - 1, core.get_height() - 1);
            float sum = 0, weight = 0, covered = 0, total = 0, nearest = d;
            bool inMask = false;
            for (int j = -p.taps; j <= p.taps; j++) {
                for (int i = -p.taps; i <= p.taps; i++) {
                    float2 o = float2(i, j) * p.step;
                    int2 q = at + int2(round(o));
                    float dq = depth.read(uint2(clamp(q + offset[0], int2(0), dLast))).r;
                    float ws = exp(-dot(o, o) * s);
                    float v = dq >= p.floor ? valid.read(uint2(clamp(q + offset[2], int2(0), vLast))).r : 0.0;
                    total += ws;
                    covered += ws * v;
                    if (v <= 0.0) {
                        if (dq >= p.floor && core.read(uint2(clamp(q + offset[4], int2(0), cLast))).r >= 0.5) {
                            nearest = inMask ? max(nearest, dq) : dq;
                            inMask = true;
                        }
                        continue;
                    }
                    float3 dg = sqrt(max(guide.read(uint2(clamp(q + offset[1], int2(0), gLast))).rgb, 0.0)) - g;
                    // The floor keeps a ring pixel (background colour) averaging the person's depth.
                    float w = ws * v * max(exp(-dot(dg, dg) * r), 0.01);
                    sum += w * dq;
                    weight += w;
                }
            }
            float edge = weight > 0.0 ? sum / weight : d;
            float filled = mix(nearest, edge, smoothstep(0.0, 0.01, covered / total));
            out.write(float4(mix(filled, d, keep), 0, 0, 1), gid);
        }
        """
}
