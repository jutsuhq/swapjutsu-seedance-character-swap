import Foundation
import SwapjutsuDescribe
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// Views of a character: one of the person's images in `cast`, uploaded after the characters and the place and
/// bound to their person, an angle noted when it was added or drawn for one, and drawn by a generator into the clip.
@MainActor
@Suite(.serialized)
struct CharacterViewTests {
    let base = JobStoreTests()

    @Test func viewsGoAfterTheCharactersAndBeforeTheExtras() throws {
        let inputs = base.root.appending(path: "inputs")
        defer { try? FileManager.default.removeItem(at: base.root) }
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        func file(_ name: String) throws -> URL {
            let url = inputs.appending(path: name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let characters = try [file("character-1.png"), file("character-2.png")]
        let face = try file("face-character-2.jpg")
        let extra = try file("extra.png")
        let back = try file("back.png"), side = try file("side.png"), more = try file("more.png")
        let cast = [CharacterBinding(person: 3, images: [0, 4, 5]), CharacterBinding(person: 7, images: [1, 3])]
        let angles: [Int: CharacterAngle] = [3: .back, 4: .side]
        let layout = JobFiles.Layout(cast: cast, references: 6, background: false) { angles[$0] }
        let uploads = try JobFiles.uploads(
            characters + [extra, back, side, more], removeBackground: false, layout: layout)
        #expect(uploads.images == characters + [side, more, back, extra, face])
        #expect(
            uploads.views == [
                JobFiles.View(image: 3, character: 1, angle: .side, reference: 4),
                JobFiles.View(image: 4, character: 1, angle: nil, reference: 5),
                JobFiles.View(image: 5, character: 2, angle: .back, reference: 3),
            ])
        #expect(uploads.extras == [6] && uploads.closeUps == [JobFiles.CloseUp(image: 7, character: 2)])
        #expect((0..<6).map(layout.number(of:)) == [1, 2, 6, 5, 3, 4])
    }

    /// Past Seedance's limit the views go, the last first; the characters and the extras stay.
    @Test func viewsGoPastTheImageLimit() {
        let cast = [CharacterBinding(person: 1, images: [0, 1, 2])]
        let layout = JobFiles.Layout(cast: cast, references: 30, background: true)
        #expect(layout.count == JobFiles.maxImages && layout.views.map(\.reference) == [1])
        #expect(layout.background == 2 && layout.extras.first == 4)
    }

    @Test func viewsFollowTheirPerson() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let store = base.makeStore(FakeProvider(statuses: []), targets: [1, 2])
        let job = try await base.prepared(store)
        store.addReferences([try base.picture()], to: job, person: 2)
        #expect(job.spec.references.count == 2)
        #expect(store.addView(try base.picture(), angle: .back, person: 1, to: job) == nil)
        #expect(store.addView(try base.picture(), angle: .back, person: 2, to: job) == nil)
        #expect(store.addView(try base.picture(), angle: .threeQuarter, person: 2, to: job) == nil)
        #expect(job.cast.map { Array($0.views) } == [[2], [3, 4]])
        #expect(job.cast[1].views.map(job.spec.angle(of:)) == [.back, .threeQuarter])
        #expect(job.spec.references.allSatisfy { $0.path.hasPrefix(job.output.path) })
        #expect(store.addView(try base.picture(), angle: .back, person: 9, to: job) != nil)

        // Another back view replaces the one person 2 had.
        #expect(store.addView(try base.picture(), angle: .back, person: 2, to: job) == nil)
        #expect(job.spec.references.count == 5 && job.cast[1].views.map(job.spec.angle(of:)) == [.threeQuarter, .back])

        // The brief binds each view to its person, by the layout's numbers.
        #expect(job.layout.views.map(\.character) == [1, 2, 2] && job.layout.views.map(\.image) == [3, 4, 5])

        // Person 1's character goes: their view takes its place, and person 2's views keep their person.
        store.removeReference(at: 0, of: job)
        #expect(job.cast.map(\.images) == [[1], [0, 2, 3]])
    }
}
