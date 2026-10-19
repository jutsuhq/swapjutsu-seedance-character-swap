import Foundation
import ImageIO
import Testing

@testable import SwapjutsuApp

/// Files picked or dropped in Create land where they belong, whatever control received them.
@MainActor
struct DraftTests {
    private static let folder = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-draft")

    /// An image name gets a real image of `size` (Create reads the header); anything else is just a path.
    private func file(_ name: String, size: CGSize = CGSize(width: 512, height: 512)) -> URL {
        let url = Self.folder.appending(path: "\(Int(size.width))x\(Int(size.height))-\(name)")
        let isImage = ["png", "jpg", "webp", "heic"].contains(url.pathExtension)
        if isImage, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let image = context?.makeImage(),
                let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        return url
    }

    @Test func imagesSeedanceCantUseAreRefusedWithTheReason() {
        let draft = Draft()
        draft.addReferences([
            file("small.png", size: CGSize(width: 200, height: 400)),
            file("banner.png", size: CGSize(width: 1500, height: 400)), file("ok.png"),
        ])
        #expect(draft.references == [file("ok.png")])
        #expect(draft.failure?.contains("at least 300 px") == true)
        #expect(draft.failure?.contains("1:2.5") == true)
    }

    @Test func anImageBecomesACharacterNotTheSource() {
        let draft = Draft()
        draft.setSource(file("hero.png"))
        #expect(draft.source == nil)
        #expect(draft.references == [file("hero.png")])
    }

    @Test func aVideoBecomesTheSourceAndImagesTheCharacters() {
        let draft = Draft()
        draft.add([file("a.jpg"), file("clip.mov"), file("b.webp")])
        #expect(draft.source == file("clip.mov"))
        #expect(draft.references == [file("a.jpg"), file("b.webp")])
    }

    @Test func charactersStopAtEightAndSaySo() {
        let draft = Draft()
        draft.addReferences((1...10).map { file("c\($0).png") })
        #expect(draft.references.count == Draft.maxReferences)
        #expect(draft.references.first == file("c1.png"))
        #expect(draft.failure != nil)
    }

    @Test func theSameImageIsAddedOnce() {
        let draft = Draft()
        draft.addReferences([file("a.png")])
        draft.addReferences([file("a.png")])
        #expect(draft.references == [file("a.png")])
    }

    @Test func removingTheVideoKeepsTheCharacters() {
        let draft = Draft()
        draft.add([file("clip.mp4"), file("a.png")])
        draft.removeSource()
        #expect(draft.source == nil)
        #expect(draft.references == [file("a.png")])
    }

    @Test func anUnknownFileIsRefused() {
        let draft = Draft()
        draft.add([file("notes.txt")])
        #expect(draft.source == nil)
        #expect(draft.references.isEmpty)
        #expect(draft.failure != nil)
    }

    @Test func aClipIsPreparedWithoutCharacters() async {
        let draft = Draft()
        draft.setSource(file("clip.mov"))
        draft.setDuration(12)
        #expect(draft.canSubmit && draft.references.isEmpty)
    }

    @Test func specCopiesTheDraftAndFallsBackToTheFileName() throws {
        let draft = Draft()
        #expect(draft.spec == nil)
        draft.add([file("clip.mov"), file("a.png")])
        draft.sourceTitle = ""
        draft.target = .all
        draft.faceGuide = true
        draft.prompt = "swap"
        let spec = try #require(draft.spec)
        #expect(spec.title == "512x512-clip.mov" && spec.references == [file("a.png")] && spec.prompt == "swap")
        #expect(spec.options.target == .all && spec.options.faceGuide)
        draft.prompt = "changed"
        #expect(spec.prompt == "swap")
    }

    @Test func aLongClipStartsWithItsFirst30Seconds() {
        let draft = Draft()
        draft.setDuration(52.4)
        #expect(draft.ranges == [ClipRange(start: 0, end: 30)])
        draft.setEnd(40)
        #expect(draft.range?.end == 30, "a range is at most 30 s")
        draft.setStart(28)
        #expect(draft.range?.start == 26, "and at least 4 s")
    }

