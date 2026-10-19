import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// Small faces get 720p offered: their height at each resolution, from the share of the frame prep measured.
@MainActor
struct FacePixelsTests {
    @Test func aPortraitClipsFacesAtEachResolution() throws {
        let job = Job(
            spec: JobSpec(
                title: "faces", source: URL(filePath: "/tmp/clip.mov"), references: [], prompt: "", target: .main,
                faceGuide: false, model: .seedance25),
            output: URL(filePath: "/tmp/faces"))
        #expect(job.facePixels(at: .draft) == nil)
        let json = """
            {"source": "clip.mp4", "width": 480, "height": 854, "fps": 24, "frames": 12, "shots": [],
             "timeline": [], "identities": [], "targets": [1], "warnings": [],
             "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                         "mergeDistance": 0.33, "faceHeight": 0.055},
             "seedance": {"video": "control.mp4", "prompt": "Replace them.", "durationSeconds": 0.5},
             "timings": {}}
            """
        job.manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(job.facePixels(at: .draft) == 47)
        #expect(job.facePixels(at: .final720) == 70)
        #expect(try #require(job.facePixels(at: .draft)) < Job.smallFace)
    }
}
