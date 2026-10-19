import Foundation
import SwapjutsuPrep

/// What `Describer` looks at: the character images in upload order, the new place when the background is replaced,
/// the clip's keyframes with the moves `PoseBeats` timed, and the person's own prompt to read.
public struct DescribeInput: Sendable, Equatable {
    public var characters: [URL]
    public var location: URL?
    /// Keyframes in time order, with their time in seconds.
    public var keyframes: [Keyframe]
    /// `PoseBeats.lines`.
    public var beats: [String]
    /// `PoseBeats.framing`'s label, which the description's shot takes over a model's guess.
    public var framing: String?
    public var seconds: Double
    /// The person's prompt, read into the service prompt's parts; nil to leave it.
    public var wish: WishInput?
    /// Where each replaced performer stands ("on the left", …), in image order, when several are replaced and prep
    /// told them apart (`ServicePrompt.places`); each gets their own moves and gaze. Empty otherwise.
    public var performers: [String] = []
    /// A description of the same characters and place, kept: only the moves, and a prompt it hasn't read, are
    /// asked again.
    public var known: SceneDescription?

    /// The person's prompt, with the number of characters and the `@Image` number of the new place it is about.
    public struct WishInput: Sendable, Equatable {
        public var text: String
        public var people: Int
        public var place: Int?

        public init(text: String, people: Int, place: Int?) {
            (self.text, self.people, self.place) = (text, people, place)
        }
    }

    public struct Keyframe: Sendable, Equatable {
        public var time: Double
        public var image: URL

        public init(time: Double, image: URL) {
            self.time = time
            self.image = image
        }
    }

    public init(
        characters: [URL], location: URL? = nil, keyframes: [Keyframe] = [], beats: [String] = [], seconds: Double = 0,
        wish: WishInput? = nil, framing: String? = nil
    ) {
        (self.characters, self.location, self.keyframes, self.beats, self.seconds) =
            (characters, location, keyframes, beats, seconds)
        (self.wish, self.framing) = (wish, framing)
    }
}

/// The harness around any `VisionLanguageModel`: it writes the prompts (`DescriptionPrompts`), asks the models in
/// order, reads their JSON answers and falls through to the next model when one is unavailable, fails, refuses or
/// answers something that isn't the JSON asked for. A part no model could describe is left out, and the prompt keeps
/// its wording without it. Every model asked is unloaded at the end.
public struct Describer: Sendable {
    public let models: [any VisionLanguageModel]
    public var maxTokens = 700

    public init(models: [any VisionLanguageModel]) { self.models = models }

    /// Describes every part of `input`; nil when no model described anything. `log` gets a line per step.
    public func describe(_ input: DescribeInput, log: @Sendable (String) -> Void = { _ in }) async -> SceneDescription?
    {
        var asked: [any VisionLanguageModel] = []
        let description = await describe(input, asked: &asked, log: log)
        for model in asked { await model.unload() }
        return description
    }

    private func describe(
        _ input: DescribeInput, asked: inout [any VisionLanguageModel], log: @Sendable (String) -> Void
    ) async -> SceneDescription? {
        var usable: [any VisionLanguageModel] = []
        for model in models {
            switch await model.availability() {
            case .available: usable.append(model)
            case .unavailable(let reason): log("\(model.name) is unavailable: \(reason)")
            }
        }
        guard !usable.isEmpty else { return nil }
        func ask<T>(
            _ prompt: String, _ images: [URL], what: String, read: (String) -> T?
        ) async -> (fields: T, by: String)? {
            for model in usable {
                if !asked.contains(where: { $0.name == model.name }) { asked.append(model) }
                log("Describing \(what) with \(model.name)")
                do {
                    let answer = try await model.respond(to: prompt, images: images, maxTokens: maxTokens)
                    if let fields = read(answer) { return (fields, model.name) }
                    log(
                        DescriptionParser.isRefusal(answer)
                            ? "\(model.name) declined to describe \(what)"
                            : "\(model.name) gave no JSON for \(what): \(answer.prefix(160))")
                } catch {
                    log("\(model.name) failed on \(what): \(error.localizedDescription)")
                }
            }
            return nil
        }
        func ask(_ prompt: String, _ images: [URL], what: String) async -> (fields: [String: String], by: String)? {
            await ask(prompt, images, what: what, read: DescriptionParser.fields)
        }
        var description = input.known ?? SceneDescription()
        var sources: [String] = []
        for (index, image) in input.characters.enumerated() where input.known == nil {
            guard let answer = await ask(DescriptionPrompts.character, [image], what: "character \(index + 1)") else {
                description.characters.append(.init(noun: ""))
                continue
            }
            description.characters.append(DescriptionParser.character(answer.fields))
            sources.append(answer.by)
        }
        if input.known == nil, let location = input.location,
            let answer = await ask(DescriptionPrompts.location, [location], what: "the place")
        {
            description.location = DescriptionParser.location(answer.fields)
            sources.append(answer.by)
        }
        if !input.keyframes.isEmpty,
            let answer = await ask(
                DescriptionPrompts.beats(input, wardrobe: description.characters.first?.wardrobe ?? ""),
                input.keyframes.map(\.image), what: "the moves")
        {
            description.motion = DescriptionParser.motion(answer.fields, performers: input.performers.count)
            if let framing = input.framing { description.motion?.shot = DescriptionParser.shot(answer.fields, framing) }
            sources.append(answer.by)
        }
        if let wish = input.wish, !wish.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            input.known?.request?.text != wish.text,
            let answer = await ask(
                DescriptionPrompts.wish(wish.text, people: wish.people, place: wish.place), [], what: "your prompt",
                read: { DescriptionParser.wish($0, people: wish.people)?.covering(wish.text) })
        {
            description.request = .init(text: wish.text, reading: answer.fields)
            sources.append(answer.by)
        }
        guard !sources.isEmpty else { return nil }
        let earlier = input.known.map { $0.source.split(separator: ", ").map(String.init) } ?? []
        description.source = Array(NSOrderedSet(array: earlier + sources)).compactMap { $0 as? String }.joined(separator: ", ")
        return description
    }
}

