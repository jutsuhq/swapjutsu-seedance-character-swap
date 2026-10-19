import Foundation
import Testing

@testable import SwapjutsuDescribe
@testable import SwapjutsuPrep

/// A model that answers from a script and records what it was asked.
final class ScriptedModel: VisionLanguageModel, @unchecked Sendable {
    let name: String
    let available: VisionModelAvailability
    let answer: @Sendable (String) throws -> String
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var _unloads = 0
    var prompts: [String] { lock.withLock { _prompts } }
    var unloads: Int { lock.withLock { _unloads } }

    init(
        _ name: String, available: VisionModelAvailability = .available,
        answer: @escaping @Sendable (String) throws -> String
    ) {
        (self.name, self.available, self.answer) = (name, available, answer)
    }

    func availability() async -> VisionModelAvailability { available }

    func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        return try answer(prompt)
    }

    func unload() async { lock.withLock { _unloads += 1 } }
}

@Suite struct DescriberTests {
    let input = DescribeInput(
        characters: [URL(filePath: "/c1.jpg")], location: URL(filePath: "/place.jpg"),
        keyframes: [
            .init(time: 0, image: URL(filePath: "/k0.jpg")), .init(time: 5.75, image: URL(filePath: "/k1.jpg")),
        ],
        beats: ["5.8 s: turns away from the camera"], seconds: 7)

    static func answer(_ prompt: String) -> String {
        if prompt.contains("character part") {
            return """
                ```json
                {"noun": "WOMAN", "pronoun": "her", "appearance": "young, red-haired", "wardrobe": ["white shirt", "raincoat"],
                 "traits": "red hair", "moving": "none"}
                ```
                """
        }
        if prompt.contains("location part") {
            return #"{"noun": "GARDEN", "description": "gravel", "floor": "path", "light": "soft"}"#
        }
        return #"Here: {"camera": "low-angle tracking", "beats": "stride, turn", "timed": "x"}"#
    }

