import Accelerate
import CoreImage
import Metal
import Vision

/// Motion between two consecutive frames at a reduced size, with a confidence per pixel (#17). Vision's optical flow
/// gives vectors only, no confidence, so it is built here from three checks on the backward flow (current → previous):
/// the vector must land inside the previous frame, the forward flow (previous → current) must bring it back to
/// where it started (forward/backward consistency: a pixel that was hidden in the previous frame, a disocclusion,
/// fails it), and the two frames' luma must agree there (photometric residual, as a soft weight).
///
/// Layout: `values` holds (u, v, confidence, 0) per pixel, rows top-down. (u, v) is in pixels of this field, y down:
/// pixel (x, y) of the current frame shows what was at (x + u, y + v) in the previous one.
struct FlowField: @unchecked Sendable {
    let width: Int
    let height: Int
    var values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height * 4, "4 values per pixel")
        self.width = width
        self.height = height
        self.values = values
    }

    /// `values` as half floats, as stored and as `image` reads them.
    var halfData: Data {
        var halves = [Float16](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { src in
            halves.withUnsafeMutableBufferPointer { out in
                var s = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: 1,
                    width: vImagePixelCount(src.count), rowBytes: src.count * 4)
                var d = vImage_Buffer(
                    data: out.baseAddress, height: 1, width: vImagePixelCount(out.count), rowBytes: out.count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
        }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The field as a `.RGBAh` image of its size, for the blend kernel.
    var image: CIImage {
        CIImage(
            bitmapData: halfData, bytesPerRow: width * 8, size: CGSize(width: width, height: height), format: .RGBAh,
            colorSpace: nil)
    }

    /// The flow size for a frame: longest side about `side`, the frame's aspect, even sides (Vision returns an odd
    /// side one pixel short).
    static func size(for frame: CGSize, side: Int) -> (width: Int, height: Int) {
        let scale = CGFloat(side) / max(frame.width, frame.height)
        let even = { (length: CGFloat) in max(2, Int((length * scale / 2).rounded()) * 2) }
        return (even(frame.width), even(frame.height))
    }
}

enum OpticalFlow {
    /// Where each pixel of `from` is in `to`, in pixels, rows top-down and y down: (u, v) interleaved. Revision 1
    /// (classical): on real frame pairs it leaves a warped luma error 30–70 % lower than revision 2's network,
    /// which shrinks motion 2–4× here, and runs in 10–12 ms at 320–480 px against 26–43 ms (M4, 2026-10-17).
    static func vectors(from: CVPixelBuffer, to: CVPixelBuffer) throws -> [Float] {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: to, options: [:])
        request.revision = VNGenerateOpticalFlowRequestRevision1
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        try VNImageRequestHandler(cvPixelBuffer: from, options: [:]).perform([request])
        guard let flow = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else {
            throw PrepError.model("no optical flow output")
        }
        let w = CVPixelBufferGetWidth(from), h = CVPixelBufferGetHeight(from)
        guard CVPixelBufferGetWidth(flow) == w, CVPixelBufferGetHeight(flow) == h else {
            throw PrepError.model("optical flow is \(CVPixelBufferGetWidth(flow))×\(CVPixelBufferGetHeight(flow))")
        }
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { throw PrepError.model("unreadable optical flow") }
        let row = CVPixelBufferGetBytesPerRow(flow)
        var out = [Float](repeating: 0, count: w * h * 2)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                dst.baseAddress?.advanced(by: y * w * 8).copyMemory(from: base.advanced(by: y * row), byteCount: w * 8)
            }
        }
        return out
    }

    /// The backward field of a frame pair with its confidence. `backward`/`forward` are interleaved (u, v) from
    /// `vectors`; `luma`/`previousLuma` are 0–1, rows top-down; all at `size`.
    ///
    /// Confidence is 0 where the backward vector leaves the frame or the forward vector at its end does not bring
    /// it back (|F + G|² > 0.01 (|F|² + |G|²) + 0.5 px², Sundaram et al. 2010); else exp(−(Δluma / σ)²).
    static func field(
        backward: [Float], forward: [Float], luma: [Float], previousLuma: [Float], size: (width: Int, height: Int),
        sigma: Float
    ) throws -> FlowField {
        let n = size.width * size.height
        guard backward.count == n * 2, forward.count == n * 2, luma.count == n, previousLuma.count == n else {
            throw PrepError.model("flow field inputs differ in size")
        }
        return FlowField(
            width: size.width, height: size.height,
            values: try FlowConfidenceKernel.run(
                backward: backward, forward: forward, luma: luma, previousLuma: previousLuma, size: size,
                sigma: sigma))
    }
}

/// The confidence of `OpticalFlow.field` on the GPU: a plain Metal compute pass over buffers, so the flow pass costs
/// the CPU only copies while the people pass, partly on the CPU, runs beside it.
enum FlowConfidenceKernel {
    private struct Setup {
        let pipeline: MTLComputePipelineState
        let queue: MTLCommandQueue
    }

