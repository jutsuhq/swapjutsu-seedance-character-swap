import Foundation
import Observation
import SwapjutsuPrep

/// Who prep replaces.
enum PrepTarget: String, CaseIterable, Hashable, Codable, Sendable { case main, all }

/// A part of the source, in seconds; Seedance edits 4–30 s.
struct ClipRange: Codable, Hashable, Sendable {
    var start: Double
    var end: Double

    var duration: Double { end - start }

    /// "00:06.0 – 00:18.5".
    var text: String { "\(Timecode.text(start)) – \(Timecode.text(end))" }
}

enum Timecode {
    /// "01:05.3".
    /// Any Double: an agent's range is whatever number JSON holds, and `Int(_:)` traps on nan or past `Int.max`, so
    /// a time is clamped to 0 – 99:59:59 first.
    static func text(_ seconds: Double) -> String {
        let tenths = Int((min(seconds.isNaN ? 0 : max(0, seconds), 359_999.9) * 10).rounded())
        let minutes = tenths / 600
        let rest = Double(tenths % 600) / 10
        return String(format: "%02d:%04.1f", minutes, rest)
    }
}

/// Everything a clip is made from. It starts as a copy of the draft; the characters, the prompt and the prep options
/// are then edited on the clip itself. Once prep starts, `source` and `references` point at copies inside the job
/// folder (`JobFiles.adopt`, `JobFiles.addCharacter`), the source already cut to `range`.
struct JobSpec: Codable, Sendable {
    var title: String
    var source: URL
    var references: [URL]
    var prompt: String
    var target: PrepTarget
    var faceGuide: Bool
    /// Character images go to Seedance cut out onto plain grey (`JobFiles.uploadable`).
    var removeBackground = false
    /// Prep paints everything but the targets with grey depth (`BackgroundMode.replace`), and `background` is the
    /// place Seedance puts there, sent after the characters.
    var replaceBackground = false
    /// The new place, `@Image<targets + 1>`; only sent while the manifest says the background is replaced.
    var background: URL?
    var model: GenerationModel
    /// The part of the original clip this job is about; `nil` for the whole clip.
    var range: ClipRange?
    /// People prep replaces by their ids (`Manifest.Identity.id`), instead of `target`: an agent's pick, or one made
    /// person by person in Create (`ReplaceChoice`).
    var targetIDs: [Int]?
    /// What a vision model (`VisionModels`), or the person, says the characters, the place and the moves are: the
    /// entity, appearance and beat parts of the service prompt. Written before prep, editable on the clip.
    var description: SceneDescription?
    /// The images a model's `description` read (`JobStore.describedInputs`), so a clip whose characters or place
    /// changed since is described again; empty when it read none, as prep before any character; nil before it was
    /// recorded.
    var describedFrom: [String]?
    /// The `description` is the person's own (or their choice of none), never replaced on its own.
    var describedByPerson: Bool?
    /// Who each image replaces (`CharacterBinding`), set once the person or an agent assigns one on a prepared clip.
    /// Nil in jobs saved before, and until then: the replaced people take the images in order (`cast(for:)`).
    var cast: [CharacterBinding]?
    /// The angle a view in `cast` shows its character from, by the image's file name, when it was added or drawn
    /// for that angle; a view without one is "another view" in the prompt.
    var viewAngles: [String: CharacterAngle]?
    /// What paints the targets in the control video; nil: colored depth.
    var control: ControlMode?

    var options: PrepOptions {
        var options = PrepOptions()
        options.target = targetIDs.map { .ids($0) } ?? (target == .all ? .all : .main)
        options.faceGuide = faceGuide
        options.background = replaceBackground ? .replace : .keep
        options.control = control ?? .depth
        return options
    }
}

extension JobSpec {
    /// Jobs saved before `removeBackground` or `replaceBackground` existed decode with them off, before `cast` with
    /// the images in order, and without a description, view angles or a hybrid control.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        source = try c.decode(URL.self, forKey: .source)
        references = try c.decode([URL].self, forKey: .references)
        prompt = try c.decode(String.self, forKey: .prompt)
        target = try c.decode(PrepTarget.self, forKey: .target)
        faceGuide = try c.decode(Bool.self, forKey: .faceGuide)
        removeBackground = try c.decodeIfPresent(Bool.self, forKey: .removeBackground) ?? false
        replaceBackground = try c.decodeIfPresent(Bool.self, forKey: .replaceBackground) ?? false
        background = try c.decodeIfPresent(URL.self, forKey: .background)
        model = try c.decode(GenerationModel.self, forKey: .model)
        range = try c.decodeIfPresent(ClipRange.self, forKey: .range)
        targetIDs = try c.decodeIfPresent([Int].self, forKey: .targetIDs)
        description = try c.decodeIfPresent(SceneDescription.self, forKey: .description)
        describedFrom = try c.decodeIfPresent([String].self, forKey: .describedFrom)
        describedByPerson = try c.decodeIfPresent(Bool.self, forKey: .describedByPerson)
        cast = try c.decodeIfPresent([CharacterBinding].self, forKey: .cast)
        viewAngles = try c.decodeIfPresent([String: CharacterAngle].self, forKey: .viewAngles)
        control = try c.decodeIfPresent(ControlMode.self, forKey: .control)
    }
}

