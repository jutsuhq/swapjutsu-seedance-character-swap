import CoreML
import Foundation

/// Core ML models as prep loads them: a `.mlpackage` is compiled once and the result kept next to it as
/// `.mlmodelc`, so only the first load pays for the compile (and, on the Neural Engine, Core ML's own optimization,
/// which it caches per model path).
public enum CompiledModel {
    /// `url` compiled, or `url` itself when it is already a compiled model.
    public static func compiled(_ url: URL) async throws -> URL {
        guard url.pathExtension == "mlpackage" else { return url }
        let cached = url.deletingPathExtension().appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let fresh = try await MLModel.compileModel(at: url)
        do { try FileManager.default.moveItem(at: fresh, to: cached) } catch { return fresh }
        return cached
    }

    /// The model at `url` (a package or a compiled model), loaded for `units`.
    public static func load(_ url: URL, units: MLComputeUnits) async throws -> MLModel {
        let compiled = try await compiled(url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        do { return try MLModel(contentsOf: compiled, configuration: configuration) } catch {
            throw PrepError.model("\(error)")
        }
    }
}
