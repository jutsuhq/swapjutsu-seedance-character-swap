import Foundation
import Testing

@testable import SwapjutsuPrep

/// The service prompt (`ServicePrompt`): one entity line per image, a Video edit paragraph, a REPLACE item per
/// character and one for a replaced background, the identity lock and the closing line, with every `@Image` number
/// right for one to three people, with and without the background, face close-ups and extra references.
struct PromptTests {
    private let pipeline = Pipeline(options: PrepOptions(), modelURL: URL(filePath: "/dev/null"))

    /// One person, the background replaced, the face close-up after it.
    @Test func onePersonWithTheBackgroundAndACloseUp() {
        let prompt = ServicePrompt(people: 1, background: .replace, seconds: 7, semitones: 3)
            .text(closeUps: [1: 3])
        let lines = prompt.components(separatedBy: "\n")
        #expect(lines[0] == "@Image1 — CHARACTER, the replacement CHARACTER.")
        #expect(
            lines[1]
                == "@Image3 — CHARACTER's FACE: a close-up of the same CHARACTER from @Image1; it defines their "
                + "recognizable face: the same eyes, nose, lips, face shape and skin.")
        #expect(lines[2] == "@Image2 — LOCATION, the replacement LOCATION.")
        #expect(lines[3].hasPrefix("Video edit. @Video1 is a motion guide: the person painted with colored depth is"))
        #expect(lines[3].contains("everything painted with grey depth is the setting"))
        #expect(lines[3].contains("not the shape of the clothes: clothing and hair follow the reference image"))
        #expect(lines[3].contains("Keep the same single continuous 7s take"))
        #expect(
            lines[4].hasPrefix("1. REPLACE the colored-depth performer (0–7s) with CHARACTER from @Image1 and @Image3"))
        #expect(lines[4].contains("the recognizable face from @Image3"))
        #expect(lines[5].hasPrefix("2. REPLACE everything painted with grey depth (0–7s) with LOCATION from @Image2"))
        #expect(lines[6].hasPrefix("@Video1 contains embedded vocals pitched up 3 semitones"))
        #expect(lines[7].contains("CHARACTER's face matches @Image3 in every frame"))
        #expect(lines[7].hasSuffix("Lock LOCATION only to the background replacement during 0–7s."))
        #expect(lines[8].hasPrefix("Everything else — the inherited choreography"))
        #expect(lines.count == 9)
    }

    /// The original kept: no grey, no LOCATION, every other pixel stays.
    @Test func keptBackgroundKeepsTheOriginal() {
        let prompt = ServicePrompt(people: 1, seconds: 5).text()
        #expect(prompt.contains("every other pixel is the original footage, kept exactly"))
        #expect(!prompt.contains("grey") && !prompt.contains("LOCATION"))
        #expect(prompt.contains("with CHARACTER from @Image1, matched beat-for-beat"))
        #expect(prompt.contains("the recognizable face from @Image1;"))
        #expect(prompt.contains("CHARACTER's face matches @Image1 in every frame"))
        #expect(!prompt.contains("@Image2"))
    }

    /// Two and three people by place, the close-ups after the characters (and the background), the extras last.
    @Test(arguments: [2, 3], [false, true])
    func severalPeopleWithCloseUpsAndExtras(people: Int, replace: Bool) {
        let named = people == 2 ? ["on the left", "on the right"] : ["on the left", "in the middle", "on the right"]
        let location = people + 1
        let first = people + (replace ? 2 : 1)
        let faces = Dictionary(uniqueKeysWithValues: (1...people).map { ($0, first + $0 - 1) })
        let extras = [first + people, first + people + 1]
        let prompt = ServicePrompt(people: people, places: named, background: replace ? .replace : .keep, seconds: 6)
            .text(closeUps: faces, extras: extras)
        for k in 1...people {
            #expect(prompt.contains("@Image\(k) — CHARACTER \(k), the replacement CHARACTER \(k)."))
            #expect(
                prompt.contains(
                    "@Image\(faces[k] ?? 0) — CHARACTER \(k)'s FACE: a close-up of the same CHARACTER \(k) from @Image\(k);"
                ))
            #expect(
                prompt.contains(
                    "\(k). REPLACE the colored-depth performer \(named[k - 1]) (0–6s) with CHARACTER \(k) from @Image\(k) and @Image\(faces[k] ?? 0),"
                ))
            #expect(prompt.contains("CHARACTER \(k)'s face matches @Image\(faces[k] ?? 0)"))
        }
        #expect(prompt.contains("@Image\(extras[0]) — REFERENCE 1, an extra reference"))
        #expect(prompt.contains("@Image\(extras[1]) — REFERENCE 2, an extra reference"))
        #expect(prompt.contains("the \(people) people painted with colored depth are the performers"))
        #expect(prompt.contains("each CHARACTER belongs only to its own colored-depth performer"))
        #expect(prompt.contains("@Image\(location) — LOCATION") == replace)
        #expect(
            prompt.contains(
                "\(people + 1). REPLACE everything painted with grey depth (0–6s) with LOCATION from @Image\(location)")
                == replace)
        // Every @Image named is one of the uploads, and none is named twice as an entity.
        let entities = prompt.components(separatedBy: "\n").filter { $0.hasPrefix("@Image") && $0.contains(" — ") }
        #expect(entities.count == people * 2 + (replace ? 1 : 0) + extras.count)
        #expect(Set(entities.map { $0.prefix { $0 != " " } }).count == entities.count)
    }

    /// The two-dancer draft: images follow the target order, which needn't be left to right.
    @Test func eachImageIsTiedToWhereItsPersonStands() {
        let prompt = pipeline.seedancePrompt(people: 2, hasAudio: false, across: [0.7, 0.3])
        #expect(
            prompt.contains(
                "1. REPLACE the colored-depth performer on the right (the whole clip) with CHARACTER 1 from @Image1"))
        #expect(
            prompt.contains(
                "2. REPLACE the colored-depth performer on the left (the whole clip) with CHARACTER 2 from @Image2"))
        #expect(!prompt.contains("screen presence"))
    }

    @Test func threeAndMorePeopleGetTheirPlaces() {
        #expect(Pipeline.places([0.5, 0.1, 0.9]) == ["in the middle", "on the left", "on the right"])
        #expect(
            Pipeline.places([0.1, 0.3, 0.5, 0.7]) == [
                "first from the left", "second from the left", "third from the left", "fourth from the left",
            ])
    }

    /// Side by side within a tenth of the frame, or a person without a box: left and right would be a guess.
    @Test func closeOrUnknownPlacesFallBackToScreenPresence() {
        #expect(Pipeline.places([0.45, 0.5]) == nil)
        #expect(Pipeline.places([0.2, nil]) == nil)
        let prompt = pipeline.seedancePrompt(people: 2, hasAudio: false, across: [0.45, 0.5])
        #expect(prompt.contains("REPLACE the colored-depth performer with the most screen presence"))
        #expect(prompt.contains("REPLACE the colored-depth performer with the second-most screen presence"))
    }

    /// No close-up, no extras, several shots, a length that isn't whole.
    @Test func withoutCloseUpsTheFaceComesFromTheCharacter() {
        let prompt = ServicePrompt(people: 1, shots: 3, seconds: 5.25).text()
        #expect(!prompt.contains("FACE") && !prompt.contains("REFERENCE"))
        #expect(prompt.contains("Keep the same 5.3s edit cut for cut, its 3 shots"))
        #expect(prompt.contains("(0–5.3s)"))
    }

    /// The prompt only says what prep knows; the person's wishes follow it in the app.
    /// The targets' shots, back-to-back ones joined, are when the prompt replaces them; a shot with only someone else
    /// in it is flagged.
    @Test func theTargetsShotsAreTheWindowAndAShotWithoutThemIsFlagged() {
        let shots = [(0, 156), (157, 164), (165, 216), (217, 241)].enumerated().map {
            Manifest.Shot(index: $0.offset, start: $0.element.0, end: $0.element.1)
        }
        let identities = [
            Manifest.Identity(id: 1, frames: 165, shots: [0, 1], screenShare: 0.7, thumbnail: nil, isTarget: true),
            Manifest.Identity(id: 2, frames: 52, shots: [2], screenShare: 0.3, thumbnail: nil, isTarget: false),
        ]
        let windows = Pipeline.windows(of: identities, in: shots, fps: 24, seconds: 10.1)
        #expect(windows == [.init(start: 0, end: 165.0 / 24)])
        let warnings = Pipeline.unreplaced(identities, in: shots, fps: 24)
        #expect(warnings == [
            "No one is replaced in the shot at 6.9–9 s; who is in it stays as filmed. Prepare again with them picked "
                + "too to replace them."
        ])
        let everyone = identities.map {
            Manifest.Identity(
                id: $0.id, frames: $0.frames, shots: $0.shots, screenShare: $0.screenShare, thumbnail: nil,
                isTarget: true)
        }
        #expect(Pipeline.windows(of: everyone, in: shots, fps: 24, seconds: 10.1) == [.init(start: 0, end: 217.0 / 24)])
        #expect(Pipeline.unreplaced(everyone, in: shots, fps: 24).isEmpty)
    }

    @Test func theManifestKeepsTheBrief() {
        var options = PrepOptions()
        options.background = .replace
        let brief = Pipeline(options: options, modelURL: URL(filePath: "/dev/null"))
            .servicePrompt(people: 1, hasAudio: true, shots: 1, seconds: 7)
        #expect(brief == ServicePrompt(people: 1, background: .replace, seconds: 7, semitones: 3))
    }
}

