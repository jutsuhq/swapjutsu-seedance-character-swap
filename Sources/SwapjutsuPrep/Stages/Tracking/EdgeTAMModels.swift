import CoreML
import Foundation

/// The four Core ML models of EdgeTAM's video tracker (Meta's EdgeTAM, Apache-2.0, about 69 MB), loaded together for
/// the mask tracking stage: our conversion (#19), released as jutsuhq/edgetam-coreml v1.1 and built by that repository's
/// `convert.sh` at the tag, whose initializer is fp32 (it also has a `mask_input` input) and whose propagator has no
/// `rotary_weight` input.
///
/// A folder may instead hold the community conversion (AhmadYarAI/EdgeTAM-CoreML-Video) the tracker was first
/// written for, same names: its initializer is fp16 and has no `mask_input`, and its propagator takes
/// `rotary_weight`.
///
/// By default (`defaultUnits`) the encoder, memory encoder and propagator run on `.cpuAndNeuralEngine`, the fastest for
/// the per-frame models, leaving the GPU to segmentation and depth; on `.all` the
/// propagator splits across the Neural Engine and the GPU and runs slower. Our initializer is fp32, which the Neural
/// Engine does not run: on `.cpuAndNeuralEngine` it falls back to the CPU (36 ms a call on an M4), on `.all`
/// it runs on the GPU (12.5 ms), once per shot. The community initializer stays on `.cpuAndNeuralEngine`, where its
/// numbers were measured. The tracker encodes the next frame while the current one propagates
/// (`TrackingTuning.encodeAhead`); splitting the two across the Neural Engine and the GPU (`init(folder:perModel:)`)
/// is slower either way, since the GPU half alone takes longer than both on the Neural Engine (#20). The first load
/// of a new copy waits for the Neural Engine compiles, about 6–7 s on an M4; later loads take 0.2–0.3 s. An app
/// loads them once ahead of the first prep and hands the same instance to every run, as it does the depth model.
///
/// `@unchecked Sendable`: `MLModel` is not marked `Sendable`; the models are only read once loaded, and the tracker
/// uses them from one task at a time.
public final class EdgeTAMModels: @unchecked Sendable {
    /// The package names, in the order the tracker uses them: encoder, initializer, memory encoder, propagator.
    public static let names = [
        "EdgeTAMVideoImageEncoder", "EdgeTAMVideoInitializer", "EdgeTAMVideoMemoryEncoder", "EdgeTAMVideoPropagator",
    ]

    /// Image features of a 1024 × 1024 frame, every frame.
    public let imageEncoder: MLModel
    /// The first mask and object pointer from a seed prompt.
    public let initializer: MLModel
    /// Turns a frame's mask into memory for the frames after it.
    public let memoryEncoder: MLModel
    /// The mask of a frame from its features and the memory bank, every frame.
    public let propagator: MLModel
    /// The propagator takes the community conversion's `rotary_weight` (all ones).
    let takesRotaryWeight: Bool

    /// Where each model runs unless told otherwise, in the order of `names`: the initializer on `.all`, the rest on
    /// `.cpuAndNeuralEngine`.
    public static let defaultUnits: [MLComputeUnits] = [
        .cpuAndNeuralEngine, .all, .cpuAndNeuralEngine, .cpuAndNeuralEngine,
    ]

    /// Loads `<name>.mlpackage` (or `<name>.mlmodelc`) of each model from `folder` on `defaultUnits`, compiling a
    /// package once; the community initializer (no `mask_input`) on `.cpuAndNeuralEngine` instead.
    public convenience init(folder: URL) async throws {
        try await self.init(folder: folder, perModel: nil)
    }

    /// As `init(folder:)` with each model on its own units, in the order of `names`, to compare placements; `nil`
    /// is `init(folder:)`'s choice.
    public init(folder: URL, perModel units: [MLComputeUnits]?) async throws {
        let placement = units ?? Self.defaultUnits
        guard placement.count == Self.names.count else { throw PrepError.model("EdgeTAM needs units for 4 models") }
        var models: [MLModel] = []
        for (name, unit) in zip(Self.names, placement) {
            models.append(try await CompiledModel.load(Self.url(of: name, in: folder), units: unit))
        }
        if units == nil, models[1].modelDescription.inputDescriptionsByName["mask_input"] == nil {
            // The community initializer is fp16, so `.all` would move it to the GPU and change its masks.
            models[1] = try await CompiledModel.load(
                Self.url(of: Self.names[1], in: folder), units: .cpuAndNeuralEngine)
        }
        (imageEncoder, initializer, memoryEncoder, propagator) = (models[0], models[1], models[2], models[3])
        takesRotaryWeight = propagator.modelDescription.inputDescriptionsByName["rotary_weight"] != nil
    }

    /// `<name>.mlpackage` in `folder` when it is there, else `<name>.mlmodelc`.
    private static func url(of name: String, in folder: URL) -> URL {
        let package = folder.appending(path: "\(name).mlpackage")
        return FileManager.default.fileExists(atPath: package.path(percentEncoded: false))
            ? package : folder.appending(path: "\(name).mlmodelc")
    }
}
