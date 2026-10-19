import CoreImage

/// Optical flow between every pair of consecutive working frames into the cache, on its own decoder and task, while
/// the people pass runs (#17). Which frames show a target is not known yet, so every pair gets a field; the flow
/// runs beside segmentation, off the critical path.
struct FlowPass: Sendable {
    let source: VideoSource
    let cache: FlowCache
    let tuning: Tuning
    let context: CIContext

    @concurrent func run() async throws -> FlowResult {
        let (w, h) = FlowField.size(for: source.size, side: tuning.flowSide)
        var previous: FlowFrame?
        var frames = Set<Int>()
        var seconds = 0.0, vision = 0.0
        try await source.forEachFrame { n, frame in
            let start = Date()
            let current = try FlowFrame(frame, width: w, height: h, context: context)
            if let previous {
                let visionStart = Date()
                let backward = try OpticalFlow.vectors(from: current.buffer, to: previous.buffer)
                let forward = try OpticalFlow.vectors(from: previous.buffer, to: current.buffer)
                vision += Date().timeIntervalSince(visionStart)
                let field = try OpticalFlow.field(
                    backward: backward, forward: forward,
                    luma: current.luma, previousLuma: previous.luma, size: (w, h),
                    sigma: tuning.flowLumaSigma)
                try cache.store(field, frame: n)
                frames.insert(n)
            }
            previous = current
            seconds += Date().timeIntervalSince(start)
        }
        return FlowResult(frames: frames, width: w, height: h, seconds: seconds, vision: vision)
    }
}

/// Which frames have a flow field back to the frame before, and the field size.
struct FlowResult: Sendable {
    let frames: Set<Int>
    let width: Int
    let height: Int
    /// Time spent in the pass's own work, and the part of it in Vision's optical flow.
    let seconds: Double
    let vision: Double
}
