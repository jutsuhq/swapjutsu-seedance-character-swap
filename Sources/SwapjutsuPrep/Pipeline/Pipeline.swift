import CoreImage
import Foundation

/// Source clip → `prepared.mp4`, `control.mp4` (Seedance `@Video1`), `mask.mp4`, `review.mp4`, identity
/// thumbnails and `manifest.json`, entirely on device.
///
/// The run, stage by stage (each stage is a protocol in `PrepStages`, swappable on its own):
///
///     decode → shot cuts → which way up each shot stands (`Upright`), before the passes below
///     decode ─┬─ people → faces → appearance → tracks → identity → targets → mask tracking ─┐
///             ├─ depth (own decoder, model loads meanwhile) ────────────────────────────────────┼─ crop fits
///             │  + person crops (boxes from the people pass)                                     │  → smoothing
///             └─ optical flow (own decoder) ─────────────────────────────────────────────────────┘  → depth scale
///     decode → control / mask / review frames → encode ─┐
///     audio: range → voice → pitch ─────────────────────┴─ mux → manifest
///
/// People and depth run at the same time: they read the clip with separate decoders, Vision runs on the GPU and
/// the depth model on the Neural Engine, and the model loads while the shots are planned. People, tracking and depth
/// see each shot turned upright; everything they hand on is in the source's frame.
public final class Pipeline {
    let options: PrepOptions
    let stages: PrepStages
    let log: (String) -> Void
    var context: CIContext { stages.context }
    var timings: [String: Double] = [:]

    /// The standard on-device stages with the depth model at `modelURL`.
    public convenience init(options: PrepOptions, modelURL: URL, log: @escaping (String) -> Void = { _ in }) {
        self.init(options: options, stages: .standard(tuning: options.tuning, depthModel: modelURL), log: log)
    }

    public init(options: PrepOptions, stages: PrepStages, log: @escaping (String) -> Void = { _ in }) {
        self.options = options
        self.stages = stages
        self.log = log
    }

    func timed<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        defer { timings[stage, default: 0] += Date().timeIntervalSince(start) }
        return try body()
    }

    /// Cancelling the task that awaits this stops every pass at the next frame and leaves no half-written video.
    @discardableResult
    public func run(video: URL, output: URL) async throws -> Manifest {
        try options.validate()
        let tuning = options.tuning
        let work = Workspace(output: output)
        try work.create()
        defer { try? FileManager.default.removeItem(at: work.root) }
        let source = try await VideoSource.open(video, tuning: tuning)
        guard source.duration >= 4 else { throw PrepError.tooShort(seconds: source.duration) }
        if source.sourceDuration > tuning.maxSeconds { log("Trimming to the first \(Int(tuning.maxSeconds)) s") }
        if source.upscaled { log("Upscaling to \(Int(source.size.width))×\(Int(source.size.height)) for Seedance") }
        log(
            "Source \(Int(source.size.width))×\(Int(source.size.height)), \(source.frameCount) frames at \(source.fps) fps"
        )

        let start = Date()
        // The depth model loads while the shots are planned; the people and depth passes need the plan.
        let loading = Task { [load = stages.depth] in try await load() }
        defer { loading.cancel() }
        let plan = try await planShots(source)
        let feed = PeopleFeed()
        let depthPass = DepthPass(
            source: source, plan: plan, cache: work.depth, feed: feed, tuning: tuning,
            load: { try await loading.value }, log: log)
        async let depthDone = depthPass.run()
        // Optical flow for the depth smoothing, on a third decoder beside segmentation.
        let flowPass = flowPass(source, work: work)
        async let flowDone = flowPass?.run()
        let analysis = try await analysePeople(source, plan: plan, work: work, feed: feed)
        let decision = try decide(analysis)
        log("Shots \(decision.cuts.count + 1), people \(decision.result.count), targets \(decision.targets.sorted())")
        // Tracking runs while the depth pass finishes.
        let targets = try await trackTargets(source, decision: decision, work: work)
        let depth = try await depthDone
        timings["model load"] = depth.modelLoad
        timings["depth"] = depth.inference
        let final = try finalDepth(
            decision, targets: targets, depth: depth, flows: try await flowDone,
            extent: CGRect(origin: .zero, size: source.size), work: work)
        timings["pass1"] = Date().timeIntervalSince(start)

        let pass2 = Date()
        let hybrid = try await hybridMasks(source, decision: decision, targets: targets, work: work)
        let (depthMeans, guide) = try await render(
            source, decision: decision, targets: targets, depth: depth, final: final, hybrid: hybrid, work: work)
        if options.faceGuide { log(guide.summary) }
        try await mux(video: video, source: source, work: work)
        timings["pass2"] = Date().timeIntervalSince(pass2)
        timings["total"] = Date().timeIntervalSince(start)

        let manifest = makeManifest(
            source: source, decision: decision, targets: targets, depthMeans: depthMeans, residual: final.residual,
            guided: guide.frames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"))
        return manifest
    }

    /// The vocals into `control.mp4`, the original into `prepared.mp4`.
    private func mux(video: URL, source: VideoSource, work: Workspace) async throws {
        let tuning = options.tuning
        let soundtrack = Soundtrack(voice: tuning.isolateVoice ? stages.voice : nil, pitch: stages.pitch)
        let vocals = work.file("control-audio.m4a")
        let start = Date()
        let hasVocals =
            tuning.pitchSemitones != 0 || tuning.isolateVoice
            ? try await soundtrack.prepare(
                video, seconds: source.duration, semitones: tuning.pitchSemitones, output: vocals, work: work.root)
            : false
        timings["audio"] = Date().timeIntervalSince(start)
        try await muxAudio(
            video: work.file("control-silent.mp4"), audioSource: hasVocals ? vocals : video,
            output: work.output.appendingPathComponent("control.mp4"))
        try await muxAudio(
            video: work.file("prepared-silent.mp4"), audioSource: video,
            output: work.output.appendingPathComponent("prepared.mp4"))
    }
}