/// A description from a vision model, or the person, filling the entity, appearance and beat parts.
@Suite struct DescribedPromptTests {
    let redhead = SceneDescription(
        characters: [
            .init(
                noun: "woman", pronoun: "Her", appearance: "young freckled woman with short curly red hair",
                wardrobe: "white blouse, yellow raincoat.",
                traits: "freckles, short curly red hair, yellow raincoat", moving: "skirt, scarf and hair")
        ],
        location: .init(
            noun: "Garden", description: "walled garden with gravel paths", floor: "Fine gravel path",
            light: "soft overcast daylight"),
        motion: .init(camera: "low-angle backward tracking shot", beats: "clockwise full-body turn, final pose"),
        source: "test")

    @Test func aDescriptionFillsTheEntitiesAppearanceAndBeats() {
        let brief = ServicePrompt(people: 1, background: .replace, seconds: 7)
        let text = brief.text(closeUps: [1: 3], description: redhead)
        #expect(
            text.contains(
                "@Image1 — WOMAN, the replacement WOMAN: young freckled woman with short curly red hair. "
                    + "Wardrobe: white blouse, yellow raincoat."))
        #expect(text.contains("it defines her recognizable face"))
        #expect(text.contains("@Image2 — GARDEN, the replacement LOCATION: walled garden with gravel paths."))
        #expect(text.contains("the same low-angle backward tracking shot, framing"))
        // With the framing said, the camera is not one more shot, nor the framing twice.
        var framed = redhead
        framed.motion?.shot = "full-body shot"
        framed.request = .init(text: "x", reading: Wish(characters: [.init()], camera: "the same static full-body framing"))
        let both = brief.text(description: framed, wish: "x")
        #expect(both.contains("the same full-body shot, the same static full-body framing, composition"))
        framed.request = nil
        #expect(brief.text(description: framed).contains("the same full-body shot, the same low-angle backward tracking camera, framing"))
        framed.motion?.camera = "handheld, tracking"
        #expect(brief.text(description: framed).contains("the same full-body shot, the same handheld, tracking camera, framing"))
        #expect(text.contains("matched beat-for-beat to the original moves (clockwise full-body turn, final pose)."))
        #expect(
            text.contains("Render WOMAN's full declared appearance — freckles, short curly red hair, yellow raincoat —")
        )
        #expect(text.contains("her skirt, scarf and hair swing and settle"))
        #expect(text.contains("Place WOMAN on the fine gravel path, lit by soft overcast daylight."))
        #expect(text.contains("Identity lock: WOMAN belongs only") && text.contains("Lock GARDEN only"))
        #expect(!text.contains("CHARACTER"))
    }

    /// Two of the same noun are numbered, and the beats of the largest body never go to one of several.
    @Test func sameNounsAreNumberedAndBeatsStayWithOnePerformer() {
        var cats = SceneDescription(
            characters: [.init(noun: "cat", pronoun: "its"), .init(noun: "CAT", pronoun: "its")],
            motion: .init(beats: "sways side to side"))
        #expect(cats.names == ["CAT 1", "CAT 2"])
        let text = ServicePrompt(people: 2).text(description: cats)
        #expect(text.contains("@Image2 — CAT 2, the replacement CAT 2."))
        #expect(!text.contains("sways"))
        #expect(text.contains("Identity lock: each of CAT 1 and CAT 2 belongs only to its own"))
        cats.characters[1].noun = "Character"
        #expect(cats.names == ["CAT", nil])
    }

    @Test func noDescriptionKeepsThePromptAsItWas() {
        let brief = ServicePrompt(people: 1, background: .replace, seconds: 7)
        #expect(brief.text(description: SceneDescription()) == brief.text())
        #expect(brief.text().contains("@Image2 — LOCATION, the replacement LOCATION."))
        #expect(brief.text().contains("hair and clothing swing"))
    }
}

