import Foundation
import Testing

@testable import SwapjutsuPrep

/// The person's prompt folded into the service prompt by a model's reading of it (`SceneDescription.request`), and
/// whole when no model read it, or read another text.
struct WishTests {
    /// A reading of "Replace the man jogging in @Video1 with the man in @Image1: grey hoodie, black shorts. He keeps the
    /// red cap. Put him in the park from @Image2 instead of the street. Make it look like early morning."
    static let jogger = SceneDescription.Request(
        text: "Replace the man jogging in @Video1 with the man in @Image1: grey hoodie, black shorts. He keeps the red "
            + "cap. Put him in the park from @Image2 instead of the street. Make it look like early morning.",
        reading: Wish(
            characters: [
                .init(
                    performer: "the man jogging", noun: "man", pronoun: "his", looks: "grey hoodie, black shorts",
                    kept: ["the red cap"], notes: ["He keeps the red cap."])
            ],
            placeNoun: "park", replacedSetting: "the street", notes: ["Make it look like early morning."]))

    @Test func theReadingGoesToItsParts() {
        let description = SceneDescription(request: Self.jogger)
        let text = ServicePrompt(people: 1, background: .replace, seconds: 5).text(
            description: description, wish: Self.jogger.text)
        #expect(text.contains("@Image1 — MAN, the replacement MAN: grey hoodie, black shorts."))
        #expect(text.contains("@Image2 — PARK, the replacement LOCATION."))
        #expect(text.contains("REPLACE the colored-depth man jogging (0–5s) with MAN"))
        #expect(text.contains("REPLACE everything painted with grey depth — the original street —"))
        #expect(text.contains("including the red cap,"))
        #expect(text.contains("He keeps the red cap."))
        #expect(text.contains("Make it look like early morning."))
        // The person's sentences once each: not also whole.
        #expect(!text.contains("Put him in the park"))
    }

    /// A prompt edited after it was read, or never read: whole, so nothing of it is lost.
    @Test func anUnreadWishGoesInWhole() {
        let edited = "Replace the man in @Video1 with the man in @Image1. Он бежит быстрее."
        let text = ServicePrompt(people: 1).text(description: SceneDescription(request: Self.jogger), wish: edited)
        #expect(text.contains(edited))
        #expect(!text.contains("red cap"))
        let unread = ServicePrompt(people: 1).text(wish: "Make it rain.\n\nSlow motion at the end.")
        #expect(unread.contains("Make it rain.\n\nSlow motion at the end."))
    }

    @Test func noWishNoChange() {
        let brief = ServicePrompt(people: 2, seconds: 6)
        #expect(brief.text(wish: "") == brief.text())
        #expect(Wish.verbatim(" ", people: 2).isEmpty)
    }

    /// A sentence the model left out of its reading goes in as written; one it read stays where it put it.
    @Test func aSentenceTheReadingSkippedIsKept() {
        let text = "Replace the man in @Video1 with the woman in @Image1. Photorealistic, lit like the original studio."
        let reading = Wish(characters: [.init(performer: "the man", noun: "woman")]).covering(text)
        #expect(reading.notes == ["Photorealistic, lit like the original studio."])
        // A detail dropped from a sentence it read.
        let looks = "Swap him for the woman in @Image1: red coat, round glasses, a small scar on her chin."
        let read = Wish(characters: [.init(noun: "woman", looks: "red coat, round glasses")]).covering(looks)
        #expect(read.notes == ["a small scar on her chin"])
        // Another script can't be matched word for word: the reading is left as it is.
        #expect(Wish(characters: [.init()]).covering("Сделай закат.").notes.isEmpty)
    }

    /// A model that put more characters in its reading than there are: their words go to the notes.
    @Test func extraCharactersInAReadingAreKept() {
        let reading = Wish(characters: [.init(looks: "a"), .init(looks: "b", notes: ["She waves."])]).sized(1)
        #expect(reading.characters == [.init(looks: "a")])
        #expect(reading.notes == ["b", "She waves."])
    }
}