    private static let setup: Result<Setup, Error> = Result {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PrepError.model("no Metal device")
        }
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "flowConfidence") else {
            throw PrepError.model("flow confidence kernel missing")
        }
        return Setup(pipeline: try device.makeComputePipelineState(function: function), queue: queue)
    }

    static func run(
        backward: [Float], forward: [Float], luma: [Float], previousLuma: [Float], size: (width: Int, height: Int),
        sigma: Float
    ) throws -> [Float] {
        let setup = try setup.get()
        let device = setup.pipeline.device
        let n = size.width * size.height
        let inputs = [backward, forward, luma, previousLuma].map { values in
            values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress.unsafelyUnwrapped, length: $0.count) }
        }
        guard let out = device.makeBuffer(length: n * 16), inputs.allSatisfy({ $0 != nil }),
            let commands = setup.queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
        else { throw PrepError.model("no Metal buffers for the flow confidence") }
        var params = (SIMD2(Int32(size.width), Int32(size.height)), sigma)
        encoder.setComputePipelineState(setup.pipeline)
        for (i, buffer) in (inputs + [out]).enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
        encoder.setBytes(&params, length: MemoryLayout.stride(ofValue: params), index: 5)
        encoder.dispatchThreads(
            MTLSize(width: size.width, height: size.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw PrepError.model("flow confidence: \(error)") }
        return [Float](UnsafeBufferPointer(start: out.contents().assumingMemoryBound(to: Float.self), count: n * 4))
    }

    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Params { int2 size; float sigma; };

        static float sample(device const float *a, int2 size, int channels, int channel, float2 p) {
            int2 i = clamp(int2(p), int2(0), size - 2);
            float2 f = p - float2(i);
            int k = (i.y * size.x + i.x) * channels + channel, below = k + size.x * channels;
            float top = mix(a[k], a[k + channels], f.x), bottom = mix(a[below], a[below + channels], f.x);
            return mix(top, bottom, f.y);
        }

        kernel void flowConfidence(
            device const float *backward [[buffer(0)]],
            device const float *forward [[buffer(1)]],
            device const float *luma [[buffer(2)]],
            device const float *previousLuma [[buffer(3)]],
            device float4 *out [[buffer(4)]],
            constant Params &p [[buffer(5)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
            int k = int(gid.y) * p.size.x + int(gid.x);
            float2 f = float2(backward[k * 2], backward[k * 2 + 1]);
            float2 q = float2(gid) + f;
            float confidence = 0.0;
            if (q.x >= 0.0 && q.y >= 0.0 && q.x <= float(p.size.x - 1) && q.y <= float(p.size.y - 1)) {
                float2 g = float2(sample(forward, p.size, 2, 0, q), sample(forward, p.size, 2, 1, q));
                float2 d = f + g;
                if (dot(d, d) <= 0.01 * (dot(f, f) + dot(g, g)) + 0.5) {
                    float e = (luma[k] - sample(previousLuma, p.size, 1, 0, q)) / p.sigma;
                    confidence = exp(-e * e);
                }
            }
            out[k] = float4(f, confidence, 0.0);
        }
        """
}

/// An interleaved float image borrowed for the length of a loop: `channels` values per pixel, rows top-down. Reads go
/// through a raw pointer, which a Debug build does not range-check on every access (several times faster there).
struct Plane {
    let base: UnsafePointer<Float>
    let width: Int
    let height: Int
    let channels: Int

    static func with<R>(
        _ values: [Float], width: Int, height: Int, channels: Int = 1, _ body: (Plane) -> R
    ) -> R {
        precondition(values.count == width * height * channels, "\(values.count) values for \(width)×\(height)")
        return values.withUnsafeBufferPointer {
            body(Plane(base: $0.baseAddress.unsafelyUnwrapped, width: width, height: height, channels: channels))
        }
    }

    subscript(_ k: Int, _ channel: Int) -> Float { base[k * channels + channel] }

    /// Bilinear sample of `channel` at (x, y) inside the image.
    func bilinear(_ x: Float, _ y: Float, _ channel: Int) -> Float {
        let x0 = min(max(Int(x), 0), width - 2), y0 = min(max(Int(y), 0), height - 2)
        let fx = x - Float(x0), fy = y - Float(y0)
        let i = (y0 * width + x0) * channels + channel, below = i + width * channels
        let top = base[i] + (base[i + channels] - base[i]) * fx
        let bottom = base[below] + (base[below + channels] - base[below]) * fx
        return top + (bottom - top) * fy
    }
}

/// A working frame at the flow size: a BGRA buffer for Vision and its luma.
struct FlowFrame {
    let buffer: CVPixelBuffer
    let luma: [Float]

    init(_ frame: CIImage, width w: Int, height h: Int, context: CIContext) throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { throw PrepError.model("no flow frame buffer") }
        let e = frame.extent
        let scaled = frame.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        context.render(scaled, to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        // Rec. 601 luma, gamma-encoded like the frame.
        let weights = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        let gray = scaled.applyingFilter(
            "CIColorMatrix",
            parameters: ["inputRVector": weights, "inputGVector": weights, "inputBVector": weights])
        var luma = [Float](repeating: 0, count: w * h)
        context.render(
            gray, toBitmap: &luma, rowBytes: w * 4, bounds: bounds, format: .Rf,
            colorSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        self.buffer = buffer
        self.luma = luma
    }
}

/// Flow fields kept on disk between the flow pass and the smoothing, as half floats (u, v, confidence, 0).
struct FlowCache {
    let directory: URL

    func store(_ field: FlowField, frame: Int) throws { try field.halfData.write(to: url(frame)) }

    /// The field of `frame`; a missing or truncated file throws.
    func load(frame: Int, width: Int, height: Int) throws -> FlowField {
        let data: Data
        do { data = try Data(contentsOf: url(frame)) } catch {
            throw PrepError.readFailed("flow cache \(frame): \(error.localizedDescription)")
        }
        let count = width * height * 4
        guard data.count == count * 2 else { throw PrepError.readFailed("flow cache \(frame) has \(data.count) bytes") }
        var values = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { src in
            values.withUnsafeMutableBufferPointer { out in
                var s = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: 1,
                    width: vImagePixelCount(count), rowBytes: count * 2)
                var d = vImage_Buffer(
                    data: out.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
        }
        return FlowField(width: width, height: height, values: values)
    }

    private func url(_ frame: Int) -> URL { directory.appendingPathComponent("\(frame).flow") }
}
