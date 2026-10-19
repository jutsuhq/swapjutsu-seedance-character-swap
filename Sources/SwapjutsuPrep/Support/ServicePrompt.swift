import Foundation
import NaturalLanguage

/// The service part of the Seedance prompt, in the structure of Genjutsu's server-side enhanced prompt: a line per
/// reference naming its entity, a "Video edit." paragraph on what `@Video1` is, one numbered REPLACE item per
/// character and one for a replaced background, the vocals, an identity lock and a closing line. A Seedance 2.5 edit
/// with this structure, our control video without face lines and a face close-up came out with no control colours,
/// clothes that swing and a face close to the reference. The fixed sentences say what the control video's colours
/// mean, which no model looking at the clip knows; everything about this clip, its characters and its place comes
/// from a `SceneDescription` and the person's prompt, and without them the prompt says nothing about either.
///
/// Prep knows the people, their places, the background and the soundtrack and stores them in the manifest; the app
/// adds the face close-ups and the extra references it uploads (`text(closeUps:extras:)`), whose `@Image` numbers
/// only it knows.
public struct ServicePrompt: Codable, Sendable, Equatable {
    /// Replaced people, `@Image1…` in order.
    public var people: Int
    /// Where each stands ("on the left", …), in image order; nil with one person, or when places are missing or too
    /// close to tell apart, where the order of screen presence stays (`Pipeline.places`).
    public var places: [String]?
    public var background: BackgroundMode
    /// Shots in the clip: a single continuous take, or an edit to keep cut for cut.
    public var shots: Int
    public var seconds: Double?
    /// When the replaced people are on screen, from the shots they are in, in seconds; nil for the whole clip, as
    /// manifests from before it decode. A shot without them keeps whoever is in it, so the prompt names only these.
    public var during: [Window]?
    /// The soundtrack's pitch shift, nil when `@Video1` has no vocals: a silent clip described as pitched audio
    /// misleads the lip sync.
    public var semitones: Float?
    /// The face guide drew its lines on some frame, which the prompt then explains.
    public var guided: Bool
    /// A hybrid control (`ControlMode`): real hands or a real body in `@Video1`, which the prompt says are motion
    /// only. Nil for colored depth, as manifests from before it decode.
    public var control: ControlMode?