/// The outer layer stays in every frame, as the character's description names it and with how it is worn, and is
/// never guessed from the wardrobe's words; the setting continues where the place's image ends.
struct OuterLayerPromptTests {
    @Test func theDescriptionNamesTheOuterLayerAndHowItIsWorn() {
        let description = SceneDescription(
            characters: [
                .init(
                    noun: "MAN", pronoun: "his", wardrobe: "grey suit", outer: "knee-length tan trench coat",
                    outerState: "belted closed, its hem sways")
            ])
        let text = ServicePrompt(people: 1, seconds: 4).text(description: description)
        #expect(
            text.contains(
                "His knee-length tan trench coat is worn over the rest of the outfit in every frame, belted closed, its "
                    + "hem sways; it never disappears"))
        #expect(text.contains("including his knee-length tan trench coat,"))
        #expect(!text.contains(" open"))
    }

    @Test func noOuterLayerIsGuessedFromTheWardrobe() {
        let description = SceneDescription(
            characters: [.init(noun: "GIRL", pronoun: "her", wardrobe: "white tee, open denim jacket, jeans")])
        #expect(!ServicePrompt(people: 1).text(description: description).contains("worn over the rest"))
    }

    /// What the person says about the outfit goes in with the looks; the outer layer is the image's.
    @Test func thePersonsWordsJoinTheImagesOuterLayer() {
        let description = SceneDescription(
            characters: [.init(noun: "WOMAN", pronoun: "her", outer: "black coat", outerState: "worn open")],
            request: .init(text: "x", reading: Wish(characters: [.init(looks: "a red scarf over the coat")])))
        let text = ServicePrompt(people: 1).text(description: description, wish: "x")
        #expect(text.contains("Her black coat is worn over the rest of the outfit in every frame, worn open;"))
        #expect(text.contains("a red scarf over the coat"))
    }

    @Test func theSettingContinuesWhereItsImageEnds() {
        let place = SceneDescription(location: .init(noun: "BEACH"))
        let text = ServicePrompt(people: 1, background: .replace).text(description: place)
        #expect(
            text.contains(
                "parts of the setting @Image2 doesn't show, continue the same BEACH — its look, materials and light — "
                    + "and never cut to a different place."))
        #expect(!text.contains("outdoors") && !text.contains("indoors"))
        #expect(!ServicePrompt(people: 1).text().contains("doesn't show"))
    }
}

/// A reading's performer that is only a pronoun names no one in the video.
struct PerformerWordTests {
    @Test func aPronounIsNoPerformer() {
        let reading = Wish(
            characters: [.init(performer: "her", noun: "her", notes: ["she waves"])], notes: ["make it dusk"])
        let description = SceneDescription(request: .init(text: "x", reading: reading))
        let text = ServicePrompt(people: 1).text(description: description, wish: "x")
        #expect(text.contains("REPLACE the colored-depth performer (the whole clip) with CHARACTER"))
        #expect(text.contains(" She waves.") && text.contains("\nMake it dusk.\n"))
    }
}

/// The person's few words for the looks or the place come first, and the description of their image adds the rest;
/// where their words say otherwise, theirs win.
struct TheirWordsFirstTests {
    let woman = SceneDescription.Character(
        noun: "WOMAN", pronoun: "her", appearance: "young woman, long blonde hair in loose waves, round glasses",
        wardrobe: "white collared shirt, black and white striped tie, long black robe with green satin lining",
        traits: "long blonde hair, round glasses, striped tie", outer: "long black robe with green satin lining",
        outerState: "worn open")

    func prompt(looks: String, place: String = "", location: SceneDescription.Location? = nil) -> String {
        let description = SceneDescription(
            characters: [woman], location: location,
            request: .init(text: "x", reading: Wish(characters: [.init(looks: looks)], place: place)))
        return ServicePrompt(people: 1, background: location == nil ? .keep : .replace).text(
            description: description, wish: "x")
    }

    @Test func aFewWordsKeepTheImagesDescription() {
        let text = prompt(looks: "wears glasses")
        #expect(
            text.contains(
                "the replacement WOMAN: wears glasses. Young woman, long blonde hair in loose waves, round glasses. "
                    + "Wardrobe: white collared shirt, black and white striped tie, long black robe"))
        #expect(text.contains("full declared appearance — long blonde hair, round glasses, striped tie —"))
        // "The same" words only point at the image.
        #expect(prompt(looks: "same face, hair and school uniform").contains("long blonde hair in loose waves"))
    }

    @Test func theirWordsWinWhereTheySayOtherwise() {
        let text = prompt(looks: "short red hair, white collared shirt")
        #expect(text.contains("the replacement WOMAN: short red hair, white collared shirt. Young woman, round glasses."))
        #expect(text.contains("Wardrobe: black and white striped tie, long black robe with green satin lining."))
        #expect(!text.contains("blonde"))
        #expect(!prompt(looks: "silver hair, beard").contains("long blonde hair"))
    }

    /// A garment translated under another name ("cloak" for the image's "robe") is still the image's outer layer,
    /// in the person's words.
    @Test func aTranslatedGarmentIsTheOuterLayer() {
        let text = prompt(looks: "long open black cloak with green lining")
        #expect(text.contains("Her long open black cloak with green lining is worn over the rest"))
        #expect(!text.contains("satin"))
    }

    @Test func aFewWordsForThePlaceKeepItsImagesDescription() {
        let hall = SceneDescription.Location(noun: "HALL", description: "vaulted stone ceiling with a stained glass dome")
        #expect(
            prompt(looks: "", place: "stone hall with arches", location: hall).contains(
                "the replacement LOCATION: stone hall with arches. Vaulted stone ceiling with a stained glass dome."))
        #expect(
            prompt(looks: "", place: "a vaulted stone ceiling with a big stained glass dome", location: hall).contains(
                "LOCATION: a vaulted stone ceiling with a big stained glass dome.\n"))
    }
}

