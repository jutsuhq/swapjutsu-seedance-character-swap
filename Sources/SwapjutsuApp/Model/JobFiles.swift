import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SwapjutsuPrep
import UniformTypeIdentifiers

/// The job owns its inputs: they are copied into `<job>/inputs` when prep starts (characters added later, as they
/// are added), the source cut to the job's range, so moving or editing the originals later can't break a deferred
/// generation or the final mux.
enum JobFiles {
    /// The image types Seedance reads as they are; anything else (HEIC, TIFF, GIF…) is converted to PNG.
    static let uploadableImages: [UTType] = [.jpeg, .png, .webP]

    static func adopt(_ spec: JobSpec, into output: URL) async throws -> JobSpec {
        let inputs = output.appending(path: "inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        var adopted = spec
        if let range = spec.range, !isInside(spec.source, inputs) {
            adopted.source = try await cut(spec.source, to: range, into: inputs.appending(path: "source.mov"))
        } else {
            adopted.source = try copy(spec.source, to: inputs.appending(path: "source"), in: inputs)
        }
        adopted.references = try spec.references.enumerated().map { index, url in
            try character(url, to: inputs.appending(path: "character-\(index + 1)"), in: inputs)
        }
        adopted.background = try spec.background.map { try character($0, to: inputs.appending(path: "background"), in: inputs) }
        return adopted
    }

    /// Re-encoded rather than passed through: a passthrough cut starts at the keyframe before the range, and prep,
    /// Seedance and the soundtrack would all see a different start.
    private static func cut(_ url: URL, to range: ClipRange, into file: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600))
        try? FileManager.default.removeItem(at: file)
        try await export.export(to: file, as: .mov)
        return file
    }

    /// By path components: two URLs of one folder can differ in a trailing slash or how they were made
    /// (`URL(filePath:)` against `appending(path:)`), and compare unequal.
    private static func isInside(_ url: URL, _ inputs: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().pathComponents == inputs.standardizedFileURL.pathComponents
    }

    /// `url` copied to `base.<ext>`, unless it already lives in `inputs` (a restored job).
    private static func copy(_ url: URL, to base: URL, in inputs: URL) throws -> URL {
        if isInside(url, inputs) { return url }
        let file = base.appendingPathExtension(url.pathExtension)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: url, to: file)
        return file
    }

    /// A character (or, by `kind`, the background) added to a clip after it was started, copied into its inputs under
    /// a name of its own.
    static func addCharacter(_ url: URL, into output: URL, as kind: String = "character") throws -> URL {
        let inputs = output.appending(path: "inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let name = "\(kind)-\(UUID().uuidString.prefix(8).lowercased())"
        return try character(url, to: inputs.appending(path: name), in: inputs)
    }

    /// Where each image of a clip goes in `@Image` order, without reading a file: each person's character
    /// (`@Image1…`, in `cast` order, as the service prompt binds them), the new place when it is replaced, the
    /// people's views (`CharacterBinding.views`), then the references that replace no one. The face close-ups come
    /// after all of them (`uploads`), so these numbers hold whether or not a face is found. Past Seedance's limit the
    /// views go, the last first.
    struct Layout: Equatable {
        /// The characters' `references` indices, in cast order.
        var characters: [Int]
        /// The new place's `@Image` number.
        var background: Int?
        var views: [View]
        /// The `references` indices of the images that replace no one, in order.
        var others: [Int]

        init(
            cast: [CharacterBinding], references: Int, background: Bool, angle: (Int) -> CharacterAngle? = { _ in nil },
            limit: Int = JobFiles.maxImages
        ) {
            let bound = cast.filter { $0.character != nil }
            characters = bound.compactMap(\.character)
            others = (0..<references).filter { index in !cast.contains { $0.images.contains(index) } }
            self.background = background ? characters.count + 1 : nil
            var next = characters.count + (background ? 1 : 0) + 1
            var room = max(0, limit - next + 1 - others.count)
            views = []
            for (k, binding) in bound.enumerated() {
                for reference in binding.views where room > 0 {
                    views.append(View(image: next, character: k + 1, angle: angle(reference), reference: reference))
                    next += 1
                    room -= 1
                }
            }
        }

        /// `@Image` numbers of the images that replace no one.
        var extras: [Int] {
            let first = characters.count + (background == nil ? 0 : 1) + views.count + 1
            return Array(first..<(first + others.count))
        }

        var count: Int { characters.count + (background == nil ? 0 : 1) + views.count + others.count }

        /// The `@Image` number of `references[index]`, nil when it doesn't go.
        func number(of index: Int) -> Int? {
            if let k = characters.firstIndex(of: index) { return k + 1 }
            if let view = views.first(where: { $0.reference == index }) { return view.image }
            return others.firstIndex(of: index).map { extras[$0] }
        }
    }

    /// What a render uploads, in `@Image` order: the images of `layout`, then the face close-ups.
    struct Uploads: Equatable {
        var images: [URL]
        var layout: Layout
        var closeUps: [CloseUp] = []

        var views: [View] { layout.views }
        /// `@Image` numbers of the other references.
        var extras: [Int] { layout.extras }

        /// The layout's numbers alone, before any file is read: the prompt as Create shows it.
        init(layout: Layout) { (images, self.layout) = ([], layout) }

        init(images: [URL], layout: Layout, closeUps: [CloseUp]) {
            (self.images, self.layout, self.closeUps) = (images, layout, closeUps)
        }
    }

    /// A face close-up (`FaceCloseUp`) of a character, by `@Image` numbers.
    struct CloseUp: Equatable {
        var image: Int
        var character: Int
    }

    /// Another view of a character, by `@Image` numbers, with the angle it was added for.
    struct View: Equatable {
        var image: Int
        var character: Int
        var angle: CharacterAngle?
        /// Its index in `JobSpec.references`.
        var reference: Int
    }

    /// Seedance 2.5 takes up to 30 reference images (ComfyUI's `seedance2_reference_limits` for
    /// `dreamina-seedance-2-5-260628`); the views and the close-ups only repeat a character, so they go first.
    static let maxImages = 30

    /// The images as they go to Seedance, in `layout` order. With `removeBackground`, each reference is cut out onto
    /// grey next to the original (`<name>-cutout.jpg`, made once); an image without a clear subject goes as it is.
    /// The `background` (there when `layout` has one) is never cut out: it is the place, not a subject. Each
    /// character whose face is small gets its face close-up after everything else (`faceCloseUp(of:)`), while there
    /// is room.
    static func uploads(
        _ references: [URL], removeBackground: Bool, background: URL? = nil, layout: Layout
    ) throws -> Uploads {
        let images = { (indices: [Int]) in
            try cutouts(indices.map { references[$0] }, removeBackground: removeBackground)
        }
        let lead = try images(layout.characters) + (background.map { [$0] } ?? [])
        let rest = try images(layout.views.map(\.reference)) + images(layout.others)
        let faces = Array(
            layout.characters.enumerated()
                .compactMap { k, index in faceCloseUp(of: references[index]).map { (k + 1, $0) } }
                .prefix(max(0, maxImages - layout.count)))
        let closeUps = faces.enumerated().map { CloseUp(image: layout.count + $0 + 1, character: $1.0) }
        return Uploads(images: lead + rest + faces.map(\.1), layout: layout, closeUps: closeUps)
    }

    /// `face-<name>.jpg` beside a character in the job's inputs: a close-up of its face from the character file
    /// itself (never its cutout), made once and again only when the character is newer; nil when the image has no
    /// face Vision finds or one large enough already. Nothing else records it, so old jobs get one the same way.
    static func faceCloseUp(of url: URL) -> URL? {
        let file = url.deletingLastPathComponent()
            .appending(path: "face-\(url.deletingPathExtension().lastPathComponent).jpg")
        let date = { (url: URL) in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        if let made = date(file), let original = date(url), made >= original { return file }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let face = try? FaceCloseUp().closeUp(image),
            (try? writeJPEG(face, to: file)) != nil
        else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return file
    }

    /// One character as it goes to a generator: cut out onto grey with `removeBackground`, else as it is.
    static func character(_ reference: URL, removeBackground: Bool) throws -> URL {
        try cutouts([reference], removeBackground: removeBackground).first ?? reference
    }

    private static func cutouts(_ references: [URL], removeBackground: Bool) throws -> [URL] {
        guard removeBackground else { return references }
        return try references.map { url in
            let file = url.deletingPathExtension().appendingPathExtension("cutout.jpg")
            if FileManager.default.fileExists(atPath: file.path) { return file }
            return try cutout(url, to: file) ?? url
        }
    }

    /// `url` as Seedance reads it, at `base.<ext>`: copied, or converted to PNG.
    private static func character(_ url: URL, to base: URL, in inputs: URL) throws -> URL {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, uploadableImages.contains(where: type.conforms) {
            return try copy(url, to: base, in: inputs)
        }
        if isInside(url, inputs) { return url }
        return try convertToPNG(url, to: base.appendingPathExtension("png"))
    }

    /// The character cut out onto grey as JPEG (no alpha for Seedance to turn black), or nil to use the original:
    /// no clear subject, or not an image Vision reads.
    private static func cutout(_ url: URL, to file: URL) throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let cut = try? VisionCutout().cutout(image)
        else { return nil }
        try writeJPEG(cut, to: file)
        return file
    }

    private static func writeJPEG(_ image: CGImage, to file: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func convertToPNG(_ url: URL, to file: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }
}