    @Test func rangesStayApartAndEachBecomesAJob() throws {
        let draft = Draft()
        draft.add([file("clip.mov"), file("a.png")])
        draft.setDuration(52.4)
        draft.setEnd(12)
        draft.addRange()
        #expect(draft.ranges == [ClipRange(start: 0, end: 12), ClipRange(start: 12, end: 24)])
        #expect(draft.selectedRange == 1)
        draft.moveRange(toStart: 0)
        #expect(draft.range?.start == 12, "a range can't slide over its neighbour")
        draft.moveRange(toStart: 100)
        #expect(abs((draft.range?.start ?? 0) - 40.4) < 0.001 && draft.range?.end == 52.4)
        let specs = draft.specs
        #expect(specs.count == 2 && specs[0].range == ClipRange(start: 0, end: 12) && specs[1].range?.end == 52.4)
        draft.removeRange(at: 0)
        #expect(draft.ranges.count == 1 && draft.selectedRange == 0)
        draft.removeRange(at: 0)
        #expect(draft.ranges.count == 1, "the last range stays")
    }

    @Test func theWholeClipNeedsNoCutAndATooShortOneNoRange() throws {
        let draft = Draft()
        draft.add([file("clip.mov"), file("a.png")])
        draft.setDuration(12)
        #expect(draft.specs.count == 1 && draft.specs.first?.range == nil)
        draft.setDuration(3)
        #expect(draft.ranges.isEmpty && !draft.canSubmit && draft.failure != nil)
    }

    @Test func liveProvidersNeedAKey() {
        let secret = KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.\(UUID().uuidString)")
        let credentials = Credentials(comfy: ComfyKeyStore(secret: secret))
        #expect(!credentials.hasComfyKey)
        #expect(throws: GenerationError.self) { try Providers.live(credentials)(RenderBackend(model: .seedance25)) }
    }
}

/// An agent's ranges are any number JSON holds; a time too big for an Int is refused, not a crash.
@MainActor
struct RangeProblemTests {
    @Test func aRangeNoIntHoldsIsRefused() {
        let ranges = [ClipRange(start: 1e20, end: 1e20), ClipRange(start: 0, end: 1e300), ClipRange(start: -1e20, end: 5)]
        for range in ranges {
            #expect(Draft.problem(with: [range], duration: 5) != nil)
        }
        #expect(Timecode.text(.infinity) == "5999:59.9" && Timecode.text(.nan) == "00:00.0")
    }
}

/// Clearing the examples cache waits for every clip still reading an example from it.
@MainActor
struct ExamplesCacheTests {
    @Test func aQueuedClipsExampleKeepsTheCache() {
        let samples = URL(filePath: "/cache/samples")
        let example = samples.appending(path: "dance/clip.mp4")
        func spec(_ source: URL, references: [URL] = []) -> JobSpec {
            JobSpec(
                title: "t", source: source, references: references, prompt: "", target: .main, faceGuide: false,
                model: .seedance25)
        }
        let draft = Draft()
        let reads = { (specs: [JobSpec]) in StorageSettings.reads(samples, draft: draft, specs: specs) }
        let character = samples.appending(path: "dance/../dance/face.png")
        #expect(!reads([]) && reads([spec(example)]))
        #expect(reads([spec(URL(filePath: "/a.mp4"), references: [character])]))
        #expect(!reads([spec(URL(filePath: "/jobs/x/inputs/source.mov"))]), "copied into its folder")
        draft.references = [character]
        #expect(StorageSettings.reads(samples, draft: draft, specs: []))
    }

    /// An example's video is in the cache before its characters are, and before the new clip has any of it.
    @Test func anExampleStillDownloadingKeepsTheCache() async {
        let samples = URL(filePath: "/cache/samples")
        let draft = Draft()
        // Nothing listens on port 1: the download fails without writing anything.
        let sample = Sample(
            id: "audit-\(UUID().uuidString)", title: "t", kind: .swap,
            sourceVideo: URL(string: "http://127.0.0.1:1/clip.mp4")!, thumbnail: nil, duration: 5, preview: nil,
            references: [], prompt: nil)
        let loading = Task { await draft.apply(sample) }
        for _ in 0..<400 where draft.loadingSampleID == nil { await Task.yield() }
        #expect(StorageSettings.reads(samples, draft: draft, specs: []))
        await loading.value
        #expect(!StorageSettings.reads(samples, draft: draft, specs: []) && draft.failure != nil)
    }
}
