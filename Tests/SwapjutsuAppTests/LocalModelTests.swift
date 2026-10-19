import CoreImage
import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// A model is loaded once, however many preps and warm-ups ask for it, so a slow Neural Engine compile is waited out
/// once and never doubles the memory. (Integrity checks and re-fetching are in `ModelFilesTests`.)
@MainActor
struct LocalModelTests {
    @Test func aPrepDuringWarmUpWaitsForTheSameLoad() async throws {
        let loader = Loader()
        let depth = DepthModel(load: loader.load)
        let url = URL(filePath: "/models/a.mlpackage")
        async let warm = depth.model(for: url)
        while await loader.calls == 0 { await Task.yield() }
        #expect(depth.isOptimizing && depth.phase == .optimizing)
        async let prep = depth.model(for: url)
        await loader.finish()
        let first = try await warm as? Stand, second = try await prep as? Stand
        #expect(first != nil && first === second)
        #expect(await loader.calls == 1)
        #expect(!depth.isOptimizing)
        _ = try await depth.model(for: url)
        #expect(await loader.calls == 1)
    }

    @Test func aFailedLoadIsReportedAndTriedAgain() async throws {
        let loader = Loader(failing: 1)
        let depth = DepthModel(load: loader.load)
        let url = URL(filePath: "/models/a.mlpackage")
        await loader.finish()
        await #expect(throws: PrepError.self) { try await depth.model(for: url) }
        #expect(depth.failure != nil && !depth.isOptimizing)
        _ = try await depth.model(for: url)
        #expect(depth.failure == nil)
        #expect(await loader.calls == 2)
    }

    @Test func anotherModelIsLoadedInsteadOfTheFirst() async throws {
        let loader = Loader()
        let depth = DepthModel(load: loader.load)
        await loader.finish()
        let first = try await depth.model(for: URL(filePath: "/models/a.mlpackage")) as? Stand
        let second = try await depth.model(for: URL(filePath: "/models/b.mlpackage")) as? Stand
        #expect(first !== second)
        #expect(await loader.calls == 2)
    }

    /// Counts loads and holds them until `finish`, like a model compiling for the Neural Engine; the first
    /// `failing` loads throw.
    private actor Loader {
        private(set) var calls = 0
        private var failing: Int
        private var isFinished = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(failing: Int = 0) { self.failing = failing }

        nonisolated var load: @Sendable (URL) async throws -> any DepthEstimating {
            { _ in try await self.next() }
        }

        func finish() {
            isFinished = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        private func next() async throws -> any DepthEstimating {
            calls += 1
            if !isFinished { await withCheckedContinuation { waiting.append($0) } }
            if failing > 0 {
                failing -= 1
                throw PrepError.model("stand-in failure")
            }
            return Stand()
        }
    }

    private final class Stand: DepthEstimating {
        func depth(of frame: CIImage) throws -> DepthMap { throw PrepError.model("stand-in") }
    }
}