    @Test func everyPartIsDescribedAndTheModelUnloaded() async throws {
        let model = ScriptedModel("Local") { Self.answer($0) }
        let description = try #require(await Describer(models: [model]).describe(input))
        #expect(
            description.characters == [
                .init(
                    noun: "WOMAN", pronoun: "her", appearance: "young, red-haired", wardrobe: "white shirt, raincoat",
                    traits: "red hair", moving: "")
            ])
        #expect(description.location == .init(noun: "GARDEN", description: "gravel", floor: "path", light: "soft"))
        #expect(description.motion == .init(camera: "low-angle tracking", beats: "stride, turn"))
        #expect(description.source == "Local")
        #expect(model.unloads == 1)
        // The tracker's moves and the keyframe times are in the beats prompt.
        #expect(model.prompts.last?.contains("5.8 s: turns away from the camera") == true)
        #expect(model.prompts.last?.contains("at 0.00, 5.75 s") == true)
    }

    /// An unavailable model is skipped, a refusal or an answer without JSON falls through to the next model.
    /// With several replaced performers the moves prompt asks each one's moves and gaze by where they stand, and
    /// a known description of the same characters is kept: only the moves are asked again.
    @Test func eachPerformerIsReadApartAndAKnownDescriptionKept() async throws {
        let model = ScriptedModel("Local") { prompt in
            #"{"camera": "static", "beats": "both talk", "moves_1": "0-2s steps forward", "gaze_1": "They look at the "#
                + #"floor.", "moves_2": "raises their hand", "gaze_2": "into the camera"}"#
        }
        var duo = input
        duo.characters.append(URL(filePath: "/c2.jpg"))
        duo.performers = ["on the left", "on the right"]
        let known = SceneDescription(characters: [.init(noun: "WOMAN"), .init(noun: "MAN")], source: "Earlier")
        duo.known = known
        let description = try #require(await Describer(models: [model]).describe(duo))
        #expect(model.prompts.count == 1)
        let prompt = try #require(model.prompts.first)
        #expect(prompt.contains("the one on the left, the one on the right"))
        #expect(prompt.contains(#""moves_2": "the moves of the performer on the right only"#))
        #expect(prompt.contains(#""gaze_1""#) && !prompt.contains(#""gaze":"#))
        #expect(description.characters == known.characters && description.source == "Earlier, Local")
        #expect(
            description.motion?.performers == [
                .init(beats: "steps forward", gaze: "at the floor"), .init(beats: "raises their hand", gaze: "into the camera"),
            ])
    }

    @Test func oneTargetsGazeIsAsked() async throws {
        let model = ScriptedModel("Local") { _ in #"{"camera": "static", "beats": "a wave", "gaze": "looking up"}"# }
        var single = input
        single.known = SceneDescription(characters: [.init(noun: "WOMAN")])
        let description = try #require(await Describer(models: [model]).describe(single))
        #expect(model.prompts.first?.contains(#""gaze": "where the performer looks"#) == true)
        #expect(description.motion?.gaze == "up" && description.motion?.performers == [])
    }

    @Test func refusalsAndUnavailableModelsFallThrough() async throws {
        let off = ScriptedModel("Off", available: .unavailable("not downloaded")) { _ in "" }
        let shy = ScriptedModel("Shy") { _ in "I'm sorry, I can't describe people in images." }
        let next = ScriptedModel("System") { Self.answer($0) }
        let lines = Lines()
        let description = try #require(
            await Describer(models: [off, shy, next]).describe(input) { lines.append($0) })
        #expect(description.characters.first?.noun == "WOMAN")
        #expect(description.source == "System")
        #expect(off.prompts.isEmpty && shy.prompts.count == 3)
        #expect(lines.all.contains("Off is unavailable: not downloaded"))
        #expect(lines.all.contains("Shy declined to describe character 1"))
        #expect(shy.unloads == 1 && next.unloads == 1 && off.unloads == 0)
    }

    @Test func noModelGivesNoDescription() async {
        let broken = ScriptedModel("Broken") { _ in throw VisionModelError.failed("out of memory") }
        #expect(await Describer(models: [broken]).describe(input) == nil)
        #expect(await Describer(models: []).describe(input) == nil)
    }

    @Test func parserFindsTheJSONAndDropsPlaceholders() {
        #expect(DescriptionParser.fields(#"x {"a": "Empty", "b": " ok "} y"#) == ["a": "", "b": "ok"])
        #expect(DescriptionParser.fields("no json") == nil)
        #expect(DescriptionParser.fields(#"{"a": "none"}"#) == nil)
        #expect(DescriptionParser.isRefusal("Sorry, I cannot help with that."))
        #expect(!DescriptionParser.isRefusal(#"{"noun": "sorry"}"#))
        // Cut off at the token limit: the complete pairs are kept.
        let cut =
            #"{"noun": "GIRL", "pronoun": "her", "appearance": "slim, \"red-haired\"", "wardrobe": "white, grey, gre"#
        #expect(
            DescriptionParser.fields(cut) == ["noun": "GIRL", "pronoun": "her", "appearance": #"slim, "red-haired""#])
    }

    @Test func motionLosesTheCameraPreambleAndCopiedTimes() {
        let motion = DescriptionParser.motion([
            "camera": "the camera is static, a full-length shot",
            "beats": "0.0-1.2s facing the camera, 5.8 s turns away, 6.5–7.0s final pose",
        ])
        #expect(motion.camera == "static, a full-length shot")
        #expect(motion.beats == "facing the camera, turns away, final pose")
        #expect(
            DescriptionParser.motion(["camera": "low-angle backward tracking shot"]).camera
                == "low-angle backward tracking shot")
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

/// The OpenAI-compatible provider's request and answer, against a stubbed server.
@Suite(.serialized) struct OpenAICompatibleTests {
    @Test func sendsTheImagesInlineAndReadsTheMessage() async throws {
        let image = FileManager.default.temporaryDirectory.appending(path: "describe-\(UUID()).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.reply = (200, #"{"choices": [{"message": {"content": "{\"noun\": \"CAT\"}"}}]}"#)
        let model = OpenAICompatibleVisionModel(
            base: try #require(URL(string: "http://localhost:1234/v1")), model: "qwen3-vl", key: "k",
            session: URLSession(configuration: configuration))
        let text = try await model.respond(to: "describe", images: [image], maxTokens: 50)
        #expect(text == #"{"noun": "CAT"}"#)
        let request = try #require(StubProtocol.last)
        #expect(request.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        // JSONSerialization escapes slashes; the decoded body has them back.
        let body = try #require(try JSONSerialization.jsonObject(with: StubProtocol.body) as? [String: Any])
        #expect(body["model"] as? String == "qwen3-vl")
        let content = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        #expect((content?.last?["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,/9j/")

        StubProtocol.reply = (401, #"{"error": "bad key"}"#)
        await #expect(throws: VisionModelError.self) { try await model.respond(to: "x", images: [], maxTokens: 5) }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var last: URLRequest?
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.last = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            Self.body = data
        } else {
            Self.body = request.httpBody ?? Data()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(filePath: "/"), statusCode: Self.reply.0, httpVersion: nil, headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data(Self.reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The shot is the pose tracker's framing, with the model's words for who is in it when they agree.
@Suite struct FramingTests {
    @Test func theMeasuredFramingWins() {
        #expect(DescriptionParser.shot(["shot": "full-body shot"], "waist-up shot") == "waist-up shot")
        #expect(DescriptionParser.shot(["shot": "Waist-up two-shot"], "waist-up shot") == "waist-up two-shot")
        #expect(DescriptionParser.shot(["shot": "full-body"], "full-body shot") == "full-body shot")
        #expect(PoseBeats.most([.full, .waist, .waist, .chest]) == .waist)
        #expect(PoseBeats.most([]) == nil)
        let input = DescribeInput(characters: [], keyframes: [.init(time: 0, image: URL(filePath: "/a.jpg"))],
            framing: "chest-up shot")
        #expect(DescriptionPrompts.beats(input).contains("measured the framing as a chest-up shot"))
    }
}

@Suite struct TraitTests {
    @Test func aPoseIsNotATrait() {
        #expect(
            DescriptionParser.looks("standing, facing camera, short curly red hair, hands by sides, yellow raincoat")
                == "short curly red hair, yellow raincoat")
        #expect(DescriptionParser.looks("standing, posture upright") == "")
    }
}

/// The person's prompt read by a model into the prompt's parts, text only, in whatever language they wrote it.
@Suite struct WishReadingTests {
    static let russian = "Замени парня в @Video1 на мужчину с @Image1. Он в серой куртке на молнии, застёгнутой."

    static let answer = """
        ```json
        {"characters": [{"performer": "the guy", "noun": "man", "pronoun": "His", "looks": "a grey zip-up jacket, zipped closed",
          "moving": "her hair moves as she turns", "kept": [], "notes": []},
          {"looks": "", "notes": ["He smiles at the end."]}],
         "place": "", "place_noun": "", "replaced": "", "beats": "", "camera": "", "notes": "none"}
        ```
        """

    @Test func theWishIsReadWithoutImages() async throws {
        let model = ScriptedModel("Local") { $0.contains("A person wrote this request") ? Self.answer : "no" }
        let input = DescribeInput(characters: [], wish: .init(text: Self.russian, people: 1, place: nil))
        let description = try #require(await Describer(models: [model]).describe(input))
        let request = try #require(description.request)
        #expect(request.text == Self.russian)
        #expect(request.reading.characters.count == 1)
        #expect(request.reading.characters[0].pronoun == "his")
        #expect(request.reading.characters[0].moving == "hair")
        // The second character the model made up is folded into the notes, not lost.
        #expect(request.reading.notes == ["He smiles at the end."])
        #expect(model.prompts.count == 1 && model.prompts[0].contains(Self.russian))
        #expect(!description.isDescribed)
    }

    /// `moving` holds only the parts that swing: the clause around them is cut, and an action read there goes to
    /// the moves.
    @Test func movingIsOnlyWhatSwings() throws {
        #expect(Wish.swinging("his robes, coat and beard flowing and whipping with the motion") == "robes, coat and beard")
        #expect(Wish.swinging("hair, long skirt and the hem of the coat") == "hair, long skirt and the hem of the coat")
        let answer = #"""
            {"characters": [{"performer": "the man", "noun": "girl", "looks": "",
            "moving": "throws the stacks of cash at the camera exactly like he does", "kept": [], "notes": []}],
            "beats": "", "notes": []}
            """#
        let wish = try #require(DescriptionParser.wish(answer, people: 1))
        #expect(wish.characters[0].moving == "")
        #expect(wish.beats == "throws the stacks of cash at the camera exactly like he does")
    }

    @Test func aWishNoModelReadIsLeft() async {
        let model = ScriptedModel("Local") { _ in "I can't." }
        let input = DescribeInput(characters: [], wish: .init(text: "x", people: 1, place: nil))
        #expect(await Describer(models: [model]).describe(input) == nil)
        #expect(DescriptionParser.wish(#"{"characters": [], "notes": []}"#, people: 1) == nil)
    }

    @Test func theWishPromptNamesThePlaceAndAsksForEnglish() {
        let prompt = DescriptionPrompts.wish("Сделай дождь.", people: 2, place: 3)
        #expect(prompt.contains("@Image1 to @Image2 are the characters"))
        #expect(prompt.contains("@Image3 is the new place"))
        #expect(prompt.contains("write every part in English"))
        #expect(prompt.contains("Сделай дождь."))
        #expect(prompt.contains("with every detail they give of them (what they wear"))
    }
}
