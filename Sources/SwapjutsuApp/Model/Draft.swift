import AVFoundation
import Foundation
import ImageIO
import Observation
import SwapjutsuPrep
import UniformTypeIdentifiers

/// The new clip Create is filling in: the video, its ranges and the prep options. `specs` are the snapshots that
/// become clips. Characters and the prompt are set on each clip once it is prepared; an example's (or images dropped
/// here) come along into every clip.
@MainActor
@Observable
final class Draft {
    typealias Target = PrepTarget

    var source: URL? {
        didSet { if source != oldValue { sourceChanged() } }
    }
    var sourceTitle = ""
    /// The source's length, once read; the ranges wait for it.
    private(set) var duration: Double?
    /// The parts of the source to prepare, in order and apart, each 4–30 s; each becomes its own clip.
    var ranges: [ClipRange] = []
    /// The range the trim strip edits.
    var selectedRange = 0
    /// Character images that come along into the clips, `@Image1…` in order.
    var references: [URL] = []
    var prompt = ""
    var target = PrepDefaults.target
    var faceGuide = PrepDefaults.faceGuide
    /// Off by default until a paid A/B run shows Seedance does better with cut-out characters.
    var removeBackground = PrepDefaults.removeBackground
    /// Grey depth instead of the original around the people; the place's image is set on the clip, like characters.
    var replaceBackground = PrepDefaults.replaceBackground
    /// nil: colored depth; an agent's hybrid control otherwise.
    var control: ControlMode?
    var model = GenerationModel.seedance25
    /// The example being downloaded into the draft.
    private(set) var loadingSampleID: String?
    var failure: String?

    /// Seedance 2.5 reads up to 30 reference images; eight keeps the grid and the prompt manageable.
    static let maxReferences = 8

    var canSubmit: Bool { source != nil && !ranges.isEmpty && loadingSampleID == nil }

    /// The job this draft describes for one range (the whole clip without one), or nil while it has no source.
    func spec(for range: ClipRange? = nil) -> JobSpec? {
        guard let source else { return nil }
        // The whole clip needs no cut.
        let range = range.flatMap { range in
            range.start < 0.05 && abs(range.end - (duration ?? range.end)) < 0.05 ? nil : range
        }
        return JobSpec(
            title: sourceTitle.isEmpty ? source.lastPathComponent : sourceTitle, source: source,
            references: references, prompt: prompt, target: target, faceGuide: faceGuide,
            removeBackground: removeBackground, replaceBackground: replaceBackground, model: model, range: range,
            control: control)
    }

    var spec: JobSpec? { spec(for: ranges.first) }

    /// One job per range.
    var specs: [JobSpec] { ranges.compactMap { spec(for: $0) } }

    /// Files dropped or picked anywhere in Create land where they belong: a video becomes the source, images become
    /// characters, anything else is refused with a message.
    func add(_ urls: [URL]) {
        let videos = urls.filter { Self.conforms($0, to: .movie) }
        let images = urls.filter { Self.conforms($0, to: .image) }
        if let video = videos.first { setSource(video) }
        addReferences(images)
        if videos.isEmpty && images.isEmpty, let file = urls.first {
            failure = "\(file.lastPathComponent) is neither a video nor an image."
        }
    }

    func setSource(_ url: URL) {
        guard Self.conforms(url, to: .movie) else { return add([url]) }
        source = url
        sourceTitle = url.deletingPathExtension().lastPathComponent
    }

    func removeSource() {
        source = nil
        sourceTitle = ""
    }

    func addReferences(_ urls: [URL]) {
        let images = urls.filter { Self.conforms($0, to: .image) && !references.contains($0) }
        var refused: [String] = []
        let new = images.filter { url in
            guard let problem = Self.imageProblem(url) else { return true }
            refused.append("\(url.lastPathComponent) \(problem)")
            return false
        }
        let room = Self.maxReferences - references.count
        references += new.prefix(room)
        if !refused.isEmpty {
            failure = "Seedance can't use " + refused.joined(separator: "; ") + "."
        } else if new.count > room {
            failure = "Swapjutsu takes up to \(Self.maxReferences) character images."
        }
    }

    /// Seedance 2.5's limits for a reference image (docs.comfy.org › ByteDance2ReferenceNodeV2): at least 300 px on
    /// each side and an aspect ratio between 0.4 and 2.5. Checked from the file header, before anything uploads.
    static func imageProblem(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return "is not a readable image" }
        if min(width, height) < 300 { return "is \(width)×\(height); it needs at least 300 px on each side" }
        let ratio = Double(width) / Double(height)
        if ratio < 0.4 || ratio > 2.5 {
            return "is \(width)×\(height); its sides must be within 1:2.5 of each other"
        }
        return nil
    }

    func removeReference(at index: Int) {
        guard references.indices.contains(index) else { return }
        references.remove(at: index)
    }

    private static func conforms(_ url: URL, to type: UTType) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true
    }

    /// Downloads the example's clip and character images, then puts them and its prompt in the draft.
    func apply(_ sample: Sample) async {
        loadingSampleID = sample.id
        failure = nil
        defer { loadingSampleID = nil }
        do {
            let folder = AppPaths.samples.appending(path: sample.id)
            let video = try await AppPaths.cached(sample.sourceVideo, into: folder, name: "source")
            var images: [URL] = []
            for (index, link) in sample.references.prefix(Self.maxReferences).enumerated() {
                images.append(try await AppPaths.cached(link, into: folder, name: "character-\(index + 1)"))
            }
            setSource(video)
            sourceTitle = sample.title
            references = images
            prompt = sample.prompt ?? ""
        } catch {
            failure = "Can't download \(sample.title): \(error.localizedDescription)"
        }
    }

    private var durationTask: Task<Void, Never>?

    /// A new source starts with one range: the whole clip, or its first 30 s.
    private func sourceChanged() {
        duration = nil
        ranges = []
        selectedRange = 0
        durationTask?.cancel()
        guard let source else { return }
        durationTask = Task {
            let seconds = try? await AVURLAsset(url: source).load(.duration).seconds
            guard !Task.isCancelled, self.source == source else { return }
            setDuration(seconds ?? 0)
        }
    }

    /// Sets the length the ranges are measured against; Create reads it from the file, tests set it.
    func setDuration(_ seconds: Double) {
        durationTask?.cancel()
        duration = seconds
        ranges = seconds >= Self.rangeLimits.lowerBound ? [ClipRange(start: 0, end: min(seconds, 30))] : []
        selectedRange = 0
        if seconds > 0 && seconds < Self.rangeLimits.lowerBound {
            failure = "Seedance edits clips of 4–30 s; this one is \(Timecode.text(seconds))."
        }
    }

    /// Waits for the source's length; for tests and the debug autopilot.
    func settle() async { await durationTask?.value }

    func clear() {
        source = nil
        sourceTitle = ""
        references = []
        prompt = ""
        target = PrepDefaults.target
        faceGuide = PrepDefaults.faceGuide
        removeBackground = PrepDefaults.removeBackground
        replaceBackground = PrepDefaults.replaceBackground
        control = nil
    }
}
