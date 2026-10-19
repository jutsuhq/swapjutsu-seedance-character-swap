import Foundation
import Testing

@testable import SwapjutsuPrep

/// The prompt for settings unlike any one clip, from a description and a model's reading of the person's prompt as
/// `Describer` writes them: a terse wish with an outdoor place, a long one with a closed jacket, a Russian one with a
/// sleeveless character and the real hands. Nothing the prompt says may come from anywhere but them.
struct PromptSettingsTests {
    /// Words of no setting here: a fixed sentence that says one of them assumes a setting.
    static let foreign = [
        "robe", "lining", "lined", "platinum", "earphone", "sleeve", "pocket", "waistband", "indoors", "outdoors",
        "room", "ceiling", "lamplight", "open and moving", "its inside", "stained", "vaulted",
    ]

    func foreignWords(in text: String) -> [String] {
        Self.foreign.filter { text.range(of: "\\b\($0)", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    @Test func aTerseWishWithAnOutdoorPlace() {
        let wish = "swap her for @Image1 and put her on the beach @Image2"
        let description = SceneDescription(
            characters: [
                .init(noun: "WOMAN", pronoun: "her", appearance: "young, short black hair", wardrobe: "red swimsuit")
            ],
            location: .init(
                noun: "BEACH", description: "wide sandy beach with low dunes", floor: "dry sand",
                light: "bright midday sun"),
            motion: .init(camera: "static wide shot", beats: "running forward, jump, landing", feet: true),
            request: .init(text: wish, reading: Wish(characters: [.init()], placeNoun: "beach")))
        let text = ServicePrompt(people: 1, background: .replace, seconds: 5).text(description: description, wish: wish)
        #expect(foreignWords(in: text).isEmpty, "\(foreignWords(in: text))")
        #expect(
            text.contains(
                "continue the same BEACH — its look, materials and light — and never cut to a different place."))
        #expect(text.contains("Place WOMAN on the dry sand, lit by bright midday sun."))
        #expect(!text.contains(wish))
    }

    @Test func aLongWishWithAClosedJacket() {
        let wish = """
            Replace the man walking toward the camera in @Video1 with the man in @Image1. He wears a navy bomber jacket \
            zipped closed over a white shirt, dark jeans and white sneakers; the jacket stays zipped the whole time. \
            Keep the camera exactly as it is. Replace the background with the night street from @Image2: wet asphalt, \
            neon shop signs on both sides. He looks at the camera at the end. Cinematic, slightly desaturated.
            """
        let reading = Wish(
            characters: [
                .init(
                    performer: "the man walking toward the camera", noun: "man", pronoun: "his",
                    looks: "a navy bomber jacket zipped closed over a white shirt, dark jeans and white sneakers; the "
                        + "jacket stays zipped the whole time",
                    notes: ["He looks at the camera at the end."])
            ],
            place: "wet asphalt, neon shop signs on both sides", placeNoun: "street",
            notes: ["Cinematic, slightly desaturated."])
        let description = SceneDescription(
            characters: [
                .init(
                    noun: "MAN", pronoun: "his", wardrobe: "navy bomber jacket, white shirt, dark jeans",
                    outer: "navy bomber jacket", outerState: "zipped closed")
            ],
            location: .init(noun: "STREET", description: "night street with shop fronts"),
            request: .init(text: wish, reading: reading))
        let text = ServicePrompt(people: 1, background: .replace, seconds: 5).text(description: description, wish: wish)
        #expect(foreignWords(in: text).isEmpty, "\(foreignWords(in: text))")
        #expect(
            text.contains(
                "His navy bomber jacket zipped closed is worn over the rest of the outfit in every frame; it never"))
        #expect(text.contains("the jacket stays zipped the whole time"))
        #expect(text.contains("@Image2 — STREET, the replacement LOCATION: wet asphalt, neon shop signs"))
        #expect(text.contains("REPLACE the colored-depth man walking toward the camera"))
        #expect(
            text.contains("He looks at the camera at the end.") && text.contains("Cinematic, slightly desaturated."))
        #expect(!text.contains("Keep the camera exactly as it is"))
    }

