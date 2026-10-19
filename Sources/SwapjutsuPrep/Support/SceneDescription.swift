import Foundation

/// What a vision-language model, or the person, says the references and the video show: the entity, appearance and
/// beat parts of the Seedance prompt, which Genjutsu's server-side model writes for its own prompt. Every field is
/// plain text the person can edit; an empty one leaves its part of the prompt as `ServicePrompt` writes it without.
public struct SceneDescription: Codable, Sendable, Equatable {
    /// One per character image, in image order.
    public var characters: [Character]
    /// The new place, when the background is replaced.
    public var location: Location?
    /// The moves and gaze, from the keyframes and `PoseBeats`.
    public var motion: Motion?
    /// Which model wrote it, "Qwen3-VL 8B", or "Edited" once the person changed it.
    public var source: String
    /// A model's reading of the person's prompt, with the text it read: the prompt uses it while the person's prompt
    /// is still that text, and the prompt whole otherwise (`Wish.verbatim`).
    public var request: Request?

    public struct Request: Codable, Sendable, Equatable {
        public var text: String
        public var reading: Wish

        public init(text: String, reading: Wish) { (self.text, self.reading) = (text, reading) }
    }

    public struct Character: Codable, Sendable, Equatable {
        /// WOMAN, MAN, CAT: names the character's entity in the prompt.
        public var noun: String
        /// her, his, its or their.
        public var pronoun: String
        public var appearance: String
        public var wardrobe: String
        /// The most recognisable traits, repeated where the prompt renders the character.
        public var traits: String
        /// What swings and settles with movement: "skirt, scarf and hair".
        public var moving: String
        /// The outermost layer worn over the rest, "knee-length tan trench coat"; nil or empty without one, and in
        /// descriptions written before it. A layer wider than the performer's own clothes is outside the colored
        /// silhouette, and Seedance drops what the silhouette doesn't show unless the prompt keeps it in every frame.
        public var outer: String?
        /// How the outer layer is worn and moves: "belted closed, its hem sways as he walks"; nil when unknown.
        public var outerState: String?

        public init(
            noun: String, pronoun: String = "their", appearance: String = "", wardrobe: String = "",
            traits: String = "", moving: String = "", outer: String? = nil, outerState: String? = nil
        ) {
            (self.noun, self.pronoun, self.appearance) = (noun, pronoun, appearance)
            (self.wardrobe, self.traits, self.moving, self.outer, self.outerState) =
                (wardrobe, traits, moving, outer, outerState)
        }
    }

    public struct Location: Codable, Sendable, Equatable {
        /// GARDEN, STREET.
        public var noun: String
        public var description: String
        public var floor: String
        public var light: String

        public init(noun: String, description: String = "", floor: String = "", light: String = "") {
            (self.noun, self.description, self.floor, self.light) = (noun, description, floor, light)
        }
    }

    public struct Motion: Codable, Sendable, Equatable {
        /// "low-angle backward tracking shot".
        public var camera: String
        /// "side step to the left, clockwise full-body turn, final front-facing pose": what the body does, never the
        /// source's own clothes it touches, which the new outfit replaces.
        public var beats: String
        /// The framing and who it holds: "waist-up two-shot".
        public var shot: String
        /// What stays in the frame as filmed, kept by name as Genjutsu's prompt keeps it: "the woman on the left in a
        /// yellow raincoat, a wooden bench, a brick wall".
        public var scene: String
        /// What the performer holds or uses that stays: "the umbrella she holds over her head".
        public var props: String
        /// The on-screen text, quoted: "\"You ready!\", \"Yes\"".
        public var text: String
        /// Whether the performer's feet are on the ground in the frame; nil when unknown.
        // swiftlint:disable:next discouraged_optional_boolean
        public var feet: Bool?
        /// Where the main performer looks for most of the clip: "at the person beside them". The colored depth has
        /// no eyes, so without it Seedance takes the gaze, and the smile, of the character's portrait.
        public var gaze: String
        /// Each replaced performer's own moves and gaze, in image order, when several are replaced; `beats` and
        /// `gaze` are the main performer's.
        public var performers: [Performer]

        public struct Performer: Codable, Sendable, Equatable {
            public var beats: String
            public var gaze: String

            public init(beats: String = "", gaze: String = "") { (self.beats, self.gaze) = (beats, gaze) }
        }

        public init(
            camera: String = "", beats: String = "", shot: String = "", scene: String = "", props: String = "",
            // swiftlint:disable:next discouraged_optional_boolean
            text: String = "", feet: Bool? = nil, gaze: String = "", performers: [Performer] = []
        ) {
            (self.camera, self.beats, self.shot, self.scene) = (camera, beats, shot, scene)
            (self.props, self.text, self.feet) = (props, text, feet)
            (self.gaze, self.performers) = (gaze, performers)
        }

        /// Descriptions saved before the shot, scene, props, text, gaze and performers decode without them.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            camera = try c.decode(String.self, forKey: .camera)
            beats = try c.decode(String.self, forKey: .beats)
            shot = try c.decodeIfPresent(String.self, forKey: .shot) ?? ""
            scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
            props = try c.decodeIfPresent(String.self, forKey: .props) ?? ""
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            feet = try c.decodeIfPresent(Bool.self, forKey: .feet)
            gaze = try c.decodeIfPresent(String.self, forKey: .gaze) ?? ""
            performers = try c.decodeIfPresent([Performer].self, forKey: .performers) ?? []
        }
    }

    public init(
        characters: [Character] = [], location: Location? = nil, motion: Motion? = nil, source: String = "",
        request: Request? = nil
    ) {
        (self.characters, self.location, self.motion, self.source, self.request) =
            (characters, location, motion, source, request)
    }
}

extension SceneDescription {
    /// Whether a model described the clip itself, not only read the person's prompt.
    public var isDescribed: Bool { !characters.isEmpty || location != nil || motion != nil }

    /// The entity names the prompt uses, in image order: the nouns in capitals, numbered where two are the same
    /// ("CAT 1", "CAT 2"); nil where a character has no noun, so the prompt keeps CHARACTER for it.
    public var names: [String?] {
        let nouns = characters.map { Self.entity($0.noun) }
        return nouns.enumerated().map { index, noun in
            guard let noun else { return nil }
            let same = nouns.indices.filter { nouns[$0] == noun }
            return same.count > 1 ? "\(noun) \((same.firstIndex(of: index) ?? 0) + 1)" : noun
        }
    }

    /// A model's noun as an entity name: letters, digits, spaces and hyphens, in capitals, at most three words.
    /// CHARACTER, LOCATION, REFERENCE and FACE are the prompt's own words, so they never come from a description.
    static func entity(_ noun: String) -> String? {
        let kept = String(noun.uppercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " })
        let words = kept.split(separator: " ").prefix(3).joined(separator: " ")
        let reserved: Set = ["CHARACTER", "LOCATION", "REFERENCE", "FACE"]
        return words.isEmpty || reserved.contains(words) ? nil : words
    }
}