extension JobSpec {
    /// The angle the image at `index` was added or drawn for, if any.
    func angle(of index: Int) -> CharacterAngle? {
        references.indices.contains(index) ? viewAngles?[references[index].lastPathComponent] : nil
    }
}

/// One clip: prepared once on the Mac, then rendered by Seedance as often as the person likes. Every change worth
/// keeping is written to `job.json` in its folder (`JobRecord`), so a quit or crash never loses a paid request.
@MainActor
@Observable
final class Job: Identifiable {
    /// Prep, on this Mac. Renders have their own stages.
    enum Stage: String, Codable, Equatable {
        case waiting, preparing, prepared, failed, canceled

        var isActive: Bool { self == .waiting || self == .preparing }
    }

    let id: UUID
    let created: Date
    private(set) var spec: JobSpec
    let output: URL
    var stage = Stage.waiting
    /// The latest prep line, or why prep failed.
    var detail = ""
    var manifest: Manifest?
    /// Counts the preps that finished: prep again rewrites `control.mp4`, `prepared.mp4` and `mask.mp4` in place, and
    /// a render made from an earlier one says so (`RenderInputSnapshot.prepRevision`).
    var prepRevision = 0
    /// A description asked for on the clip (`JobStore.describe`) is on its way or waiting for prep to finish.
    var isDescribing = false
    /// Counts the changes to the description and whose it is, in memory only: a model's description started at one
    /// revision is dropped when the person (or anything else) changed it before the model answered.
    private(set) var descriptionRevision = 0
    /// Oldest first.
    var renders: [Render] = []
    /// The agent that started the clip, when one did.
    var origin: JobOrigin?

    var title: String { spec.title }
    var source: URL { spec.source }
    var model: GenerationModel { spec.model }
    var control: URL { output.appending(path: "control.mp4") }
    /// The source as prep read it, with its soundtrack: what Wan 2.2 Animate replaces the person in.
    var prepared: URL { output.appending(path: "prepared.mp4") }
    /// The replaced people's grown matte, white on black, frame for frame with `prepared`.
    var mask: URL { output.appending(path: "mask.mp4") }
    var review: URL { output.appending(path: "review.mp4") }
    var recordURL: URL { output.appending(path: "job.json") }

    /// How long the clip is: the range, else what prep measured.
    var duration: Double? {
        if let range = spec.range { return range.duration }
        guard let manifest, manifest.fps > 0 else { return nil }
        return Double(manifest.frames) / Double(manifest.fps)
    }

    /// How tall the targets' faces come out at `quality`, brows to chin (`Manifest.Quality.faceHeight`); nil
    /// before prep or without faces.
    func facePixels(at quality: RenderQuality) -> Int? {
        guard let manifest, let share = manifest.quality.faceHeight, manifest.width > 0, manifest.height > 0 else {
            return nil
        }
        let frameHeight =
            Double(quality.shortSide) * Double(manifest.height) / Double(min(manifest.width, manifest.height))
        return Int((share * frameHeight).rounded())
    }

    /// Faces shorter than this at 480p blur in a draft (a face under 50 px loses the character's look), so the
    /// render step offers 720p for them. Never the default: it costs more and skips the draft.
    static let smallFace = 64

    /// "00:06.0 – 00:18.5 · 12.5 s", or the length of a whole clip.
    var rangeText: String {
        let seconds = duration.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" }
        return [spec.range?.text, seconds].compactMap(\.self).joined(separator: " · ")
    }

    var isRendering: Bool { renders.contains { $0.stage.isActive } }
    var isActive: Bool { stage.isActive || isRendering }
    /// A stopped render whose request may still run and be charged (`Render.canDismiss`).
    var hasLiveRequest: Bool { renders.contains { !$0.canDismiss } }
    var finished: [Render] { renders.filter { $0.stage == .done } }

    /// Prepared, with an image for every replaced person (and the new place, when the background is replaced), and
    /// never sent to Seedance: the clips Create counts as waiting for a render.
    var isReady: Bool { stage == .prepared && renders.isEmpty && missingCharacters == 0 && !missingBackground }