/// A character's other angles are bound to it as views of the same character, never taken for someone else.
@Suite struct ViewPromptTests {
    @Test func viewsAreBoundToTheirCharacter() {
        let brief = ServicePrompt(people: 1, seconds: 7)
        let description = SceneDescription(characters: [.init(noun: "WOMAN", pronoun: "her")], source: "test")
        let views = [1: [ReferenceView(image: 3, angle: .threeQuarter), ReferenceView(image: 4, angle: .back)]]
        let text = brief.text(closeUps: [1: 2], views: views, description: description)
        #expect(
            text.contains(
                "@Image4 — WOMAN from behind: the same WOMAN as @Image1, seen from behind; it defines the back of her "
                    + "hair and wardrobe in every turn away from the camera."))
        #expect(text.contains("@Image3 — WOMAN at a three-quarter angle: the same WOMAN as @Image1"))
        #expect(text.contains("with WOMAN from @Image1, @Image3, @Image4 and @Image2, matched"))
        #expect(text.contains("with the recognizable face from @Image2;"))
        #expect(text.contains("WOMAN stays the same character from every angle, matching @Image3 and @Image4"))
        // Lines in @Image order: the character, its close-up, then its views.
        let order = ["@Image1 —", "@Image2 —", "@Image3 —", "@Image4 —"].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted())
    }

    @Test func aSheetAndNoCloseUp() {
        let text = ServicePrompt(people: 2).text(views: [2: [ReferenceView(image: 3, angle: .sheet)]])
        #expect(
            text.contains("@Image3 — CHARACTER 2's CHARACTER SHEET: the same CHARACTER 2 as @Image2 from the front"))
        #expect(text.contains("with CHARACTER 2 from @Image2 and @Image3, matched"))
        #expect(text.contains("with the recognizable face from @Image2;"))
        #expect(!text.contains("CHARACTER 1 stays the same character from every angle"))
    }
}

