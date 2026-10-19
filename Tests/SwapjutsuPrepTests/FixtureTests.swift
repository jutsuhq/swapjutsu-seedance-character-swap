import Foundation
import Testing

@testable import SwapjutsuPrep

/// End-to-end checks on real clips (see Fixtures/fixtures.json next to this file). About 30 s per clip, so they run
/// only with SWAPJUTSU_FIXTURES=1 and the clips present.
struct FixtureTests {
    struct Fixture: Decodable, Sendable, CustomTestStringConvertible {
        let file: String
        let maxSeconds: Double?
        let cuts: [Int]?
        let shots: [[String]?]?
        let main: String?
        let error: String?
        var testDescription: String { file }
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let enabled = ProcessInfo.processInfo.environment["SWAPJUTSU_FIXTURES"] != nil
    /// When fixtures are on, an unreadable or malformed fixtures.json becomes one failing case instead of an empty
    /// (and silently green) run.
    static let fixtures: [Fixture] = {
        struct File: Decodable { let fixtures: [Fixture] }
        guard enabled else { return [] }
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("fixtures.json"))
            return try JSONDecoder().decode(File.self, from: data).fixtures
        } catch {
            return [
                Fixture(file: "fixtures.json: \(error)", maxSeconds: nil, cuts: nil, shots: nil, main: nil, error: nil)
            ]
        }
    }()

    @Test(.enabled(if: enabled), .serialized, arguments: fixtures)
    func fixture(_ fixture: Fixture) async throws {
        let video = Self.folder.appendingPathComponent(fixture.file)
        try #require(FileManager.default.fileExists(atPath: video.path), "missing \(fixture.file)")
        var options = PrepOptions()
        options.review = false
        if let seconds = fixture.maxSeconds { options.tuning.maxSeconds = seconds }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("swapjutsu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        // The masks are tracked as in the app when the EdgeTAM models are at hand.
        let tracking =
            ProcessInfo.processInfo.environment["SWAPJUTSU_TRACKING_MODELS"].map { URL(filePath: $0) }
            ?? Self.root.appendingPathComponent("Models/EdgeTAM")
        let stages = PrepStages.standard(
            tuning: options.tuning,
            depthModel: Self.root.appendingPathComponent("Models/DepthAnythingV2SmallF16.mlpackage"),
            trackingModels: FileManager.default.fileExists(atPath: tracking.path) ? tracking : nil)
        let pipeline = Pipeline(options: options, stages: stages) { _ in }

        if fixture.error == "noPerson" {
            await #expect(throws: PrepError.noPerson) { try await pipeline.run(video: video, output: out) }
            return
        }
        let manifest = try await pipeline.run(video: video, output: out)
        if stages.tracking != nil {
            #expect(manifest.tracking?.tracker == "EdgeTAM", "tracking: \(String(describing: manifest.tracking))")
        }

        if let cuts = fixture.cuts {
            let found = manifest.shots.dropFirst().map(\.start)
            #expect(found.count == cuts.count, "cuts \(found) vs \(cuts)")
            for (a, b) in zip(found, cuts) { #expect(abs(a - b) <= 1, "cut at \(a), expected \(b)") }
        }
        guard let labels = fixture.shots else { return }
        try #require(manifest.shots.count == labels.count, "\(manifest.shots.count) shots, expected \(labels.count)")
        let onScreen = manifest.shots.map { shot -> Set<Int> in
            var counts: [Int: Int] = [:]
            for frame in manifest.timeline[shot.start...shot.end] {
                for id in Set(frame) { counts[id, default: 0] += 1 }
            }
            let length = shot.end - shot.start + 1
            return Set(counts.filter { $0.value * 2 >= length }.keys)
        }
        // Some one-to-one naming of identities by labels must explain every checked shot.
        let names = Set(labels.compactMap { $0 }.flatMap { $0 }).sorted()
        let ids = Array(1...max(1, manifest.identities.count))
        let match = assignments(names, ids).first { naming in
            zip(labels, onScreen).allSatisfy { expected, actual in
                expected.map { Set($0.compactMap { naming[$0] }) == actual } ?? true
            }
        }
        #expect(match != nil, "shots \(onScreen.map { $0.sorted() }) do not match \(labels)")
        if let main = fixture.main, let match { #expect(match[main] == 1, "main character is not identity 1") }
    }

    /// Every injective map from names to ids.
    private func assignments(_ names: [String], _ ids: [Int]) -> [[String: Int]] {
        guard let first = names.first else { return [[:]] }
        return ids.flatMap { id in
            assignments(Array(names.dropFirst()), ids.filter { $0 != id }).map { $0.merging([first: id]) { a, _ in a } }
        }
    }
}
