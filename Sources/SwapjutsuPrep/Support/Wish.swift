import Foundation

/// The person's own prompt, folded into the service prompt's parts instead of appended after it: Genjutsu rewrites
/// the person's prompt into one prompt, and Seedance given ours and theirs one after the other gets two
/// overlapping instructions. A language model splits it into these parts (`DescriptionPrompts.wish`), in English,
/// in any wording or language the person wrote it; what only repeats what the service prompt says (keep the camera,
/// the timing, the moves, the look as in the image) it leaves out. Without a model's reading the wish goes in whole
/// (`verbatim`): nothing of it is dropped or reworded.
public struct Wish: Codable, Sendable, Equatable {
    public struct Character: Codable, Sendable, Equatable {
        /// Who the person says is replaced in `@Video1`: "the man dancing on the left".
        public var performer = ""
        /// What they call the character: "man".
        public var noun = ""
        /// her, his, its or their, when they say.
        public var pronoun = ""
        /// What they say the character looks like and wears. The outer layer and how it is worn come from the
        /// character's image (`SceneDescription.Character.outer`), which shows it.
        public var looks = ""
        /// What they say swings or flows as the character moves.
        public var moving = ""
        /// What they say the character keeps from the footage: "the silver necklace". The identity lock names it with
        /// the wardrobe, or Seedance takes its colour from the colored depth.
        public var kept: [String] = []
        /// Their other sentences about the character, in order.
        public var notes: [String] = []

        public init(
            performer: String = "", noun: String = "", pronoun: String = "", looks: String = "", moving: String = "",
            kept: [String] = [], notes: [String] = []
        ) {
            (self.performer, self.noun, self.pronoun, self.looks) = (performer, noun, pronoun, looks)
            (self.moving, self.kept, self.notes) = (moving, kept, notes)
        }
    }

    /// One per character image, `@Image1…`.
    public var characters: [Character]
    /// What they say the new place looks like.
    public var place = ""
    /// "garden" for "the garden in @Image2".
    public var placeNoun = ""
    /// What they say the new place replaces: "the parking lot and the cars".
    public var replacedSetting = ""
    /// The moves they list.
    public var beats = ""
    /// The camera they describe.
    public var camera = ""
    /// The light they ask for: "warm lamplight". With a new place it lights the place in their words, not the
    /// image's.
    public var light = ""
    /// The things of the video's setting they say stay as filmed: "the yellow floor", with the background kept.
    public var keptSetting: [String] = []
    /// Everything else they ask for, in order.
    public var notes: [String] = []

    public init(
        characters: [Character], place: String = "", placeNoun: String = "", replacedSetting: String = "",
        beats: String = "", camera: String = "", light: String = "", keptSetting: [String] = [],
        notes: [String] = []
    ) {
        (self.characters, self.place, self.placeNoun, self.replacedSetting) =
            (characters, place, placeNoun, replacedSetting)
        (self.beats, self.camera, self.light, self.keptSetting, self.notes) = (beats, camera, light, keptSetting, notes)
    }

    /// Readings saved before a part existed decode without it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characters = try c.decodeIfPresent([Character].self, forKey: .characters) ?? []
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        placeNoun = try c.decodeIfPresent(String.self, forKey: .placeNoun) ?? ""
        replacedSetting = try c.decodeIfPresent(String.self, forKey: .replacedSetting) ?? ""
        beats = try c.decodeIfPresent(String.self, forKey: .beats) ?? ""
        camera = try c.decodeIfPresent(String.self, forKey: .camera) ?? ""
        light = try c.decodeIfPresent(String.self, forKey: .light) ?? ""
        keptSetting = try c.decodeIfPresent([String].self, forKey: .keptSetting) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    /// The wish as written, for `people` characters, with no model to read it: whole, in the notes.
    public static func verbatim(_ text: String, people: Int) -> Wish {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Wish(
            characters: Array(repeating: Character(), count: max(1, people)), notes: text.isEmpty ? [] : [text])
    }

