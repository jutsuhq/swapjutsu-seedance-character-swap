// Needs the MLX trait (Package.swift), on by default.
#if MLX
import Foundation
import SwapjutsuDescribe
import SwapjutsuMLX
import SwapjutsuPrep

// As in the app, the model answers from a child process of this executable, which an MLX error ends instead of this one.
if await MLXVisionBackend.serveIfWorker() { exit(0) }

let usage = """
    usage: swapjutsu-describe --video <clip> --character <image>… [--location <image>]
                              [--model <folder>] [--download <repo>] [--system] [--out <dir>]
                              [--wish <prompt.txt>] [--save <description.json>] [--shots <n>]
                              [--manifest <manifest.json>]
           swapjutsu-describe --video <clip> --character <image>… [--location <image>] --replay <answers.json>
           swapjutsu-describe --wish <prompt.txt> [--people <n>] [--location <image>] [--model <folder>] [--system]

    Describes the characters, the new place and the clip's moves as the app does before prep, and prints the
    description as JSON and the service prompt it fills. The models are asked in order: --model (an MLX model
    folder; --download <repo> fetches a Hugging Face repository into it first), then Apple's system model with
    --system. --out keeps the keyframes (default: a temporary folder).

    --replay answers with a recorded model's answers (a JSON array of strings, in the order the parts are asked:
    the characters, the place, the moves, the prompt) through the same parsing, and prints the prompt with and
    without them.

    --wish reads the person's prompt from a file into the prompt's parts, as the app does; --save writes the
    description, with that reading, as JSON. Without --video only the prompt is read, for --people characters
    (default: the --character count, else 1), and the service prompt it fills is printed. --shots gives the
    number of shots prep finds in the clip (default 1), which the app's prompt keeps cut for cut. --manifest takes
    the service prompt's brief from prep's manifest (people's places, shots, length, vocals), as the app does.
    """

func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

var video: URL?, characters: [URL] = [], location: URL?, folder: URL?, repo: String?, system = false
var replay: URL?, wishFile: URL?, save: URL?, people: Int?, shots = 1, manifest: URL?
var out = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-describe-\(UUID().uuidString)")
var rest = CommandLine.arguments.dropFirst()
while let arg = rest.popFirst() {
    func value() -> String {
        guard let value = rest.popFirst() else { fail("\(arg) needs a value\n\(usage)") }
        return value
    }
    switch arg {
    case "--video": video = URL(filePath: value())
    case "--character": characters.append(URL(filePath: value()))
    case "--location": location = URL(filePath: value())
    case "--model": folder = URL(filePath: value(), directoryHint: .isDirectory)
    case "--download": repo = value()
    case "--system": system = true
    case "--replay": replay = URL(filePath: value())
    case "--wish": wishFile = URL(filePath: value())
    case "--save": save = URL(filePath: value())
    case "--people":
        guard let n = Int(value()), n > 0 else { fail(usage) }
        people = n
    case "--shots":
        guard let n = Int(value()), n > 0 else { fail(usage) }
        shots = n
    case "--manifest": manifest = URL(filePath: value())
    case "--out": out = URL(filePath: value(), directoryHint: .isDirectory)
    default: fail(usage)
    }
}
let wish = try wishFile.map { try String(contentsOf: $0, encoding: .utf8) } ?? ""
guard let video, !characters.isEmpty else {
    guard !wish.isEmpty else { fail(usage) }
    // The prompt alone, read as the app reads it when it changed after the clip was described.
    let count = people ?? max(1, characters.count)
    let input = DescribeInput(
        characters: [], wish: .init(text: wish, people: count, place: location == nil ? nil : count + 1))
    let models: [any VisionLanguageModel] =
        (folder.map { [MLXVisionBackend(worker: Bundle.main.executableURL).model(in: $0, name: $0.lastPathComponent)] }
            ?? []) + (system ? [SystemVisionModel()] : [])
    let read = await Describer(models: models).describe(input) { say($0) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let read {
        let json = try encoder.encode(read)
        say(String(decoding: json, as: UTF8.self))
        if let save { try json.write(to: save) }
    } else {
        say("no model read the prompt; it goes in whole")
    }
    say(
        ServicePrompt(people: count, background: location == nil ? .keep : .replace).text(description: read, wish: wish)
    )
    exit(0)
}

let clock = ContinuousClock()
let started = clock.now
var models: [any VisionLanguageModel] = []
if let folder {
    let backend = MLXVisionBackend(worker: Bundle.main.executableURL)
    if let repo {
        say("downloading \(repo)")
        _ = try await backend.download(repo: repo, revision: "main", into: folder) { _ in }
    }
    models.append(backend.model(in: folder, name: folder.lastPathComponent))
}
if system { models.append(SystemVisionModel()) }
if let replay {
    let answers = try JSONDecoder().decode([String].self, from: Data(contentsOf: replay))
    models.append(Replay(answers: answers))
}
var input = try await DescribeInput.make(video: video, characters: characters, location: location, folder: out)
let brief = try manifest.flatMap { try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: $0)).seedance.brief }
if let places = brief?.places, places.count == characters.count { input.performers = places }
if !wish.isEmpty {
    input.wish = .init(text: wish, people: characters.count, place: location == nil ? nil : characters.count + 1)
}
say("beats in \(clock.now - started): \(input.beats.joined(separator: "; "))")
let describing = clock.now
let description = await Describer(models: models).describe(input) { say($0) }
say("described in \(clock.now - describing)")
guard let description else { fail("no model described anything") }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let json = try encoder.encode(description)
say(String(decoding: json, as: UTF8.self))
if let save { try json.write(to: save) }
let service =
    brief
    ?? ServicePrompt(
        people: characters.count, background: location == nil ? .keep : .replace, shots: shots, seconds: input.seconds)
if replay != nil { say(service.text(wish: wish) + "\n") }
say(service.text(description: description, wish: wish))

/// A recorded model: its answers in the order they were asked.
final class Replay: VisionLanguageModel, @unchecked Sendable {
    let name = "Replay"
    private var answers: [String]

    init(answers: [String]) { self.answers = answers }

    func availability() async -> VisionModelAvailability { .available }
    func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String {
        answers.isEmpty ? "" : answers.removeFirst()
    }
    func unload() async {}
}
#else
    import Foundation

    FileHandle.standardError.write(Data("error: swapjutsu-describe is built without the MLX trait\n".utf8))
    exit(2)
#endif