    /// A stretch of the clip, in seconds.
    public struct Window: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) { (self.start, self.end) = (start, end) }
    }

    public init(
        people: Int, places: [String]? = nil, background: BackgroundMode = .keep, shots: Int = 1,
        seconds: Double? = nil, during: [Window]? = nil, semitones: Float? = nil, guided: Bool = false,
        control: ControlMode? = nil
    ) {
        (self.people, self.places, self.background, self.shots) = (people, places, background, shots)
        (self.seconds, self.during, self.semitones, self.guided) = (seconds, during, semitones, guided)
        self.control = control
    }

    /// The prompt, with `closeUps` (character's `@Image` number → its face close-up's), `views` (character's `@Image`
    /// number → its other angles) and `extras` (the `@Image` numbers of the person's other references) named as
    /// entities. A `description` fills in the entities' names, appearance and wardrobe, the place, the camera and the
    /// beats, as Genjutsu's language model does; the person's own prompt (`wish`) is folded into the same parts by
    /// the description's reading of it (`SceneDescription.request`), their words winning over the description's, so
    /// Seedance gets one prompt, not two. A wish no model read goes in whole (`Wish.verbatim`).
    public func text(
        closeUps: [Int: Int] = [:], views: [Int: [ReferenceView]] = [:], extras: [Int] = [],
        description: SceneDescription? = nil, wish: String = ""
    ) -> String {
        let count = max(1, people)
        let replace = background == .replace
        let location = count + 1
        let folded = Self.reading(of: wish, in: description, people: count)
        let words = Words(prompt: self, description: description, wish: folded, count: count)
        let name = words.name
        var lines: [String] = []
        for k in 1...count {
            lines.append("@Image\(k) — \(name(k)), the replacement \(name(k))\(words.looks(k)).")
            if let face = closeUps[k] {
                lines.append(
                    "@Image\(face) — \(name(k))'s FACE: a close-up of the same \(name(k)) from @Image\(k); it defines "
                        + "\(words.pronoun(k)) recognizable face: the same eyes, nose, lips, face shape and skin.")
            }
            for view in views[k] ?? [] {
                lines.append(view.angle == .sheet ? sheetLine(view, k, words) : viewLine(view, k, words))
            }
        }
        if replace {
            lines.append("@Image\(location) — \(words.place), the replacement LOCATION\(words.placeLooks).")
        }
        for (index, image) in extras.enumerated() {
            let reference = extras.count == 1 ? "REFERENCE" : "REFERENCE \(index + 1)"
            lines.append("@Image\(image) — \(reference), an extra reference; the request below says how to use it.")
        }
        lines.append(videoEdit(count, words: words))
        for k in 1...count { lines.append(replaceLine(k, closeUp: closeUps[k], views: views[k] ?? [], words: words)) }
        if let beats = words.sharedBeats { lines.append(beats) }
        if replace {
            let setting = folded.replacedSetting.replacing(/^(?i)(?:the|an?)\s+/, with: "")
            let replaced = setting.isEmpty ? "" : " — the original \(setting) —"
            lines.append(
                "\(count + 1). REPLACE everything painted with grey depth\(replaced) (\(span)) with \(words.place) from "
                    + "@Image\(location); its layout and parallax follow the grey depth in every frame.\(words.ground) "
                    + "Keep the source perspective, framing and camera movement; no other people or visible text "
                    + "appear. \(Self.unseen(words.place, image: location))")
        }
        let said = lines.joined(separator: " ")
        // With the background kept, the person's light has no place line to go in.
        let light = replace ? nil : Words.clean(folded.light).map { "The scene is \(Words.lit($0))." }
        let notes = (folded.notes + [light].compactMap(\.self)).filter { !Words.repeats($0, in: said) }
        if !notes.isEmpty { lines.append(notes.map(Words.sentence).joined(separator: " ")) }
        if let semitones, semitones != 0 {
            lines.append(
                String(
                    format:
                        "@Video1 contains embedded vocals pitched up %.0f semitones; use them for performance and lip synchronization.",
                    semitones))
        }
        lines.append(identityLock(count, closeUps: closeUps, views: views, words: words))
        let kept = words.scene.map { "\($0), " } ?? ""
        lines.append(
            "Everything else — \(kept)the inherited choreography, blocking, framing and composition, the camera moves "
                + "and all timing — stays exactly the same.")
        return lines.joined(separator: "\n")
    }

    /// The description's reading of `wish` while it is still the text read, else the wish whole.
    static func reading(of wish: String, in description: SceneDescription?, people: Int) -> Wish {
        let text = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        if let request = description?.request, request.text.trimmingCharacters(in: .whitespacesAndNewlines) == text,
            !text.isEmpty
        {
            return request.reading.sized(people)
        }
        return .verbatim(text, people: people)
    }

    /// CHARACTER, or CHARACTER 1… with several people.
    func defaultName(_ k: Int) -> String { people > 1 ? "CHARACTER \(k)" : "CHARACTER" }

    /// " on the left", " with the second-most screen presence", or nothing: with one person, where the person's own
    /// words for the performer (`named`) already say the place, or name the performer when prep found no places.
    private func performer(_ k: Int, named: String?) -> String {
        guard people > 1 else { return "" }
        if let places, places.count == people {
            let place = places[k - 1]
            return named?.lowercased().contains(place.lowercased()) == true ? "" : " \(place)"
        }
        guard named == nil else { return "" }
        let ranks = ["most", "second-most", "third-most", "fourth-most", "fifth-most", "sixth-most"]
        return " with the \(k <= ranks.count ? ranks[k - 1] : "number \(k)") screen presence"
    }

    /// "0–7s", or "the whole clip" when the length is unknown; "0–6.8s" or "0–3s and 5–7s" when the replaced
    /// people are in only some shots (`during`).
    private var span: String {
        if let during, !during.isEmpty, !Self.covers(during, seconds) {
            return Self.list(during.map { "\(Self.format($0.start))–\(Self.format($0.end))s" })
        }
        return seconds.map { "0–\(Self.format($0))s" } ?? "the whole clip"
    }

    /// Whether `during` is the whole clip of `seconds`, to a tenth of a second.
    static func covers(_ during: [Window], _ seconds: Double?) -> Bool {
        guard during.count == 1, let window = during.first, window.start < 0.05 else { return false }
        return seconds.map { window.end > $0 - 0.05 } ?? true
    }

    private func videoEdit(_ count: Int, words: Words) -> String {
        let one = count == 1
        let performers =
            switch control {
            case .hybridBody?:
                one
                    ? "the person shown as real footage with a colored-depth head is the performer"
                    : "the \(count) people shown as real footage with colored-depth heads are the performers"
            case .hybridHands?:
                one
                    ? "the person painted with colored depth, with their real hands from the footage, is the performer"
                    : "the \(count) people painted with colored depth, with their real hands from the footage, are "
                        + "the performers"
            default:
                one
                    ? "the person painted with colored depth is the performer"
                    : "the \(count) people painted with colored depth are the performers"
            }
        let setting =
            control == .hybridBody
            ? "\(performers), and everything around them is "
                + (background == .replace
                    ? "painted with grey depth: the setting" : "the original footage, kept exactly")
                + "; the depth colors and the grey are guidance only and must never appear."
            : background == .replace
                ? "\(performers), and everything painted with grey depth is the setting; the colors and the grey are "
                    + "guidance only and must never appear."
                : "\(performers), and every other pixel is the original footage, kept exactly; the depth colors are "
                    + "guidance only and must never appear."
        let silhouette =
            control == .hybridBody
            ? "The real \(one ? "body is" : "bodies are") the motion only: \(one ? "it gives" : "they give") the pose, "
                + "gestures, hands and timing, not the look; face, hair, skin and outfit come from the reference "
                + "\(one ? "image" : "images"), and none of the source's clothes, accessories or jewellery stays."
            : one
                ? "The colored silhouette gives the pose and body, not the shape of the clothes: clothing and hair follow "
                    + "the reference image and may extend beyond it."
                : "The colored silhouettes give the poses and bodies, not the shape of the clothes: clothing and hair "
                    + "follow the reference images and may extend beyond them."
        // Without a word on them, the face guide's white lines read as a drawing on the face to keep; without lines,
        // the sentence would send Seedance looking for some.
        let lines =
            guided
            ? " White lines on the faces mark the brows, eyes, nose, mouth and jaw: follow them for the head turn, gaze "
                + "and expression, and never draw them."
            : ""
        let length = seconds.map { " \(Self.format($0))s" } ?? ""
        let take =
            shots > 1
            ? "Keep the same\(length) edit cut for cut, its \(shots) shots"
            : "Keep the same single continuous\(length) take"
        let shot = shots > 1 ? ", every shot's framing" : words.shot.map { ", the same \($0)" } ?? ""
        let framing = shots > 1 || words.camera?.contains("framing") == true ? "" : "framing, "
        // "the same waist-up shot, the same static camera": one "shot" is the framing, the other the movement.
        let camera = shot.isEmpty ? words.camera : words.camera?.replacing(/(?i)\s+shot$/, with: " camera")
        let movement = camera.map { "the same \($0)" } ?? "the camera movement"
        let scene = words.scene.map { " Keep \($0) exactly as filmed." } ?? ""
        // Genjutsu keeps the source's captions in every prompt; with the background replaced none stay.
        let text =
            words.text.map {
                " Keep the on-screen text \($0) exactly as it appears in @Video1: its wording, styling, placement and "
                    + "timing."
            } ?? ""
        let realHands =
            control == .hybridHands
            ? " The real hands are the motion only: they give the exact hand pose, grip and finger movement, and take "
                + "the character's skin and whatever the character wears on its arms and hands."
            : ""
        return "Video edit. @Video1 is a motion guide: \(setting) \(silhouette)\(realHands)\(lines) \(take)\(shot), "
            + "\(movement), \(framing)composition, pacing and the timing of every beat.\(scene)\(text)"
    }

    /// "1. REPLACE the colored-depth performer … with WOMAN from @Image1, @Image4 and @Image3, …": the character,
    /// its views and its face close-up, the face from the close-up when there is one.
    private func replaceLine(_ k: Int, closeUp: Int?, views: [ReferenceView], words: Words) -> String {
        let images = ([k] + views.map(\.image) + (closeUp.map { [$0] } ?? [])).map { "@Image\($0)" }
        let notes = words.notes(k).map { " " + $0 } ?? ""
        return
            "\(k). REPLACE the \(performerWord(words.performer(k)))\(performer(k, named: words.performer(k))) (\(span)) with \(words.name(k)) "
            + "from \(Self.list(images)), matched beat-for-beat\(words.beats(k))\(words.body(k)). Render "
            + "\(words.appearance(k)), with the recognizable face from @Image\(closeUp ?? k); "
            + "\(words.moving(k)) swing and settle naturally through every movement. \(Self.performance)\(words.gaze(k))"
            + "\(words.outerLine(k))\(words.props(k))\(notes)\(motionOnly(k, words))\(words.feet ? Self.contact : "")"
    }

    /// "colored-depth performer", or with the real body the one "with the colored-depth head"; with the person's
    /// own words for who it is, "colored-depth man dancing on the left".
    private func performerWord(_ who: String? = nil) -> String {
        let who = who ?? "performer"
        return control == .hybridBody ? "\(who) with the colored-depth head" : "colored-depth \(who)"
    }

    /// A camera that turns past what the place's one image shows leaves Seedance to invent the rest, and it can
    /// invent a different place.
    static func unseen(_ place: String, image: Int) -> String {
        "Where the camera turns to parts of the setting @Image\(image) doesn't show, continue the same \(place) — its "
            + "look, materials and light — and never cut to a different place."
    }

    /// With a hybrid control: what of the real pixels is kept (the motion) and what is replaced.
    private func motionOnly(_ k: Int, _ words: Words) -> String {
        switch control {
        case .hybridHands?:
            " \(Self.hands) Take the hand pose and finger motion from the real hands in @Video1; the hands and arms "
                + "take \(words.name(k))'s skin and whatever \(words.name(k)) wears on them in @Image\(k)."
        case .hybridBody?:
            " Take only the motion from the real body in @Video1; replace its face, hair, skin and outfit with "
                + "\(words.name(k)) from @Image\(k)."
        default: ""
        }
    }

    /// With the real hands of hybrid-hands only (Genjutsu says nothing about hands): a source hand hidden in
    /// clothing the new outfit doesn't have is a hand Seedance has no shape for, and it draws it without fingers.
    static let hands =
        "Hands always keep five complete, natural fingers; where a source hand disappears into clothing the new "
        + "outfit doesn't have, it rests against the body with every finger visible."

    /// The identity lock holds who the character is; this holds the surface, as NRDX's H3 template does.
    static let stable = "Skin, hair and fabric keep their texture in every frame, with no crawling or flicker."

    /// What the performer gives besides the moves, said whether or not the face guide drew its lines: the
    /// character-swap template NRDX trained MiniMax H3 on names each of these, frame by frame.
    static let performance =
        "The head turns, gaze, facial expressions and lip movement follow the performer's, frame by frame."

    /// Said where the feet are on the ground: Genjutsu's prompt gives the replacement's floor shadows only where
    /// they show.
    static let contact = " Keep natural body weight and foot contact, with a soft contact shadow throughout."

    /// "@Image7 — WOMAN from behind: the same WOMAN as @Image1, seen from behind; it defines the back of her hair
    /// and wardrobe in every turn away from the camera." A view without an angle is "another view of WOMAN".
    private func viewLine(_ view: ReferenceView, _ k: Int, _ words: Words) -> String {
        let name = words.name(k), pronoun = words.pronoun(k)
        guard let angle = view.angle else {
            return "@Image\(view.image) — another view of \(name): the same \(name) as @Image\(k); it defines "
                + "\(pronoun) face, hair and wardrobe through every turn."
        }
        let defines =
            switch angle {
            case .back: "the back of \(pronoun) hair and wardrobe in every turn away from the camera"
            case .side: "\(pronoun) profile, hair and wardrobe from the side"
            default: "\(pronoun) face, hair and wardrobe through every turn"
            }
        return "@Image\(view.image) — \(name) \(angle.seen.replacingOccurrences(of: "seen ", with: "")): the same "
            + "\(name) as @Image\(k), \(angle.seen); it defines \(defines)."
    }

    private func sheetLine(_ view: ReferenceView, _ k: Int, _ words: Words) -> String {
        let name = words.name(k)
        return
            "@Image\(view.image) — \(name)'s CHARACTER SHEET: the same \(name) as @Image\(k) \(CharacterAngle.sheet.seen); "
            + "it defines \(words.pronoun(k)) look from every side, including the back of \(words.pronoun(k)) hair "
            + "and wardrobe."
    }

    private func identityLock(_ count: Int, closeUps: [Int: Int], views: [Int: [ReferenceView]], words: Words) -> String
    {
        let name = words.name
        let faces = (1...count).map { k in "\(name(k))'s face matches @Image\(closeUps[k] ?? k)" }
        let named = (1...count).contains { name($0) != defaultName($0) }
        let group = named ? "each of \(Self.list((1...count).map(name)))" : "each CHARACTER"
        let each = named ? "each one's" : "each CHARACTER's"
        var lock =
            count == 1
            ? "Identity lock: \(name(1)) belongs only to the \(performerWord(words.performer(1))) during \(span) and is "
                + "never duplicated onto another figure. Lock \(name(1))'s complete image-defined identity, face and "
                + "wardrobe\(words.outerLock(1)) throughout \(span); \(Self.list(faces)) in every frame."
            : "Identity lock: \(group) belongs only to its own \(performerWord()) during \(span) and is "
                + "never duplicated onto another figure. Lock \(each) complete image-defined identity, face "
                + "and wardrobe throughout \(span); \(Self.list(faces)) in every frame."
        for k in 1...count where !(views[k] ?? []).isEmpty {
            let angles = Self.list((views[k] ?? []).map { "@Image\($0.image)" })
            lock +=
                " \(name(k)) stays the same character from every angle, matching \(angles) whenever turned or "
                + "seen from behind."
        }
        lock += " \(Self.worn(count, words)) \(Self.portrait(count, words))"
        lock += " \(Self.stable)"
        if background == .replace {
            lock += " Lock \(words.place) only to the background replacement during \(span)."
        }
        return lock
    }

    /// What the performer wears is never the character's: the person's words name the performer by it ("the man
    /// with glasses") and the footage may show it at the edge of the silhouette, and Seedance put glasses on a
    /// character whose image has none. The examples leave out what a character's own looks have: "nothing the
    /// performer wears, such as glasses" says no glasses to a character who wears them.
    static func worn(_ count: Int, _ words: Words) -> String {
        let who = count == 1 ? "\(words.name(1)) wears" : "Each one wears"
        let image = count == 1 ? "@Image1" : "their own image"
        let examples = Self.wornExamples.filter { _, pattern in !(1...count).contains { words.has(pattern, k: $0) } }
            .map(\.name)
        let such = examples.isEmpty ? "" : ", such as \(Self.list(examples, or: true)),"
        return "\(who) only what \(image) shows and the request gives: nothing the performer wears\(such) carries over."
    }

    /// What a performer often wears that isn't the character's, and how a character's looks name it.
    static let wornExamples: [(name: String, pattern: String)] = [
        ("glasses", #"\b(glasses|spectacles|eyeglasses|sunglasses|goggles)\b"#),
        ("a hat", #"\b(hats?|caps?|beanies?|berets?|hoods?|helmets?)\b"#),
        ("jewellery", #"\b(jewel\w*|necklaces?|earrings?|bracelets?|rings?|piercings?|hoops?|chains?)\b"#),
    ]

    /// The colored depth has no eyes or expression, so Seedance took the character portrait's smile and its look
    /// into the camera while the performer looked elsewhere.
    static func portrait(_ count: Int, _ words: Words) -> String {
        count == 1
            ? "The pose, expression and gaze in @Image1 are only the portrait's: \(words.name(1))'s expression and "
                + "where \(words.name(1)) looks follow the performer."
            : "The pose, expression and gaze in each image are only the portrait's: each one's expression and where "
                + "each one looks follow their own performer."
    }

    /// 7 → "7", 6.96 → "7", 5.25 → "5.3".
    static func format(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
    }

    /// "a, b and c", or "a, b or c" with `or`.
    static func list(_ items: [String], or: Bool = false) -> String {
        guard items.count >= 2 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + (items.last ?? "")
    }
}

/// The parts of the prompt a `SceneDescription` fills in, each falling back to the wording without one.
struct Words {
    let prompt: ServicePrompt
    let description: SceneDescription?
    var wish = Wish.verbatim("", people: 1)
    let count: Int

    init(prompt: ServicePrompt, description: SceneDescription?, wish: Wish? = nil, count: Int) {
        (self.prompt, self.description, self.count) = (prompt, description, count)
        if let wish { self.wish = wish }
    }

    private func asked(_ k: Int) -> Wish.Character? {
        wish.characters.indices.contains(k - 1) ? wish.characters[k - 1] : nil
    }

    private func character(_ k: Int) -> SceneDescription.Character? {
        guard let characters = description?.characters, k - 1 < characters.count else { return nil }
        return characters[k - 1]
    }

    static func clean(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".;,")))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The person's word for the character ("the old wizard" → WIZARD), else the description's entity name, else
    /// CHARACTER; two of the same are numbered ("CAT 1", "CAT 2").
    func name(_ k: Int) -> String {
        let nouns = (1...count).map { askedNoun($0) ?? describedNoun($0) }
        guard let noun = nouns[k - 1] else { return prompt.defaultName(k) }
        let same = (1...count).filter { nouns[$0 - 1] == noun }
        return same.count > 1 ? "\(noun) \((same.firstIndex(of: k) ?? 0) + 1)" : noun
    }

    /// The last word of the person's noun for the character as an entity name: the thing, without what they say
    /// of it ("blonde girl" → GIRL); nil for a pronoun ("her"), which is no name.
    private func askedNoun(_ k: Int) -> String? {
        guard let noun = asked(k)?.noun, !Self.isPronoun(noun),
            let last = noun.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).last
        else { return nil }
        return SceneDescription.entity(String(last))
    }

    private func describedNoun(_ k: Int) -> String? { character(k).flatMap { SceneDescription.entity($0.noun) } }

    /// Whether `word` is only a pronoun.
    static func isPronoun(_ word: String) -> Bool {
        word.firstMatch(of: /^(?i)\s*(she|he|it|they|her|him|them|his|its|their|herself|himself)\s*$/) != nil
    }

    func pronoun(_ k: Int) -> String {
        let pronoun = Self.clean(character(k)?.pronoun)?.lowercased() ?? Self.clean(asked(k)?.pronoun) ?? ""
        return ["her", "his", "its", "their"].contains(pronoun) ? pronoun : "their"
    }

    /// The person's words for who is replaced: "man dancing on the left"; nil for a bare pronoun ("her"), which
    /// names no one in the video.
    func performer(_ k: Int) -> String? {
        guard
            let who = Self.clean(asked(k)?.performer)?.replacing(/(?i)^(the|a|an)\s+/, with: "")
                .replacing(/(?i)\s+(in|from|of)\s+@video\d+$/, with: ""),
            !Self.isPronoun(who)
        else { return nil }
        return who
    }

    /// ": wears glasses. Young woman with round glasses, …. Wardrobe: grey hoodie, …", or nothing. The person's
    /// words for the looks come first, then what the description of the image adds to them (`unsaid`): a few words
    /// of theirs never take the rest of the image's description away, and where theirs say otherwise, they win.
    /// Never the portrait's expression: the expression is the performer's.
    func looks(_ k: Int) -> String {
        let theirs = Self.clean(Self.described(asked(k)?.looks ?? "")) ?? ""
        let parts = [
            Self.clean(theirs),
            Self.unsaid(Self.expressionless(character(k)?.appearance), by: theirs).map {
                theirs.isEmpty ? $0 : $0.uppercasedFirst
            },
            Self.unsaid(character(k)?.wardrobe, by: theirs).map { "Wardrobe: \($0)" },
        ].compactMap(\.self)
        return parts.isEmpty ? "" : ": " + parts.joined(separator: ". ")
    }

    /// The person's words for the looks without the parts that only name what is kept ("face, hair and outfit", of
    /// "keep her face, hair and outfit"; "same face"): those say nothing of how the character looks.
    static func described(_ text: String) -> String {
        let parts = items(text, atAnd: true)
        let kept = parts.filter { part in
            guard let head = head(part), features.contains(head) else { return true }
            return describes(part)
        }
        return kept.count == parts.count ? text : kept.joined(separator: ", ")
    }

    /// What a person keeps of a character by naming it, not by saying how it looks.
    static let features: Set<String> = [
        "face", "faces", "hair", "hairstyle", "outfit", "outfits", "clothes", "clothing", "look", "looks",
        "appearance", "body", "wardrobe", "style", "features", "identity", "skin", "eyes", "makeup", "figure",
    ]

    /// Whether the character's looks (the person's words, the image's description and traits) match `pattern`.
    func has(_ pattern: String, k: Int) -> Bool {
        let looks = [asked(k)?.looks, character(k)?.appearance, character(k)?.wardrobe, character(k)?.traits]
            .compactMap(\.self).joined(separator: " ")
        return looks.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The description's list without the portrait's expression: "gentle smile", "neutral expression".
    static func expressionless(_ text: String?) -> String {
        items(text ?? "").filter { !isExpression($0) }.joined(separator: ", ")
    }

    /// An appearance's part about the portrait's expression.
    static func isExpression(_ part: String) -> Bool {
        part.firstMatch(of: /(?i)\b(expression|smil\w*|grin\w*|frown\w*|laugh\w*|neutral|serious|calm|happy|sad|pensive)\b/)
            != nil
    }

    /// "MAN's full declared appearance — short dark hair, …" or the complete image-defined appearance: the model's
    /// traits, without those the person's own words for the looks say otherwise, and never the portrait's expression.
    func appearance(_ k: Int) -> String {
        if let traits = Self.unsaid(Self.expressionless(character(k)?.traits), by: asked(k)?.looks ?? "") {
            return "\(name(k))'s full declared appearance — \(traits) —"
        }
        return "\(name(k))'s complete image-defined appearance and stature"
    }

    /// The items of the description's `text` (a comma-separated list) that the person's `theirs` don't already say,
    /// as a list; nil when none is left. An item is said when an item of theirs names the same thing and describes
    /// it ("short red hair" says "long blonde hair in loose waves", "wears glasses" doesn't say "round glasses"), or
    /// has most of its words.
    static func unsaid(_ text: String?, by theirs: String) -> String? {
        // "a cardigan over a white T-shirt" names two garments.
        let mine = items(theirs, atAnd: true).flatMap { $0.split(separator: /\s+(?:over|under)\s+/).map(String.init) }
            .filter {
            !$0.lowercased().hasPrefix("same ") && !$0.lowercased().hasPrefix("the same ")
        }
        let all = items(text ?? "")
        let kept = all.filter { item in
            let words = contentWords(item)
            return !mine.contains { other in
                let shared = words.intersection(contentWords(other)).count
                return (head(other) == head(item) && head(item) != nil && describes(other))
                    || (shared >= 2 && shared * 2 >= words.count)
            }
        }
        return kept.count == all.count ? clean(text) : clean(kept.joined(separator: ", "))
    }

    /// "long blonde hair", "oval face": a list's items, split at commas and semicolons, and at "and" with `atAnd`
    /// (the person's "face, hair and school uniform"; never the description's "black and white shirt").
    static func items(_ text: String, atAnd: Bool = false) -> [String] {
        text.split(separator: atAnd ? /[,;]|\s+and\s+|\.\s+/ : /[,;]|\.\s+/).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        }.filter { !$0.isEmpty }
    }

    /// The thing an item names: its last word before a "with", "in", "over" or "of", "hair" in "long blonde hair in
    /// loose waves"; nil without one.
    static func head(_ item: String) -> String? {
        let name = item.split(separator: /\s+(?:with|in|over|under|of|on)\s+/).first ?? ""
        return name.lowercased().split { !$0.isLetter && $0 != "-" }.last.map { synonyms[String($0)] ?? String($0) }
    }

    /// Garment names said two ways: the person's "white T-shirt" and the description's "white crew-neck tee" are one.
    static let synonyms = [
        "tee": "t-shirt", "tshirt": "t-shirt", "trousers": "pants", "trainers": "sneakers", "jumper": "sweater",
        "pullover": "sweater",
    ]

    /// Whether `item` says what its thing looks like: a word before the thing's name that isn't a verb or "same"
    /// ("short red hair", "silver hair", "school uniform"; not "wears glasses" or "the same hair").
    static func describes(_ item: String) -> Bool {
        let name = String(item.split(separator: /\s+(?:with|in|over|under|of|on)\s+/).first ?? "")
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = name
        var tags: [(word: String, tag: NLTag?)] = []
        tagger.enumerateTags(
            in: name.startIndex..<name.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            tags.append((name[range].lowercased(), tag))
            return true
        }
        let modifiers: Set<NLTag> = [.adjective, .noun, .number]
        return tags.dropLast().contains { word, tag in
            word != "same" && tag.map(modifiers.contains) == true
                && !["wears", "wearing", "has", "having", "with", "in"].contains(word)
        }
    }

    /// The person's other sentences about the character, after the rendering; nil without any.
    /// A note that only says again another part of the reading goes: a model copies a clause of who the performer
    /// is ("dribbles the ball", of "the man who dribbles the ball") into the notes.
    func notes(_ k: Int) -> String? {
        let parts = [asked(k)?.performer, asked(k)?.looks, asked(k)?.moving, wish.beats].compactMap(\.self)
        let said = parts.joined(separator: " ")
        let notes = (asked(k)?.notes ?? []).filter { said.isEmpty || !Self.repeats($0, in: said) }
        return notes.isEmpty ? nil : notes.map(Self.sentence).joined(separator: " ")
    }

    /// A note as a sentence: a capital first, and a full stop when it ends without a mark. A wish taken whole
    /// keeps its own layout.
    static func sentence(_ note: String) -> String {
        guard let first = note.first, !note.contains("\n") else { return note }
        let ended = note.last.map { ".!?…\"')".contains($0) } ?? true
        return first.uppercased() + note.dropFirst() + (ended ? "" : ".")
    }

    /// The outer layer the description of the character's image names, in the person's words when their looks
    /// name the same garment: a layer wider than the performer's own clothes is outside the colored silhouette, and
    /// Seedance drops what the silhouette doesn't show unless the prompt keeps it in every frame. Nil without one;
    /// it is never guessed from the wardrobe's words.
    func outer(_ k: Int) -> String? {
        guard let described = Self.clean(character(k)?.outer) else { return nil }
        let said = Self.garment(described, in: asked(k)?.looks ?? "") ?? described
        return said.replacing(/^(?i)(?:an?\s+|the\s+)/, with: "")
    }

    /// "long open black robe with red lining", the item of the person's "white shirt, long open black robe with red
    /// lining, grey skirt" that names the described "knee-length black robe"'s garment, or has most of its words
    /// under another name (a translated "cloak" for the image's "robe"); nil when none does, or when it only names
    /// it ("the coat").
    static func garment(_ outer: String, in looks: String) -> String? {
        let head = outer.split(separator: /\s+(?:with|in|over|and)\s+|[,;(]/).first ?? ""
        guard let noun = head.split(separator: " ").last?.lowercased(), noun.count > 2 else { return nil }
        let described = contentWords(outer)
        let items = looks.split(separator: /[,;]|\s+(?:and|over)\s+/).map { $0.trimmingCharacters(in: .whitespaces) }
        return items.first { item in
            let words = item.lowercased().split { !$0.isLetter && $0 != "-" }.filter {
                !["a", "an", "the"].contains($0)
            }
            let shared = described.intersection(contentWords(item)).count
            return words.count > 1
                && (words.contains { $0 == noun || $0 == noun + "s" } || (shared >= 3 && shared * 2 >= described.count))
        }
    }

    /// " His knee-length tan trench coat is worn over the rest of the outfit in every frame, belted closed, its hem
    /// sways; it never disappears, …": how it is worn as the description says, and nothing about it unsaid.
    func outerLine(_ k: Int) -> String {
        guard let outer = outer(k) else { return "" }
        let possessive = pronoun(k).prefix(1).uppercased() + pronoun(k).dropFirst()
        // How it is worn, without what the person's own words for it already say: "zipped closed" twice.
        let said = Self.contentWords(outer)
        let state = Self.clean(character(k)?.outerState).flatMap { state in
            let rest = state.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !Self.contentWords($0).isSubset(of: said) }
            return rest.isEmpty ? nil : rest.joined(separator: ", ")
        }
        return " \(possessive) \(outer) is worn over the rest of the outfit in every frame"
            + (state.map { ", \($0.lowercasedFirst)" } ?? "") + "; it never disappears, even where the silhouette "
            + "in @Video1 is narrower than it."
    }

    /// ", including his knee-length tan trench coat and the silver necklace,": the outer layer and what the person
    /// says the character keeps, or nothing.
    func outerLock(_ k: Int) -> String {
        let items = (outer(k).map { ["\(pronoun(k)) \($0)"] } ?? []) + (asked(k)?.kept ?? [])
        return items.isEmpty ? "" : ", including \(ServicePrompt.list(items)),"
    }

    /// "her skirt, scarf and hair", or "hair and clothing". A reading saved before its parser cut the clause around
    /// the parts is cut here, and one that is an action is no part (`askedAction`).
    func moving(_ k: Int) -> String {
        let theirs = Self.clean(asked(k)?.moving).map(Wish.swinging).flatMap { Wish.isAction($0) ? nil : Self.clean($0) }
        guard
            let moving = (theirs ?? Self.clean(character(k)?.moving))?
                .replacing(/^(?i)(her|his|its|their)\s+/, with: ""),
            !["none", "empty", "n/a"].contains(moving.lowercased())
        else { return "hair and clothing" }
        return "\(pronoun(k)) \(moving)"
    }

    /// The moves the person lists for several performers together, which no one replace line owns.
    var sharedBeats: String? {
        guard count > 1, let beats = Self.clean(wish.beats) else { return nil }
        return "They keep the original moves, matched beat-for-beat: \(beats)."
    }

    /// " to the original moves (side step to the left, …)", in a form that reads whether the beats are verbs
    /// ("walks forward") or nouns ("a side step"): the moves `PoseBeats` timed are the largest body's, so the
    /// description's shared beats go to a single character only; with several, each takes their own performer's
    /// moves the description read apart.
    func beats(_ k: Int) -> String {
        guard count == 1 else {
            return performer(of: k).flatMap { Self.clean($0.beats) }.map { " to the original moves (\($0))" } ?? ""
        }
        guard let beats = Self.clean(wish.beats) ?? askedAction(k) ?? Self.clean(description?.motion?.beats)
        else { return "" }
        return " to the original moves (\(beats))"
    }

    /// An action a reading saved before its parser gave actions to the beats put in `moving`.
    private func askedAction(_ k: Int) -> String? {
        Self.clean(asked(k)?.moving).map(Wish.swinging).flatMap { Wish.isAction($0) ? Self.clean($0) : nil }
    }

    /// The description's reading of the `k`th replaced performer, when it read them apart.
    private func performer(of k: Int) -> SceneDescription.Motion.Performer? {
        guard let performers = description?.motion?.performers, performers.count == count else { return nil }
        return performers[k - 1]
    }

    /// " WOMAN looks at the person beside them, as the performer does.": where the performer looks, which the
    /// colored depth can't show; nothing when the description doesn't say.
    func gaze(_ k: Int) -> String {
        let gaze = count == 1 ? description?.motion?.gaze : performer(of: k)?.gaze
        guard let gaze = Self.clean(gaze) else { return "" }
        return " \(name(k)) looks \(gaze.lowercasedFirst), as the performer does."
    }

    /// ", adapted naturally to the cat's body" for a character that isn't a person (pronoun "its"), as Genjutsu
    /// writes for an animal replacing a person; nothing for a person.
    func body(_ k: Int) -> String {
        guard pronoun(k) == "its" else { return "" }
        return ", adapted naturally to the \(name(k).replacing(/\s+\d+$/, with: "").lowercased())'s body"
    }

    /// " WOMAN keeps the umbrella she holds over her head, used as in @Video1.": a single character only, like the
    /// beats, and only when the description says how the performer holds or uses it. A bare "microphone" is often
    /// one hanging above them, which the original footage keeps anyway; "keeps" would put it in their hand.
    func props(_ k: Int) -> String {
        guard count == 1, let props = Self.clean(description?.motion?.props),
            props.firstMatch(of: /(?i)\b(her|his|their|its|holds?|holding|held|carr(y|ies|ying)|us(es|ing))\b/) != nil
        else { return "" }
        return " \(name(k)) keeps \(props.lowercasedFirst), used as in @Video1."
    }

    /// The person's words for the camera, else the description's: "static full-body framing" from "the same static
    /// full-body framing, the same composition and timing as @Video1", since the prompt says "the same" itself and
    /// keeps the composition and timing in its own words.
    var camera: String? {
        let asked = Self.clean(wish.camera).map { camera in
            camera.split(separator: ",").map {
                $0.replacing(/(?i)^\s*(keep\s+)?(the\s+)?same\s+/, with: "")
                    .replacing(/(?i)\s+(as|from)\s+(in\s+)?@video\d+\s*$/, with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !Self.contentWords($0).subtracting(Wish.frame).isEmpty }.joined(separator: ", ")
        }
        // A model's bare "static" or "handheld, tracking" gets its noun; the person's words stay theirs.
        let seen = Self.clean(description?.motion?.camera).map { camera in
            camera.firstMatch(of: /(?i)\b(shot|camera|movement|motion|framing|angle|pan|tilt|zoom)$/) == nil
                ? camera + " camera" : camera
        }
        return Self.clean(asked) ?? seen
    }

    /// The description's framing, from its keyframes: one label for a single take only, since an edit's shots
    /// may each be framed differently.
    var shot: String? {
        guard prompt.shots == 1, let shot = Self.clean(description?.motion?.shot) else { return nil }
        // A bare "full-body" from a model is no noun for "the same …".
        return shot.firstMatch(of: /(?i)\b(shot|close-up|closeup|view|frame|framing)\b/) == nil ? shot + " shot" : shot
    }

    /// What stays in the frame, only with the background kept: a replaced one keeps nothing of the source. The
    /// things the person names first, in their words, then those the description adds that share no word with them.
    var scene: String? {
        guard prompt.background != .replace else { return nil }
        let said = wish.keptSetting.compactMap { Self.clean($0) }
        let named = Set(said.flatMap(Self.contentWords))
        let seen = (Self.clean(description?.motion?.scene) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Self.contentWords($0).isDisjoint(with: named) }
            .map(Self.definite)
        let all = said + seen
        return all.isEmpty ? nil : all.joined(separator: ", ").lowercasedFirst
    }

    /// "the illuminated advertising board" for a model's bare "illuminated advertising board"; a thing with its
    /// own article, number or possessive stays, and so does a name.
    static func definite(_ thing: String) -> String {
        let determiner =
            /^(?i)(the|a|an|this|that|these|those|his|her|their|its|my|our|your|some|every|each|all|both|no|one|two|three|four|five|six|several|many|\d+)\b/
        guard thing.firstMatch(of: determiner) == nil else { return thing }
        // A name ("Times Square") takes none.
        let named = thing.split(separator: " ").dropFirst().contains { $0.first?.isUppercase == true }
        return named ? thing : "the " + thing.lowercasedFirst
    }

    /// Whether `note` only says again what `prompt` says: every word of it is there, as itself or another form of it
    /// ("moves", "movement"), or is one the service prompt says in its own words (`Wish.frame`, "the same places"
    /// for its blocking), and it forbids nothing. A model's reading copies the person's sentences on moves and
    /// timing into the notes.
    /// note: a note that only rearranges the prompt's words goes too; upgrade path: the reading model marks the
    /// notes that add something.
    static func repeats(_ note: String, in prompt: String) -> Bool {
        let own: Set = [
            "place", "places", "position", "positions", "perform", "performs", "they", "them", "this", "that",
        ]
        let words = contentWords(note).subtracting(Wish.frame).subtracting(own)
        guard !contentWords(note).isEmpty,
            note.firstMatch(of: /(?i)\b(no|not|never|nothing|without|don't|doesn't)\b/) == nil
        else { return false }
        let prompt = contentWords(prompt)
        return words.allSatisfy { word in
            prompt.contains { other in
                zip(word, other).prefix { $0 == $1 }.count >= max(4, min(word.count, other.count) - 2)
            }
        }
    }

    /// The words of four letters or more that name or describe a thing, for telling two names of it apart.
    static func contentWords(_ text: String) -> Set<String> {
        let function: Set = ["from", "with", "above", "below", "behind", "front", "left", "right", "side", "their"]
        return Set(
            text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !function.contains($0) }
        )
    }

    var text: String? { prompt.background == .replace ? nil : Self.clean(description?.motion?.text) }

    /// The feet are on the ground, or unknown: without a description the contact shadow stays.
    var feet: Bool { description?.motion?.feet ?? true }

    var place: String {
        SceneDescription.entity(wish.placeNoun) ?? description?.location.flatMap { SceneDescription.entity($0.noun) }
            ?? "LOCATION"
    }

    /// What the person said the place looks like, then the description of its image, unless theirs already say
    /// most of it: their few words never take the image's description away.
    var placeLooks: String {
        let theirs = Self.clean(wish.place), seen = Self.clean(description?.location?.description)
        let words = Self.contentWords(seen ?? "")
        let said = theirs.map { words.intersection(Self.contentWords($0)).count * 2 >= words.count } ?? false
        let parts = [theirs, said ? nil : theirs == nil ? seen : seen?.uppercasedFirst].compactMap(\.self)
        return parts.isEmpty ? "" : ": " + parts.joined(separator: ". ")
    }

    /// " Place MAN on the wet asphalt, lit by soft overcast daylight.", or nothing.
    var ground: String {
        // The person's light wins: the image's would contradict it.
        let floor = Self.clean(description?.location?.floor)
        let light = (Self.clean(wish.light) ?? Self.clean(description?.location?.light)).map(Self.lit)
        guard floor != nil || light != nil else { return "" }
        let who = count == 1 ? name(1) : "everyone"
        guard let floor else { return " \(who.uppercasedFirst) is \(light ?? "")." }
        return " Place \(who) on the \(floor.lowercasedFirst)" + (light.map { ", \($0)" } ?? "") + "."
    }

    /// "lit by warm lamplight", or the person's own "lit like the original studio" as it is.
    static func lit(_ light: String) -> String {
        let light = light.replacing(/^(?i)light(?:ing)?\s*:\s*/, with: "").lowercasedFirst
        return light.firstMatch(of: /^(lit|lighted|illuminated)\b/) != nil ? light : "lit by " + light
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
    var uppercasedFirst: String { prefix(1).uppercased() + dropFirst() }
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