    public var isEmpty: Bool {
        characters.allSatisfy { $0 == Character() } && place.isEmpty && placeNoun.isEmpty
            && replacedSetting.isEmpty && beats.isEmpty && camera.isEmpty && light.isEmpty && keptSetting.isEmpty
            && notes.isEmpty
    }

    /// The words of what the service prompt says on its own, which the reading leaves out by design.
    static let frame: Set = [
        "replace", "swap", "video", "image", "keep", "exactly", "same", "original", "instead", "camera", "framing",
        "timing", "composition", "movement", "moves", "every", "face",
    ]

    /// The reading with every sentence of `text` it leaves out added to the notes as written, and every item it
    /// leaves out of a list it read into a character's looks, so a model that skipped one loses nothing: a part is left out when fewer
    /// than half of its words are anywhere in the reading. Only for a text in the reading's Latin script, since words
    /// of another language never match; what only repeats the service prompt may come back too, which costs a
    /// repeat, not a loss.
    public func covering(_ text: String) -> Wish {
        guard text.range(of: "[^\\p{Latin}\\p{Common}\\p{Inherited}]", options: .regularExpression) == nil
        else { return self }
        let frame = Self.frame
        let parts =
            characters.flatMap { [$0.performer, $0.noun, $0.looks, $0.moving] + $0.kept + $0.notes }
            + [place, placeNoun, replacedSetting, beats, camera, light] + keptSetting + notes
        let read = Words.contentWords(parts.joined(separator: " "))
        let looks = characters.map { Words.contentWords($0.looks) }
        let missing = { (part: String) -> Bool in
            let words = Words.contentWords(part).subtracting(frame)
            return !words.isEmpty && words.intersection(read).count * 2 < words.count
        }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) { sentences.append(sentence) }
        }
        var wish = self
        for sentence in sentences {
            if missing(sentence) {
                wish.notes.append(sentence)
                continue
            }
            let words = Words.contentWords(sentence).subtracting(frame)
            let shared = looks.map { $0.intersection(words).count }.max() ?? 0
            guard shared >= 3 || shared * 2 >= words.count else { continue }
            wish.notes += sentence.split(separator: /[,;:]/).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter(missing).map { $0.replacing(/[.!?]+$/, with: "") }
        }
        return wish
    }

    /// The reading with `people` characters: missing ones empty; what the model put on characters past them goes
    /// to the notes, so none of it is dropped.
    public func sized(_ people: Int) -> Wish {
        var wish = self
        let count = max(1, people)
        wish.characters = Array((characters + Array(repeating: Character(), count: count)).prefix(count))
        for extra in characters.dropFirst(count) {
            wish.notes += [extra.looks].filter { !$0.isEmpty } + extra.kept + extra.notes
        }
        return wish
    }

    /// "hair and scarf" from a model that wrote the whole clause, "her hair and scarf move naturally as she walks"
    /// or "robes and beard flowing and whipping with the motion".
    public static func swinging(_ moving: String) -> String {
        let verb =
            /(?i)\s+(mov(e|es|ing)|swing(s|ing)?|flow(s|ing)?|sway(s|ing)?|bounc(e|es|ing)|whip(s|ping)?|flutter(s|ing)?|flap(s|ping)?|billow(s|ing)?|wav(e|es|ing)|ripple(s)?|rippling|trail(s|ing)?|as\s+(she|he|it|they)\b|with\s+(the|each|every)\b)\b.*$/
        return moving.replacing(/^(?i)(her|his|its|their)\s+/, with: "").replacing(verb, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether a `moving` reading is an action, not the parts that swing: a list of things names each in a few
    /// words ("hair, long skirt and the hem of the coat"), an action is a clause ("throws the stacks of cash at the
    /// camera").
    public static func isAction(_ moving: String) -> Bool {
        moving.split(separator: /,|\s+and\s+/).contains { $0.split(separator: " ").count > 5 }
    }
}
