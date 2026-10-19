import Foundation
import Synchronization
import Vision

/// Whether a character image shows enough of the body for the person it replaces (#60). A portrait has no clothes,
/// shoes or proportions for Seedance to follow on someone seen head to toe.
///
/// The heuristic: how far down from the top of the face an image reaches, in face heights (`reach`). Vision's face
/// box is about chin to brow, so a standing person measures about 8–9, knees-up about 6, waist-up about 3.5 and head
/// and shoulders 2–3. The person's side is measured on the crop prep keeps of them from their best frame
/// (`identities/<id>.jpg`, the detection box), the character's on the image, each down to the bottom of the body
/// rectangle Vision finds under the face, else to the bottom of the image. Full body is 6 and more, a portrait
/// under 4; only that pair warns, so a clear face is needed on both sides and anything unsure stays quiet.
enum ReferenceFit {
    static let fullBody = 6.0
    static let portrait = 4.0

    /// The warning for `person`'s image, or nil when it fits or either side can't be measured.
    static func warning(person: String, target: Double?, reference: Double?) -> String? {
        guard let target, let reference, target >= fullBody, reference < portrait else { return nil }
        return "\(person) is seen full body but their image is a portrait: Seedance has no clothes, shoes or "
            + "proportions to follow. A full-body image fits better."
    }

    /// Face heights from the top of `face` down to the bottom of `body` (or of the image), in Vision's normalized
    /// coordinates with the origin at the bottom left.
    static func reach(face: CGRect, body: CGRect?) -> Double? {
        guard face.height > 0 else { return nil }
        return Double((face.maxY - (body?.minY ?? 0)) / face.height)
    }

    private static let measured = Mutex<[URL: Double?]>([:])

    /// `reach` of the largest face in the image at `url`, measured once per file; nil without a face.
    static func reach(of url: URL) -> Double? {
        if let known = measured.withLock({ $0[url] }) { return known }
        let value = measure(url)
        measured.withLock { $0[url] = value }
        return value
    }

    private static func measure(_ url: URL) -> Double? {
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        guard (try? VNImageRequestHandler(url: url).perform([faces, bodies])) != nil,
            let face = faces.results?.max(by: { $0.boundingBox.height < $1.boundingBox.height })?.boundingBox
        else { return nil }
        let centre = CGPoint(x: face.midX, y: face.midY)
        let body = bodies.results?.map(\.boundingBox).filter { $0.contains(centre) }
            .max { $0.width * $0.height < $1.width * $1.height }
        return reach(face: face, body: body)
    }
}

extension Job {
    /// A `ReferenceFit` warning per replaced person whose character is a portrait while they are seen full body.
    /// Measures with Vision the first time; call it off the main actor where that matters.
    nonisolated static func fitWarnings(
        cast: [CharacterBinding], references: [URL], thumbnails: [Int: URL]
    ) -> [Int: String] {
        var warnings: [Int: String] = [:]
        for binding in cast {
            guard let character = binding.character, references.indices.contains(character),
                let thumbnail = thumbnails[binding.person]
            else { continue }
            warnings[binding.person] = ReferenceFit.warning(
                person: "Person \(binding.person)", target: ReferenceFit.reach(of: thumbnail),
                reference: ReferenceFit.reach(of: references[character]))
        }
        return warnings
    }

    /// `fitWarnings` for this clip as it is.
    var fitWarnings: [Int: String] {
        let thumbnails = (manifest?.identities ?? []).reduce(into: [Int: URL]()) { result, identity in
            if let thumbnail = identity.thumbnail { result[identity.id] = output.appending(path: thumbnail) }
        }
        return Self.fitWarnings(cast: cast, references: spec.references, thumbnails: thumbnails)
    }
}