/// Hands: every prompt asks for whole hands, and a described adaptation (a pocket the outfit doesn't have) is said
/// for the single performer.
@Suite struct HandPromptTests {
    /// Head turns, gaze, expressions and lips follow the performer in every REPLACE item, guide lines or not, and the
    /// lock asks for stable textures.
    @Test func everyCharacterFollowsTheFaceAndKeepsItsTexture() {
        for guided in [false, true] {
            let prompt = ServicePrompt(people: 2, background: .replace, seconds: 6, guided: guided).text()
            let replaces = prompt.components(separatedBy: "\n").filter { $0.contains(". REPLACE the colored-depth") }
            #expect(replaces.count == 2)
            #expect(replaces.allSatisfy { $0.contains(ServicePrompt.performance) })
            let lock = prompt.components(separatedBy: "\n").first { $0.hasPrefix("Identity lock:") } ?? ""
            #expect(lock.contains(ServicePrompt.stable))
            #expect(lock.hasSuffix("Lock LOCATION only to the background replacement during 0–6s."))
        }
    }

    /// What stays, what the performer uses and the on-screen text are named as Genjutsu names them, with
    /// no rule about hands; the contact shadow only where the feet show.
    @Test func theSceneAndPropsAreNamedFromTheDescription() {
        let motion = SceneDescription.Motion(
            camera: "static shot", beats: "talking toward the camera, head nodding", shot: "waist-up two-shot",
            scene: "The woman on the left in a yellow raincoat, a brick wall",
            props: "the umbrella he holds over his head", text: "\"Yes\"", feet: false)
        let description = SceneDescription(characters: [.init(noun: "MAN", pronoun: "his")], motion: motion)
        let text = ServicePrompt(people: 1, seconds: 5).text(description: description)
        #expect(text.contains("take, the same waist-up two-shot, the same static camera, framing"))
        let kept = "the woman on the left in a yellow raincoat, a brick wall"
        #expect(text.contains("Keep \(kept) exactly as filmed."))
        #expect(text.contains("Keep the on-screen text \"Yes\" exactly as it appears in @Video1"))
        #expect(text.contains("MAN keeps the umbrella he holds over his head, used as in @Video1."))
        #expect(text.contains("Everything else — \(kept), the inherited"))
        #expect(!text.contains("fingers"))
        #expect(!text.contains("contact shadow"))

        let replaced = ServicePrompt(people: 1, background: .replace, seconds: 5).text(description: description)
        #expect(!replaced.contains("the woman on the left") && !replaced.contains("\"Yes\""))
        #expect(ServicePrompt(people: 1).text().contains("soft contact shadow"))
    }