    /// Who each replaced person becomes, in `Manifest.targets` order; empty until prep is done.
    var cast: [CharacterBinding] { spec.cast(for: manifest?.targets ?? []) }

    /// Replaced people prep found without a character image yet.
    var missingCharacters: Int { cast.filter { $0.character == nil }.count }

    /// Prep painted the background grey (`Manifest.background`), so the clip needs the image of the new place.
    var replacesBackground: Bool { manifest?.background == .replace }

    /// Prepared with a grey background and no image of the new place yet.
    var missingBackground: Bool { replacesBackground && spec.background == nil }

    /// Where each image goes in the render's `@Image` order, but for the face close-ups (`JobFiles.Layout`).
    var layout: JobFiles.Layout {
        JobFiles.Layout(
            cast: cast, references: spec.references.count, background: replacesBackground && spec.background != nil,
            angle: spec.angle(of:))
    }

    /// "Draft 2", "Final 1080p", "Wan 720p": the name of a render among this clip's renders of the same quality and
    /// generator.
    func name(of render: Render) -> String {
        let model = model(of: render)
        let same = renders.filter { $0.quality == render.quality && self.model(of: $0) == model }
        let title = model == .wan22Animate ? "Wan \(render.quality.resolution)" : render.quality.title
        guard render.quality.isDraft || same.count > 1, let index = same.firstIndex(where: { $0.id == render.id })
        else { return render.quality.isDraft ? "Draft" : title }
        return render.quality.isDraft ? "Draft \(index + 1)" : "\(title) (\(index + 1))"
    }

    /// The generator of `render`: its own, or the clip's for renders saved before there was a choice.
    func model(of render: Render) -> GenerationModel { render.model ?? spec.model }

    func render(_ id: UUID?) -> Render? { renders.first { $0.id == id } }

    /// The final rendered from `draft`, while it waits for the person, is on its way or done; other than `excluded`.
    func final(of draft: Render, excluding excluded: UUID? = nil) -> Render? {
        renders.last {
            $0.parent == draft.id && $0.id != excluded
                && ($0.stage.isActive || $0.stage == .done || $0.stage == .waiting)
        }
    }

    /// Another final of the same draft, which a retry of `render` would pay for twice.
    func otherFinal(than render: Render) -> Render? {
        self.render(render.parent).flatMap { final(of: $0, excluding: render.id) }
    }

    /// Renders an agent asked for with this `request_id`.
    func renders(forRequest requestID: String) -> [Render] {
        renders.filter { $0.origin?.requestID == requestID }
    }

    func resultURL(of render: Render) -> URL? { render.result.map { output.appending(path: $0) } }
    func generatedURL(of render: Render) -> URL? { render.generated.map { output.appending(path: $0) } }

    /// The prompt Seedance gets: the service prompt prep wrote for the people it found, with the person's own
    /// wishes folded into it (`Wish`), as Genjutsu sends one rewritten prompt instead of the person's after its own:
    /// replacing the service part would drop the depth, background and `@Video1` instructions Seedance needs, and
    /// both one after the other overlap. Its image numbers come from the upload layout (`JobFiles.Layout`): each
    /// person's character, the place, their views, the other references and the face close-ups. The service part
    /// is written from the manifest's brief (`ServicePrompt`), so each view and close-up is bound to its character
    /// and not taken for one more reference to place somewhere. A manifest from before the brief keeps its prompt,
    /// renumbered by `SeedancePrompt.bind`, with a sentence per close-up and the wishes after it.
    var effectivePrompt: String { effectivePrompt(with: spec.prompt) }