    @Test func aRussianWishWithASleevelessCharacterAndRealHands() {
        let wish = """
            Замени девушку в @Video1 на девушку с @Image1: белая майка без рукавов, серые спортивные штаны. \
            Она держит телефон в правой руке. Фон оставь как есть.
            """
        let reading = Wish(
            characters: [
                .init(
                    performer: "the girl", noun: "girl", pronoun: "her",
                    looks: "a white sleeveless top, grey sweatpants",
                    kept: ["the phone in her right hand"], notes: ["She holds the phone in her right hand."])
            ])
        let description = SceneDescription(
            characters: [.init(noun: "GIRL", pronoun: "her", wardrobe: "white tank top, grey sweatpants")],
            motion: .init(
                camera: "handheld medium shot", beats: "steps to the side, waves", props: "a phone she holds"),
            request: .init(text: wish, reading: reading))
        let text = ServicePrompt(people: 1, seconds: 5, control: .hybridHands).text(
            description: description, wish: wish)
        // The reading's own words may say "sleeveless"; the fixed sentences never assume sleeves.
        let fixed = text.replacingOccurrences(of: "sleeveless", with: "")
        #expect(foreignWords(in: fixed).isEmpty, "\(foreignWords(in: fixed))")
        #expect(text.contains("take GIRL's skin and whatever GIRL wears on them in @Image1"))
        #expect(text.contains("She holds the phone in her right hand."))
        #expect(text.range(of: "\\p{Cyrillic}", options: .regularExpression) == nil)
        // Unread, the Russian wish goes in whole.
        let unread = ServicePrompt(people: 1, seconds: 5, control: .hybridHands).text(wish: wish)
        #expect(unread.contains(wish.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Two people, an edit with cuts, the background kept: the moves they list for both stay, and each person's own
    /// words for the looks win over the model's reading of the image.
    @Test func twoPeopleInAnEditWithTheBackgroundKept() {
        let wish = "Replace the two cyclists in @Video1 with the women in @Image1 and @Image2. They ride side by side."
        let reading = Wish(
            characters: [
                .init(
                    performer: "the cyclist on the left", noun: "woman", pronoun: "her", looks: "green eyes, red helmet"
                ),
                .init(performer: "the cyclist on the right", noun: "woman", pronoun: "her", looks: "short grey hair"),
            ],
            beats: "riding side by side, waving at the end")
        let description = SceneDescription(
            characters: [
                .init(noun: "WOMAN", pronoun: "her", appearance: "brown eyes", traits: "brown eyes, blue helmet"),
                .init(noun: "WOMAN", pronoun: "her", traits: "long black hair"),
            ],
            request: .init(text: wish, reading: reading))
        let text = ServicePrompt(people: 2, shots: 3, seconds: 7).text(description: description, wish: wish)
        #expect(foreignWords(in: text).isEmpty, "\(foreignWords(in: text))")
        #expect(text.contains("Keep the same 7s edit cut for cut, its 3 shots"))
        #expect(
            text.contains(
                "They keep the original moves, matched beat-for-beat: riding side by side, waving at the end."))
        #expect(text.contains("@Image1 — WOMAN 1, the replacement WOMAN 1: green eyes, red helmet."))
        #expect(!text.contains("brown eyes") && !text.contains("blue helmet") && !text.contains("long black hair"))
    }
}