/// Reads a model's answer: the first JSON object in it (code fences and chatter around it are skipped), its values
/// as text, with placeholder answers ("empty", "none") taken as nothing.
public enum DescriptionParser {
    public static func fields(_ answer: String) -> [String: String]? {
        guard let start = answer.firstIndex(of: "{") else { return nil }
        let end = answer.lastIndex(of: "}").flatMap { $0 > start ? $0 : nil }
        guard let end,
            let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any]
        else { return salvaged(String(answer[start...])) }
        var fields: [String: String] = [:]
        for (key, value) in object {
            let text: String =
                switch value {
                case let text as String: text
                case let list as [Any]: list.map { "\($0)" }.joined(separator: ", ")
                case is NSNull: ""
                default: "\(value)"
                }
            fields[key.lowercased()] = clean(text)
        }
        return fields.values.contains { !$0.isEmpty } ? fields : nil
    }

    /// The complete `"key": "text"` pairs of an object cut off or broken, as a small model leaves it when it runs
    /// to the token limit; nil with fewer than two.
    static func salvaged(_ text: String) -> [String: String]? {
        let pair = /"([A-Za-z_0-9]+)"\s*:\s*"((?:[^"\\]|\\.)*)"/
        var fields: [String: String] = [:]
        for match in text.matches(of: pair) {
            let value = String(match.2).replacingOccurrences(of: "\\\"", with: "\"")
            fields[String(match.1).lowercased()] = clean(value)
        }
        return fields.count >= 2 && fields.values.contains { !$0.isEmpty } ? fields : nil
    }

    static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["empty", "none", "n/a", "na", "null", "none visible", "-"].contains(trimmed.lowercased()) ? "" : trimmed
    }

    /// An answer without JSON that says it won't, or can't, describe the image.
    public static func isRefusal(_ answer: String) -> Bool {
        let lower = answer.lowercased()
        return fields(answer) == nil
            && ["can't", "cannot", "unable to", "not able to", "sorry", "i won't", "i will not"].contains {
                lower.contains($0)
            }
    }

    static func character(_ f: [String: String]) -> SceneDescription.Character {
        .init(
            noun: f["noun"] ?? "", pronoun: f["pronoun"] ?? "their", appearance: f["appearance"] ?? "",
            wardrobe: f["wardrobe"] ?? "", traits: looks(f["traits"] ?? ""), moving: f["moving"] ?? "",
            outer: f["outer"].flatMap { $0.isEmpty ? nil : $0 },
            outerState: f["outer_state"].flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A model's reading of the person's prompt (`DescriptionPrompts.wish`), sized to `people` characters; nil
    /// when the answer has no such object or nothing in it.
    public static func wish(_ answer: String, people: Int) -> Wish? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), end > start,
            let object = try? JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any]
        else { return nil }
        let text = { (value: Any?) -> String in
            switch value {
            case let text as String: clean(text)
            case let list as [Any]: clean(list.map { "\($0)" }.joined(separator: ", "))
            default: ""
            }
        }
        let list = { (value: Any?) -> [String] in
            switch value {
            case let list as [Any]: list.map { clean("\($0)") }.filter { !$0.isEmpty }
            case let text as String: clean(text).isEmpty ? [] : [clean(text)]
            default: []
            }
        }
        let scene = [object["beats"], object["camera"], object["place"], object["light"]].map(text)
        var actions: [String] = []
        let characters = (object["characters"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.map { c in
            // What it does, read as what swings ("throws the cash at the camera"), goes to the moves.
            var moving = Wish.swinging(text(c["moving"]))
            if Wish.isAction(moving) { (actions, moving) = (actions + [moving], "") }
            return Wish.Character(
                performer: text(c["performer"]), noun: text(c["noun"]), pronoun: text(c["pronoun"]).lowercased(),
                looks: text(c["looks"]), moving: moving, kept: list(c["kept"]),
                notes: unsaid(list(c["notes"]), scene + [text(c["looks"])]))
        }
        let beats = ([text(object["beats"])] + actions).filter { !$0.isEmpty }.joined(separator: ", ")
        let wish = Wish(
            characters: characters, place: text(object["place"]), placeNoun: text(object["place_noun"]),
            replacedSetting: text(object["replaced"]), beats: beats, camera: text(object["camera"]),
            light: text(object["light"]),
            keptSetting: list(object["kept_setting"]),
            notes: unsaid(list(object["notes"]), scene + characters.map(\.looks))
        ).sized(people)
        return wish.isEmpty ? nil : wish
    }

    /// The notes without the clauses (between semicolons) that repeat a part the reading already has: a small model
    /// copies a sentence whole into the notes when part of it went elsewhere.
    static func unsaid(_ notes: [String], _ said: [String]) -> [String] {
        let said = said.map { $0.lowercased() }.filter { $0.count >= 20 }
        return notes.compactMap { note in
            let rest = note.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { clause in !said.contains { clause.lowercased().contains($0) } }
            return rest.isEmpty ? nil : rest.joined(separator: "; ")
        }
    }

    /// The traits without the pose a model sometimes lists instead ("standing, facing camera, hands by sides"): the
    /// prompt renders the traits in every frame, and a pose there would fight the performer's moves.
    static func looks(_ traits: String) -> String {
        let pose =
            /(?i)\b(stand|sit|facing|faces|hands?\b|arms?\b|posture|pose|shoulders? back|looking|upright|leaning)/
        return traits.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.firstMatch(of: pose) == nil }.joined(separator: ", ")
    }

    static func location(_ f: [String: String]) -> SceneDescription.Location {
        .init(
            noun: f["noun"] ?? "", description: f["description"] ?? "", floor: f["floor"] ?? "", light: f["light"] ?? ""
        )
    }

    /// The tracker's `framing`, with the model's words for who is in it when they agree on the framing ("waist-up
    /// two-shot" for "waist-up shot").
    static func shot(_ f: [String: String], _ framing: String) -> String {
        let said = (f["shot"] ?? "").lowercased()
        let first = framing.split(separator: " ").first.map(String.init) ?? framing
        return said.contains(first) && said.count > framing.count ? said : framing
    }

    /// The camera without a leading "the camera is", and the beats without the times a model copied into them:
    /// the prompt reads "the same <camera>" and "matched beat-for-beat to the original moves (<beats>)".
    static func motion(_ f: [String: String], performers: Int = 0) -> SceneDescription.Motion {
        let camera = (f["camera"] ?? "").replacing(/^(?i)(the\s+)?(camera\s+(is\s+)?)?(a\s+|an\s+)?/, with: "")
        let answer = (f["feet"] ?? "").lowercased()
        // swiftlint:disable:next discouraged_optional_boolean
        let feet: Bool? = answer.hasPrefix("y") ? true : answer.hasPrefix("n") ? false : nil
        let each = performers > 1 ? (1...performers).map { k in
            SceneDescription.Motion.Performer(beats: untimed(f["moves_\(k)"]), gaze: gaze(f["gaze_\(k)"]))
        } : []
        return .init(
            camera: camera, beats: untimed(f["beats"]), shot: f["shot"] ?? "", scene: f["scene"] ?? "",
            props: f["props"] ?? "", text: f["text"] ?? "", feet: feet, gaze: gaze(f["gaze"]), performers: each)
    }

    /// Beats without the times a model copied into them.
    static func untimed(_ beats: String?) -> String {
        (beats ?? "").replacing(/\b\d+(\.\d+)?\s*(-|–)?\s*(\d+(\.\d+)?)?\s*s\b:?\s*/, with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "at the person beside them" from "They look at the person beside them.": the prompt reads "WOMAN looks
    /// <gaze>".
    static func gaze(_ text: String?) -> String {
        (text ?? "").replacing(/^(?i)\s*((the\s+)?performer|they|their\s+eyes|eyes|gaze)?\s*(is\s+)?(looking|looks?|gazing|gazes?|directed)?\s*/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
    }
}
