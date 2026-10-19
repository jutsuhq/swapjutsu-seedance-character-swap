import Foundation
import SwapjutsuPrep

let usage = """
    usage: swapjutsu-prep <video> [--out <dir>] [--model <DepthAnythingV2SmallF16.mlpackage>]
                          [--target main|all|<id,id>] [--face-guide] [--no-review] [--keep-music]
                          [--max-seconds <4–30>] [--tracking-models <EdgeTAM folder>] [--no-tracking]
                          [--no-depth-smoothing] [--replace-background] [--no-hand-cue] [--no-occluders]
                          [--control depth|hybrid-hands|hybrid-body] [--matte-outline]

    Prepares a clip for Seedance character replacement on this Mac: finds shots and people, keeps each person's
    identity across cuts, and writes control.mp4 (target painted with depth over the original, vocals pitched up),
    mask.mp4, review.mp4, identities/*.jpg and manifest.json into --out (default: <video name>-prep next to the
    video). --replace-background paints everything but the targets with grey depth instead of the original, for a
    new place from the image after the characters. --face-guide draws the target's face landmarks over the depth
    where the face is at least 3 % of the frame height; Seedance may draw them into the face. --no-hand-cue keeps
    the hands at the depth the model gave them instead of lifting them nearer (`Tuning.handLift`). --control
    hybrid-hands shows the targets' real hands in place of their depth, tracked through the shot from Vision's hand
    pose; hybrid-body shows the whole target as filmed but for the head, which stays colored depth. The targets are
    painted inside a silhouette drawn from their skeleton and box, not their clothes' outline; --matte-outline
    paints the matte as before.

    Target masks are tracked through each shot with EdgeTAM from --tracking-models (default
    $SWAPJUTSU_TRACKING_MODELS, else Models/EdgeTAM); --no-tracking, or no models there, keeps Vision's masks.
    --no-occluders paints objects in front of the target (a steering wheel, a mic) with it, as before #56.
    """

nonisolated func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

/// Strict parse: an unknown flag, a missing value or a malformed number stops here with the reason.
struct Arguments {
    var video: URL
    var out: URL
    var model: String
    /// Nil with --no-tracking.
    var trackingModels: String?
    var options = PrepOptions()

    init(_ arguments: [String]) throws {
        var rest = arguments[...]
        var positional: [String] = []
        var out: String?
        var model: String?
        var trackingModels: String?
        var tracking = true
        var options = PrepOptions()
        while let argument = rest.popFirst() {
            switch argument {
            case "--out": out = try Self.value(argument, from: &rest)
            case "--model": model = try Self.value(argument, from: &rest)
            case "--tracking-models": trackingModels = try Self.value(argument, from: &rest)
            case "--no-tracking": tracking = false
            case "--target": options.target = try Self.target(try Self.value(argument, from: &rest))
            case "--max-seconds":
                let text = try Self.value(argument, from: &rest)
                guard let seconds = Double(text), seconds.isFinite else {
                    throw PrepError.invalidOption("--max-seconds takes a number, got \(text)")
                }
                options.tuning.maxSeconds = seconds
            case "--face-guide": options.faceGuide = true
            case "--no-review": options.review = false
            case "--keep-music": options.tuning.isolateVoice = false
            case "--no-depth-smoothing": options.tuning.depthSmoothing = 0
            case "--replace-background": options.background = .replace
            case "--no-hand-cue": options.tuning.handLift = 0
            case "--no-occluders": options.tuning.occluders.enabled = false
            case "--matte-outline": options.matteOutline = true
            case "--control":
                let value = try Self.value(argument, from: &rest)
                guard let mode = ControlMode(rawValue: value) else {
                    throw PrepError.invalidOption("--control takes depth, hybrid-hands or hybrid-body, not \(value)")
                }
                options.control = mode
            case "-h", "--help":
                say(usage)
                exit(0)
            default:
                guard !argument.hasPrefix("-") else { throw PrepError.invalidOption("unknown option \(argument)") }
                positional.append(argument)
            }
        }
        guard positional.count == 1 else { throw PrepError.invalidOption("give exactly one video") }
        try options.validate()
        video = URL(fileURLWithPath: positional[0])
        self.out = URL(fileURLWithPath: out ?? video.deletingPathExtension().path + "-prep")
        self.model =
            model ?? ProcessInfo.processInfo.environment["SWAPJUTSU_DEPTH_MODEL"]
            ?? "Models/DepthAnythingV2SmallF16.mlpackage"
        self.trackingModels =
            tracking
            ? trackingModels ?? ProcessInfo.processInfo.environment["SWAPJUTSU_TRACKING_MODELS"] ?? "Models/EdgeTAM"
            : nil
        self.options = options
    }

    /// The value after `flag`.
    private static func value(_ flag: String, from rest: inout ArraySlice<String>) throws -> String {
        guard let next = rest.popFirst(), !next.hasPrefix("--") else {
            throw PrepError.invalidOption("\(flag) needs a value")
        }
        return next
    }

    static func target(_ text: String) throws -> TargetSelection {
        switch text {
        case "main": return .main
        case "all": return .all
        default:
            let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            let ids = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !ids.isEmpty, ids.count == parts.count, ids.allSatisfy({ $0 >= 1 }) else {
                throw PrepError.invalidOption("--target is main, all or person numbers like 1,3; got \(text)")
            }
            return .ids(ids)
        }
    }
}

let arguments: Arguments
do { arguments = try Arguments(Array(CommandLine.arguments.dropFirst())) } catch {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    fail("\(error)")
}
guard FileManager.default.fileExists(atPath: arguments.video.path) else { fail("no file at \(arguments.video.path)") }
guard FileManager.default.fileExists(atPath: arguments.model) else {
    fail("depth model not found at \(arguments.model). Run scripts/fetch-models.sh.")
}

var stages = PrepStages.standard(
    tuning: arguments.options.tuning, depthModel: URL(fileURLWithPath: arguments.model),
    trackingModels: arguments.trackingModels.map { URL(fileURLWithPath: $0) })
if let folder = arguments.trackingModels, !FileManager.default.fileExists(atPath: folder) {
    // The run goes on with Vision's masks; the manifest says why.
    stages.tracking = { throw PrepError.model("tracking models not found at \(folder); run scripts/fetch-models.sh") }
}

do {
    let manifest = try await Pipeline(options: arguments.options, stages: stages, log: say)
        .run(video: arguments.video, output: arguments.out)
    say("Shots: \(manifest.shots.count)  People: \(manifest.identities.count)  Targets: \(manifest.targets)")
    let q = manifest.quality
    say(
        String(
            format: "Presence %.2f  mask stability %.3f  face coverage %.2f  depth flicker %.4f",
            q.targetPresence, q.maskStability, q.faceCoverage, q.depthFlicker))
    if let tracking = manifest.tracking {
        let kept = tracking.shots.filter { $0.fallback == nil }.count
        say(
            tracking.tracker.map { "Masks: \($0) in \(kept) of \(tracking.shots.count) target shots" }
                ?? "Masks: Vision")
    }
    if let guide = manifest.faceGuide {
        say(
            String(
                format: "Face guide: lines on %d frames (faces from %.1f %% of the height)", guide.frames,
                guide.minFaceHeight * 100))
    }
    for w in manifest.warnings { say("warning: \(w)") }
    say(String(format: "Done in %.1f s → %@", manifest.timings["total"] ?? 0, arguments.out.path))
} catch {
    fail("\(error)", code: 1)
}