/// Where the person's words and the model's reading of the same images or clip meet, the person's words win and
/// the model only adds what they leave out.
struct PersonsWordsWinTests {
    /// The outer layer the image's description names, in the person's words for that garment; how it moves stays
    /// the description's.
    @Test func theOuterLayerIsInThePersonsWords() {
        let wish =
            "Replace the man in @Video1 with the woman in @Image1: white shirt, long open green coat with grey lining."
        let reading = Wish(
            characters: [
                .init(noun: "woman", pronoun: "her", looks: "white shirt, long open green coat with grey lining")
            ])
        let description = SceneDescription(
            characters: [
                .init(
                    noun: "WOMAN", pronoun: "her", outer: "knee-length green coat with satin lining",
                    outerState: "worn open, its hem sways")
            ],
            request: .init(text: wish, reading: reading))
        let text = ServicePrompt(people: 1).text(description: description, wish: wish)
        #expect(
            text.contains(
                "Her long open green coat with grey lining is worn over the rest of the outfit in every frame, worn "
                    + "open, its hem sways;"))
        #expect(!text.contains("knee-length") && !text.contains("satin"))
        // A garment the person doesn't name stays the description's.
        #expect(Words.garment("navy bomber jacket", in: "white shirt, dark jeans") == nil)
    }

    /// An edit's shots may each be framed differently: no single label from the keyframes.
    @Test func anEditKeepsEveryShotsFraming() {
        let description = SceneDescription(motion: .init(camera: "static shot", shot: "full-body shot"))
        let edit = ServicePrompt(people: 1, shots: 3).text(description: description)
        #expect(edit.contains("its 3 shots, every shot's framing, the same static camera, composition"))
        #expect(!edit.contains("full-body shot"))
        let take = ServicePrompt(people: 1).text(description: description)
        #expect(take.contains("take, the same full-body shot, the same static camera, framing, composition"))
    }

    /// What the person says to keep of the setting stays, with what the description adds that they don't name.
    @Test func theKeptSettingIsBothListsInThePersonsWords() {
        let wish =
            "Swap the man in @Video1 for @Image1. Keep the bright orange backdrop, the yellow floor and the lamp."
        let reading = Wish(
            characters: [.init()], keptSetting: ["the bright orange backdrop", "the yellow floor", "the lamp"])
        let description = SceneDescription(
            motion: .init(scene: "orange wall, a lamp hanging from above, a wooden stool"),
            request: .init(text: wish, reading: reading))
        let text = ServicePrompt(people: 1).text(description: description, wish: wish)
        #expect(
            text.contains(
                "Keep the bright orange backdrop, the yellow floor, the lamp, a wooden stool exactly as filmed."))
        #expect(!text.contains("orange wall") && !text.contains("hanging from above"))
    }

    /// A wish that names both performers, with their places, and says the moves and timing again in its own words,
    /// as a model's reading leaves them in the notes; the description saw a microphone near them.
    @Test func aDuoWishNamingThePerformers() {
        let wish = "Replace the man on the left with @Image1 and the man on the right with @Image2."
        let reading = Wish(
            characters: [
                .init(performer: "the man in the grey coat on the left", noun: "woman"),
                .init(performer: "the man in the green shirt on the right", noun: "woman"),
            ],
            notes: [
                "They perform exactly the same moves as the two men", "with the same timing and in the same places",
                "Their hair and clothes move naturally.", "Photorealistic, lit like the original.",
                "No text, no other people.",
            ])
        let description = SceneDescription(
            characters: [
                .init(noun: "WOMAN", pronoun: "her", wardrobe: "red dress"),
                .init(noun: "WOMAN", pronoun: "her", wardrobe: "blue jeans"),
            ],
            motion: .init(camera: "static medium shot", beats: "talking, gesturing", props: "microphone"),
            request: .init(text: wish, reading: reading))
        let placed = ServicePrompt(people: 2, places: ["on the left", "on the right"], seconds: 5)
            .text(description: description, wish: wish)
        #expect(placed.contains("REPLACE the colored-depth man in the grey coat on the left (0–5s)"))
        #expect(!placed.contains("on the left on the left") && !placed.contains("screen presence"))
        #expect(!placed.contains("perform exactly") && !placed.contains("same places"), "\(placed)")
        #expect(!placed.contains("clothes move naturally"))
        #expect(
            placed.contains("Photorealistic, lit like the original.") && placed.contains("No text, no other people."))
        let unplaced = ServicePrompt(people: 2, seconds: 5).text(description: description, wish: wish)
        #expect(!unplaced.contains("screen presence"))
        let one = ServicePrompt(people: 1, seconds: 5).text(description: description, wish: "")
        #expect(!one.contains("keeps microphone"))
    }

    /// Each of several performers keeps their own moves and gaze in their own item; the colored depth has no eyes,
    /// so the portrait's expression and gaze are said not to carry over, and the portrait's smile is not described.
    @Test func eachPerformerKeepsTheirOwnMovesAndGaze() throws {
        let description = SceneDescription(
            characters: [
                .init(
                    noun: "MAN", pronoun: "his",
                    appearance: "in his 40s, stocky build, tan skin, grey beard, broad smile"),
                .init(noun: "GIRL", pronoun: "her", appearance: "teenage, petite, pale skin, short black hair"),
            ],
            motion: .init(
                camera: "handheld wide shot", beats: "both walk",
                performers: [
                    .init(beats: "kneels, ties a shoelace", gaze: "down at the ground"),
                    .init(beats: "jumps twice", gaze: "Up at the sky"),
                ]))
        let text = ServicePrompt(people: 2, places: ["in front", "behind"], seconds: 4).text(description: description)
        let lines = text.split(separator: "\n").map(String.init)
        let first = try #require(lines.first { $0.hasPrefix("1. REPLACE") })
        let second = try #require(lines.first { $0.hasPrefix("2. REPLACE") })
        #expect(first.contains("matched beat-for-beat to the original moves (kneels, ties a shoelace)"))
        #expect(first.contains("MAN looks down at the ground, as the performer does."))
        #expect(second.contains("to the original moves (jumps twice)") && second.contains("GIRL looks up at the sky"))
        #expect(!first.contains("jumps") && !second.contains("kneels"))
        #expect(!text.contains("broad smile") && text.contains("in his 40s, stocky build, tan skin, grey beard"))
        #expect(text.contains("The pose, expression and gaze in each image are only the portrait's"))
        let one = ServicePrompt(people: 1, seconds: 4).text(
            description: SceneDescription(
                characters: [description.characters[0]], motion: .init(beats: "a wave", gaze: "at the door")))
        #expect(
            one.contains("to the original moves (a wave)")
                && one.contains("MAN looks at the door, as the performer does."))
        #expect(one.contains("The pose, expression and gaze in @Image1 are only the portrait's"))
    }

    /// The person's words for the look come first and the image's age, build and skin after them, but never the
    /// portrait's expression: the expression is the performer's.
    @Test func thePortraitsExpressionIsNotTheCharacters() {
        let wish = "Swap him for @Image1: a yellow raincoat and short curly hair."
        let description = SceneDescription(
            characters: [
                .init(
                    noun: "WOMAN", pronoun: "her",
                    appearance: "early 30s, tall, athletic build, dark skin, short curly hair, gentle smile",
                    traits: "dark eyes, gentle smile")
            ],
            request: .init(
                text: wish,
                reading: Wish(characters: [.init(noun: "woman", looks: "a yellow raincoat and short curly hair")])))
        let text = ServicePrompt(people: 1, seconds: 4).text(description: description, wish: wish)
        #expect(
            text.contains(
                "the replacement WOMAN: a yellow raincoat and short curly hair. Early 30s, tall, athletic build, dark skin."
            ), "\(text)")
        #expect(!text.contains("smile"))
    }

    /// "keep her face, hair and outfit" names what to keep, not how the character looks; "glasses" isn't given as
    /// what the performer wears to a character who wears them.
    @Test func keptFeaturesAreNoLooksAndTheCharactersGlassesStay() {
        let wish = "Replace the girl with @Image1, keep her face, hair and outfit, she wears glasses."
        let description = SceneDescription(
            characters: [.init(noun: "WOMAN", pronoun: "her", appearance: "young woman, round tortoiseshell glasses")],
            request: .init(
                text: wish,
                reading: Wish(characters: [.init(noun: "girl", looks: "face, hair and outfit, wears glasses")])))
        let text = ServicePrompt(people: 1, seconds: 4).text(description: description, wish: wish)
        #expect(
            text.contains("the replacement GIRL: wears glasses. Young woman, round tortoiseshell glasses."), "\(text)")
        #expect(!text.contains("face, hair and outfit"))
        #expect(text.contains("nothing the performer wears, such as a hat or jewellery, carries over"), "\(text)")
        let plain = ServicePrompt(people: 1, seconds: 4).text(
            description: SceneDescription(characters: [.init(noun: "MAN")]))
        #expect(plain.contains("nothing the performer wears, such as glasses, a hat or jewellery, carries over"))
    }

    /// The person's "a cardigan over a white T-shirt" already says the description's "white crew-neck tee".
    @Test func aGarmentSaidAnotherWayIsntRepeated() {
        let theirs = "cropped cream cardigan over a white T-shirt, wide-leg trousers"
        #expect(
            Words.unsaid("white crew-neck tee, rust corduroy pants, white sneakers", by: theirs) == "white sneakers")
    }

    /// The replaced person is in the first shots only: the prompt says when, not the whole clip.
    @Test func theReplacementLastsAsLongAsTheTargetsShots() {
        let description = SceneDescription(characters: [.init(noun: "MAN")])
        let some = ServicePrompt(people: 1, seconds: 10.1, during: [.init(start: 0, end: 6.8)])
            .text(description: description)
        #expect(some.contains("(0–6.8s)") && some.contains("throughout 0–6.8s") && !some.contains("0–10.1s"), "\(some)")
        let all = ServicePrompt(people: 1, seconds: 10.1, during: [.init(start: 0, end: 10.1)])
            .text(description: description)
        #expect(all.contains("(0–10.1s)"))
    }

    @Test func aNoteSayingSomethingNewStays() {
        let prompt =
            "Render her face in every frame; hair and clothing swing and settle naturally through every movement."
        #expect(Words.repeats("Their hair and clothes move naturally", in: prompt))
        #expect(!Words.repeats("She smiles in every frame", in: prompt))
        #expect(!Words.repeats("Never show her face", in: prompt))
    }

    @Test func theCameraInThePersonsWordsIsNotSaidTwice() {
        let wish = "Keep the original camera exactly."
        let description = SceneDescription(
            characters: [.init(noun: "WOMAN", pronoun: "her")],
            request: .init(
                text: wish,
                reading: Wish(
                    characters: [.init()],
                    camera: "the same static full-body framing, the same composition and timing as @Video1")))
        let text = ServicePrompt(people: 1, seconds: 5).text(description: description, wish: wish)
        #expect(
            text.contains("Keep the same single continuous 5s take, the same static full-body framing, composition"))
        #expect(!text.contains("the same the same") && !text.contains("as @Video1,"))
    }
}