/// The character is named with the person's word for it, not the description's.
struct NameWordTests {
    @Test func thePersonsNounNamesTheCharacter() {
        let description = SceneDescription(
            characters: [.init(noun: "MAN", pronoun: "his")],
            request: .init(text: "x", reading: Wish(characters: [.init(noun: "old wizard")])))
        let text = ServicePrompt(people: 1).text(description: description, wish: "x")
        #expect(text.hasPrefix("@Image1 — WIZARD, the replacement WIZARD"))
        #expect(!text.contains("MAN"))
        let pronoun = SceneDescription(
            characters: [.init(noun: "MAN")], request: .init(text: "x", reading: Wish(characters: [.init(noun: "him")])))
        #expect(ServicePrompt(people: 1).text(description: pronoun, wish: "x").hasPrefix("@Image1 — MAN,"))
    }
}

/// No fragments: a note that only says again who the performer is goes, a bare thing kept gets its article, and the
/// person's light lights the new place instead of standing alone against the image's.
struct FragmentTests {
    @Test func aNoteRepeatingThePerformerGoes() {
        let reading = Wish(
            characters: [.init(performer: "the old man who dribbles the ball", notes: ["dribbles the ball", "He smiles."])])
        let text = ServicePrompt(people: 1).text(
            description: SceneDescription(request: .init(text: "x", reading: reading)), wish: "x")
        #expect(!text.contains("Dribbles the ball."))
        #expect(text.contains(" He smiles."))
    }

    @Test func aBareThingKeptGetsItsArticle() {
        let description = SceneDescription(motion: .init(scene: "illuminated advertising board, two lamps, Times Square"))
        #expect(
            ServicePrompt(people: 1).text(description: description).contains(
                "Keep the illuminated advertising board, two lamps, Times Square exactly as filmed."))
    }

    @Test func thePersonsLightLightsThePlace() {
        let place = SceneDescription.Location(noun: "ROOM", floor: "stone floor", light: "a cool blue glow")
        let reading = Wish(characters: [.init()], light: "warm lamplight")
        let description = SceneDescription(location: place, request: .init(text: "x", reading: reading))
        let replaced = ServicePrompt(people: 1, background: .replace).text(description: description, wish: "x")
        #expect(replaced.contains("Place CHARACTER on the stone floor, lit by warm lamplight."))
        #expect(!replaced.contains("blue glow") && !replaced.contains("\nWarm lamplight."))
        let said = SceneDescription(
            location: place, request: .init(text: "x", reading: Wish(characters: [.init()], light: "lit by a candle")))
        #expect(
            ServicePrompt(people: 1, background: .replace).text(description: said, wish: "x").contains(
                "lit by a candle."))
        #expect(!ServicePrompt(people: 1, background: .replace).text(description: said, wish: "x").contains("lit by lit"))
        let kept = ServicePrompt(people: 1).text(description: description, wish: "x")
        #expect(kept.contains("\nThe scene is lit by warm lamplight.\n"))
        let studio = SceneDescription(
            request: .init(text: "x", reading: Wish(characters: [.init()], light: "lit like the original studio")))
        #expect(
            ServicePrompt(people: 1).text(description: studio, wish: "x").contains(
                "\nThe scene is lit like the original studio.\n"))
    }

    @Test func aReadingSavedBeforeTheLightDecodes() throws {
        let old = Data(#"{"characters": [{"performer": "", "noun": "man", "pronoun": "", "looks": "", "moving": "", "kept": [], "notes": []}], "place": "", "placeNoun": "", "replacedSetting": "", "beats": "", "camera": "", "keptSetting": [], "notes": []}"#.utf8)
        let wish = try JSONDecoder().decode(Wish.self, from: old)
        #expect(wish.light == "" && wish.characters.first?.noun == "man")
    }
}