    func effectivePrompt(with wishes: String, uploads: JobFiles.Uploads? = nil) -> String {
        let uploads = uploads ?? JobFiles.Uploads(layout: layout)
        let wishes = wishes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let manifest else { return wishes }
        if let brief = manifest.seedance.brief {
            let faces = Dictionary(uploads.closeUps.map { ($0.character, $0.image) }) { first, _ in first }
            let views = Dictionary(grouping: uploads.views, by: \.character).mapValues {
                $0.map { ReferenceView(image: $0.image, angle: $0.angle) }
            }
            return brief.text(
                closeUps: faces, views: views, extras: uploads.extras, description: spec.description, wish: wishes)
        }
        let people = cast.indices.map { k in [k + 1] + uploads.views.filter { $0.character == k + 1 }.map(\.image) }
        let closeUps = uploads.closeUps.map {
            "@Image\($0.image) is a close-up of the face of the character in @Image\($0.character); match that face exactly."
        }
        let bound = SeedancePrompt.bind(manifest.seedance.prompt, people: people, images: uploads.layout.count)
        return [([bound] + closeUps).joined(separator: " "), wishes].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    init(spec: JobSpec, output: URL, id: UUID = UUID(), created: Date = Date()) {
        self.id = id
        self.created = created
        self.spec = spec
        self.output = output
    }

    /// A prep queued or about to write the job folder: the control video and mask may be replaced, or left half
    /// written when it fails, so no render sent before goes again on them.
    func startPrep() { prepRevision += 1 }

    /// The manifest of a prep that just finished, counted as a new prep revision.
    func takePrep(_ manifest: Manifest) {
        self.manifest = manifest
        prepRevision += 1
    }

    func edit(_ change: (inout JobSpec) -> Void) {
        let before = (spec.description, spec.describedByPerson)
        change(&spec)
        if spec.description != before.0 || spec.describedByPerson != before.1 { descriptionRevision += 1 }
    }

    func update(_ id: UUID, _ change: (inout Render) -> Void) {
        guard let index = renders.firstIndex(where: { $0.id == id }) else { return }
        change(&renders[index])
    }
}

/// `job.json`: what a job needs to come back after a relaunch. Files inside the job folder are stored by name, so a
/// moved folder still opens.
struct JobRecord: Codable {
    static let version = 2

    var version = Self.version
    var id: UUID
    var created: Date
    var spec: JobSpec
    var stage: Job.Stage
    var detail: String
    var renders: [Render]
    var origin: JobOrigin?
    /// Nil in records saved before it was kept.
    var prepRevision: Int?
}

/// Which agent started a clip with `prepare`, when, and with which request: a repeated request finds its clips by
/// `requestID` and must come with the same `parameters`.
struct JobOrigin: Codable, Equatable {
    /// The MCP client's name.
    var client: String
    var requestID: String
    var started: Date
    /// The clip's place among the request's ranges.
    var index: Int
    /// The request's parameters as the agent gave them, as canonical JSON.
    var parameters: String

    /// "Claude Code · 17 Oct, 14:02".
    var label: String { "\(client) · \(started.formatted(.dateTime.day().month().hour().minute()))" }
}

/// Version 1 kept one render inside the job; it comes back as a prepared clip with that render.
private struct JobRecordV1: Decodable {
    var id: UUID
    var created: Date
    var spec: JobSpec
    var stage: String
    var detail: String
    var providerJobID: String?
    var generated: String?
    var result: String?

    var record: JobRecord {
        let prep: Job.Stage =
            switch stage {
            case "waiting", "preparing": .waiting
            case "failed" where providerJobID == nil && result == nil: .failed
            case "canceled" where providerJobID == nil && result == nil: .canceled
            default: .prepared
            }
        var renders: [Render] = []
        if prep == .prepared, let renderStage = Render.Stage(rawValue: stage) {
            var render = Render(quality: .draft, prompt: spec.prompt, created: created)
            render.stage = renderStage
            render.detail = detail
            render.providerJobID = providerJobID
            render.generated = generated
            render.result = result
            renders.append(render)
        }
        return JobRecord(
            id: id, created: created, spec: spec, stage: prep, detail: prep == .prepared ? "" : detail,
            renders: renders)
    }
}

extension JobRecord {
    static func decode(_ data: Data) throws -> JobRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct Version: Decodable { var version: Int }
        switch try decoder.decode(Version.self, from: data).version {
        case 1: return try decoder.decode(JobRecordV1.self, from: data).record
        case Self.version: return try decoder.decode(JobRecord.self, from: data)
        default: return nil
        }
    }
}

extension Job {
    var record: JobRecord {
        JobRecord(
            id: id, created: created, spec: spec, stage: stage, detail: detail, renders: renders, origin: origin,
            prepRevision: prepRevision)
    }

    /// The job as it was saved. Work that was running when the app quit is put where it can safely continue: prep
    /// starts over, an upload's outcome is unknown, a render resumes from its request.
    convenience init(record: JobRecord, output: URL) {
        self.init(spec: record.spec, output: output, id: record.id, created: record.created)
        origin = record.origin
        prepRevision = record.prepRevision ?? 0
        manifest = (try? Data(contentsOf: output.appending(path: "manifest.json")))
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        detail = record.detail
        switch record.stage {
        case .waiting, .preparing:
            stage = .waiting
            detail = ""
        default:
            stage = record.stage
        }
        renders = record.renders.map { saved in
            var render = saved
            if render.stage == .uploading {
                render.stage = .unknown
                render.detail = "The app quit while submitting; check your Comfy history before rendering again."
            }
            return render
        }
    }
}
