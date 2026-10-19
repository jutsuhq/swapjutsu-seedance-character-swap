import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// Create's rail and badge count a prepared clip as ready only once every replaced person has a character image, so
/// Draft All never sends a clip Seedance would refuse.
@MainActor
struct ClipGroupTests {
    @Test func aPreparedClipWithoutCharactersNeedsThemAndIsNotReady() throws {
        let job = try prepared(images: 0, targets: [1, 2])
        #expect(!job.isReady)
        #expect(ClipGroup.of(job) == .needsCharacters)
    }

    @Test func aClipMissingOneOfTwoCharactersStillNeedsThem() throws {
        let job = try prepared(images: 1, targets: [1, 2])
        #expect(job.missingCharacters == 1 && ClipGroup.of(job) == .needsCharacters)
    }

    @Test func aClipWithEveryCharacterIsReady() throws {
        let job = try prepared(images: 2, targets: [1, 2])
        #expect(job.isReady && ClipGroup.of(job) == .ready)
    }

    @Test func theRailListsReadyClipsBeforeTheOnesThatNeedCharacters() throws {
        let groups = ClipGroup.ordered([try prepared(images: 0, targets: [1]), try prepared(images: 1, targets: [1])])
        #expect(groups.map(\.group) == [.ready, .needsCharacters])
        #expect(groups.first?.jobs.count == 1)
    }

    private func prepared(images count: Int, targets: [Int]) throws -> Job {
        let images = (0..<count).map { URL(filePath: "/jobs/duo/inputs/character-\($0).png") }
        let spec = JobSpec(
            title: "Duo", source: URL(filePath: "/jobs/duo/inputs/source.mov"), references: images, prompt: "",
            target: .all, faceGuide: false, model: .seedance25)
        let job = Job(spec: spec, output: URL(filePath: "/jobs/duo"))
        job.stage = .prepared
        let json = """
            {"source": "source.mov", "width": 64, "height": 64, "fps": 2, "frames": 10, "shots": [],
             "timeline": [], "targets": \(targets), "warnings": [], "identities": [],
             "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                         "mergeDistance": 0.33},
             "seedance": {"video": "control.mp4", "prompt": "", "durationSeconds": 5}, "timings": {}}
            """
        job.manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        return job
    }
}
