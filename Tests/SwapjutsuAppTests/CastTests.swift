import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// Who each character image replaces (#60): saved with the job, older jobs read in order, and the prompt Seedance
/// gets names every image's role.
@MainActor
struct CastTests {
    private let images = (1...4).map { URL(filePath: "/jobs/duo/inputs/character-\($0).png") }

    /// A `job.json` as the app wrote it before the bindings, three images on a duo.
    @Test func aJobSavedBeforeTheBindingsGivesThePeopleTheImagesInOrder() throws {
        let json = """
            {"version": 2, "id": "\(UUID().uuidString)", "created": "2026-10-16T10:00:00Z", "stage": "prepared",
             "detail": "", "renders": [],
             "spec": {"title": "Duo", "source": "file:///jobs/duo/inputs/source.mov",
                      "references": ["file:///jobs/duo/inputs/character-1.png",
                                     "file:///jobs/duo/inputs/character-2.png",
                                     "file:///jobs/duo/inputs/character-3.png"],
                      "prompt": "", "target": "all", "faceGuide": true, "removeBackground": false,
                      "model": "seedance25", "targetIDs": [1, 2]}}
            """
        let record = try #require(try JobRecord.decode(Data(json.utf8)))
        #expect(record.spec.cast == nil)
        #expect(record.spec.cast(for: [1, 2]) == [.init(person: 1, images: [0]), .init(person: 2, images: [1])])
        #expect(record.spec.extras(for: [1, 2]) == [2])
    }

    @Test func aCharacterDraggedOntoAnotherPersonSwaps() {
        var spec = spec(images: 3)
        spec.assign(1, to: 1, targets: [1, 2])
        #expect(spec.cast == [.init(person: 1, images: [1]), .init(person: 2, images: [0])])
        spec.assign(2, to: 2, asView: true, targets: [1, 2])
        #expect(spec.cast(for: [1, 2])[1].views == [2])
        // A view moved up keeps the old character as a view; an extra dropped on someone sends theirs to the extras.
        spec.assign(2, to: 2, targets: [1, 2])
        #expect(spec.cast(for: [1, 2])[1].images == [2, 0])
        spec.assign(0, to: nil, targets: [1, 2])
        spec.assign(0, to: 1, targets: [1, 2])
        #expect(spec.cast(for: [1, 2]).map(\.images) == [[0], [2]] && spec.extras(for: [1, 2]) == [1])
    }

    @Test func removingAnImageRenumbersTheBindings() {
        var spec = spec(images: 3)
        spec.cast = [.init(person: 1, images: [2]), .init(person: 2, images: [0, 1])]
        spec.removeReference(at: 0)
        #expect(spec.cast == [.init(person: 1, images: [1]), .init(person: 2, images: [0])])
    }

    @Test func peopleNoLongerReplacedLeaveTheirImagesAsExtras() {
        var spec = spec(images: 2)
        spec.cast = [.init(person: 1, images: [0]), .init(person: 2, images: [1])]
        #expect(spec.cast(for: [2]) == [.init(person: 2, images: [1])] && spec.extras(for: [2]) == [0])
    }

    /// The duo prep found, the one on the left first; the person swapped the images, gave the right one a second
    /// view and added a prop. The upload puts each person's character at their own number (`JobFiles.Layout`), so
    /// the prompt keeps prep's numbers and names the view and the prop by where they go.
    @Test func theDuosPromptNamesEveryImagesRoleAndPerson() throws {
        let keep = SeedancePrompt.keep
        let prep =
            "Replace each of the 2 people painted with colored depth in @Video1: the one on the left with the character in @Image1 and the one on the right with the character in @Image2. Each takes the full identity, hair, face and outfit of their image. \(keep)"
        var spec = spec(images: 4)
        spec.prompt = "The prop in @Image4 is a red umbrella."
        spec.cast = [.init(person: 1, images: [1]), .init(person: 2, images: [0, 2])]
        let job = Job(spec: spec, output: URL(filePath: "/jobs/duo"))
        job.manifest = try manifest(targets: [1, 2], prompt: prep)
        #expect(job.layout.characters == [1, 0] && (0..<4).map(job.layout.number(of:)) == [2, 1, 3, 4])
        #expect(
            job.effectivePrompt
                == "Replace each of the 2 people painted with colored depth in @Video1: the one on the left with the "
                + "character in @Image1 and the one on the right with the character in @Image2. Each takes the full "
                + "identity, hair, face and outfit of their image. @Image3 is another view of the character in "
                + "@Image2. @Image4 replaces no one: it is a supporting reference, used only where the instructions "
                + "name it. \(keep)\n\nThe prop in @Image4 is a red umbrella.")
    }

    @Test func aPortraitForAFullBodyPersonWarns() {
        let standing = ReferenceFit.reach(face: CGRect(x: 0.45, y: 0.86, width: 0.1, height: 0.1), body: nil)
        let portrait = ReferenceFit.reach(
            face: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.35), body: CGRect(x: 0.1, y: 0, width: 0.8, height: 1))
        #expect(standing.map { $0 > 9 } == true && portrait.map { $0 < 3 } == true)
        #expect(ReferenceFit.warning(person: "Person 1", target: standing, reference: portrait)?.contains("portrait") == true)
        #expect(ReferenceFit.warning(person: "Person 1", target: standing, reference: standing) == nil)
        #expect(ReferenceFit.warning(person: "Person 1", target: portrait, reference: portrait) == nil, "a close-up")
        #expect(ReferenceFit.warning(person: "Person 1", target: standing, reference: nil) == nil, "no face, no guess")
    }

    private func spec(images count: Int) -> JobSpec {
        JobSpec(
            title: "Duo", source: URL(filePath: "/jobs/duo/inputs/source.mov"), references: Array(images.prefix(count)),
            prompt: "", target: .all, faceGuide: true, model: .seedance25)
    }

    private func manifest(targets: [Int], prompt: String) throws -> Manifest {
        let prompt = String(decoding: try JSONEncoder().encode(prompt), as: UTF8.self)
        let json = """
            {"source": "source.mov", "width": 64, "height": 64, "fps": 2, "frames": 10, "shots": [],
             "timeline": [], "targets": \(targets), "warnings": [], "identities": [],
             "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                         "mergeDistance": 0.33},
             "seedance": {"video": "control.mp4", "prompt": \(prompt), "durationSeconds": 5}, "timings": {}}
            """
        return try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
    }
}