    @Test func anAnimalTakesTheMovesInItsOwnBody() {
        let description = SceneDescription(
            characters: [.init(noun: "CAT", pronoun: "its")], motion: .init(beats: "low wide-stance bounce"))
        #expect(
            ServicePrompt(people: 1).text(description: description).contains(
                "matched beat-for-beat to the original moves (low wide-stance bounce), adapted naturally to the cat's body."))
        let old = Data(#"{"camera": "static", "beats": "walk", "adapted": "her hand rests on her hip"}"#.utf8)
        let decoded = try? JSONDecoder().decode(SceneDescription.Motion.self, from: old)
        #expect(decoded?.scene == "" && decoded?.feet == nil)
    }
}

/// The images as the person gave them out (#60), in a prompt prep wrote before the brief: the binding by place stays,
/// the tags follow who got which image.
struct BoundPromptTests {
    private let keep = SeedancePrompt.keep
    private var byPlace: String {
        "Replace each of the 2 people painted with colored depth in @Video1: the one on the left with the character in @Image1 and the one on the right with the character in @Image2. Each takes the full identity, hair, face and outfit of their image. \(keep)"
    }

    @Test func theImagesInOrderLeaveThePromptAsPrepWroteIt() {
        #expect(SeedancePrompt.bind(byPlace, people: [[1], [2]], images: 2) == byPlace)
    }

    @Test func aDuoSwappedWithAViewAndAPropNamesEveryImage() {
        let bound = SeedancePrompt.bind(byPlace, people: [[3], [1, 2, 4]], images: 5)
        #expect(bound.contains("the one on the left with the character in @Image3"))
        #expect(bound.contains("the one on the right with the character in @Image1"))
        #expect(bound.contains("@Image2 and @Image4 are more views of the character in @Image1."))
        #expect(bound.contains("@Image5 replaces no one"))
        #expect(bound.hasSuffix(keep), "the roles come before the keep line")
    }

    @Test func screenPresenceOrderFollowsTheImages() {
        let prompt =
            "Replace the 2 people painted with colored depth in @Video1 with the characters in @Image1 and @Image2, in order of screen presence: full identity, hair, face and outfit. \(keep)"
        #expect(
            SeedancePrompt.bind(prompt, people: [[2], [1]], images: 2)
                .contains("@Image2 and @Image1, in order of screen presence"))
    }
}
