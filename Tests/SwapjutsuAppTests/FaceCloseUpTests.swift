import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// Face close-ups in the upload: after every other image, so the layout's numbers hold, each bound to its character in the prompt by the right `@Image` numbers. The close-ups are placed beside the characters as
/// `face-<name>.jpg`, as `JobFiles.faceCloseUp(of:)` leaves them, so no face detection runs.
@MainActor
struct FaceCloseUpTests {
    let inputs = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-faces-\(UUID().uuidString)/inputs")

    @Test(arguments: [1, 2], [false, true])
    func closeUpsComeAfterEveryOtherImage(people: Int, background: Bool) throws {
        defer { try? FileManager.default.removeItem(at: inputs.deletingLastPathComponent()) }
        for extras in [0, 2] {
            let characters = try (1...people).map { try file("character-\($0).png") }
            let faces = try (1...people).map { try file("face-character-\($0).jpg") }
            let more = try (0..<extras).map { try file("extra-\($0).png") }
            let place = background ? try file("background.jpg") : nil

            let uploads = try JobFiles.uploads(
                characters + more, removeBackground: false, background: place,
                layout: layout(people: people, references: people + extras, background: background))
            #expect(uploads.images == characters + (place.map { [$0] } ?? []) + more + faces)
            let first = people + (background ? 1 : 0) + extras + 1
            #expect(uploads.closeUps == (1...people).map { JobFiles.CloseUp(image: first + $0 - 1, character: $0) })
            #expect(uploads.extras == (0..<extras).map { people + (background ? 1 : 0) + 1 + $0 })

            // The brief names every upload as an entity, in the numbers the upload gives them.
            let prompt = try job(people: people, background: background, brief: true)
                .effectivePrompt(with: "Make it rain.", uploads: uploads)
            for k in 1...people {
                #expect(prompt.contains("@Image\(first + k - 1) — CHARACTER\(people > 1 ? " \(k)" : "")'s FACE"))
            }
            #expect(prompt.contains("@Image\(people + 1) — LOCATION") == background)
            for image in uploads.extras { #expect(prompt.contains("@Image\(image) — REFERENCE")) }
            // The wish is folded in, before the identity lock, not appended after the closing line.
            #expect(prompt.contains("\nMake it rain.\nIdentity lock:"))
            #expect(prompt.hasSuffix("stays exactly the same."))

            // A manifest from before the brief: its prompt with the extras named, then one sentence per close-up.
            let old = try job(people: people).effectivePrompt(with: "Make it rain.", uploads: uploads)
            let bindings = (1...people).map {
                "@Image\(first + $0 - 1) is a close-up of the face of the character in @Image\($0); match that face exactly."
            }
            let service = SeedancePrompt.bind(
                "Replace them.", people: (1...people).map { [$0] }, images: uploads.layout.count)
            #expect(old == ([service] + bindings).joined(separator: " ") + "\n\nMake it rain.")
        }
    }

    /// Only the second character's face is small: its close-up is @Image3, right after the characters.
    @Test func aCharacterWithoutACloseUpTakesNoNumber() throws {
        defer { try? FileManager.default.removeItem(at: inputs.deletingLastPathComponent()) }
        let characters = try [file("character-1.png"), file("character-2.png")]
        let face = try file("face-character-2.jpg")
        let uploads = try JobFiles.uploads(
            characters, removeBackground: false, layout: layout(people: 2, references: 2, background: false))
        #expect(uploads.images == characters + [face])
        #expect(uploads.closeUps == [JobFiles.CloseUp(image: 3, character: 2)])
    }

    /// Without close-ups the prompt is the service prompt and the wishes, as before.
    @Test func noCloseUpsNoBindings() throws {
        #expect(try job(people: 1).effectivePrompt(with: "") == "Replace them.")
    }

    /// Seedance's 30 images: a close-up that would be the 31st is left out, never a reference the person chose.
    @Test func closeUpsGoFirstPastTheImageLimit() throws {
        defer { try? FileManager.default.removeItem(at: inputs.deletingLastPathComponent()) }
        let characters = try [file("character-1.png"), file("character-2.png")]
        _ = try [file("face-character-1.jpg"), file("face-character-2.jpg")]
        let more = try (0..<26).map { try file("extra-\($0).png") }
        let uploads = try JobFiles.uploads(
            characters + more, removeBackground: false, background: try file("background.jpg"),
            layout: layout(people: 2, references: 28, background: true))
        #expect(uploads.images.count == JobFiles.maxImages)
        #expect(uploads.closeUps == [JobFiles.CloseUp(image: 30, character: 1)])
        #expect(Array(uploads.images[3..<29]) == more)
    }

    /// A close-up older than its character is made again from the character, here one without a face: gone.
    @Test func aStaleCloseUpIsNotSent() throws {
        defer { try? FileManager.default.removeItem(at: inputs.deletingLastPathComponent()) }
        let face = try file("face-character-1.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: face.path)
        let character = try file("character-1.png", data: Data(base64Encoded: JobStoreTests.onePixelPNG))
        #expect(JobFiles.faceCloseUp(of: character) == nil)
        #expect(!FileManager.default.fileExists(atPath: face.path))
    }

    // MARK: Helpers

    /// Person k takes `references[k - 1]`; the rest are extras.
    private func layout(people: Int, references: Int, background: Bool) -> JobFiles.Layout {
        JobFiles.Layout(
            cast: (1...people).map { CharacterBinding(person: $0, images: [$0 - 1]) }, references: references,
            background: background)
    }

    private func file(_ name: String, data: Data? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let url = inputs.appending(path: name)
        try (data ?? Data(name.utf8)).write(to: url)
        return url
    }

    private func job(people: Int, background: Bool = false, brief: Bool = false) throws -> Job {
        let job = Job(
            spec: JobSpec(
                title: "faces", source: inputs.appending(path: "source.mov"), references: [], prompt: "",
                target: .all, faceGuide: true, model: .seedance25),
            output: inputs.deletingLastPathComponent())
        let mode = background ? "replace" : "keep"
        let brief =
            brief ? #", "brief": {"people": \#(people), "background": "\#(mode)", "shots": 1, "guided": false}"# : ""
        let json = """
            {"source": "clip.mp4", "width": 64, "height": 64, "fps": 24, "frames": 12, "shots": [],
             "timeline": [], "identities": [], "targets": \(Array(1...people)), "warnings": [],
             "quality": {"targetPresence": 1, "maskStability": 1, "faceCoverage": 1, "depthFlicker": 0,
                         "mergeDistance": 0.33},
             "seedance": {"video": "control.mp4", "prompt": "Replace them.", "durationSeconds": 0.5\(brief)},
             "timings": {}}
            """
        job.manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        return job
    }
}
