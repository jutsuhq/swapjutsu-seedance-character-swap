import Foundation

/// The prompt prep writes (`Pipeline.seedancePrompt`) ties replaced person `k` (in `Manifest.targets` order) to
/// `@Image<k>`, by where that person stands. Once the person picks who gets which image (#60), `bind` renumbers
/// those tags and names the role of every other image, so the binding by place stays and the order of the images
/// no longer matters.
public enum SeedancePrompt {
    /// The sentence after the binding in every prompt prep writes.
    public static let keep =
        "Keep every other pixel, the camera and the timing exactly. The depth colors are guidance only and must not appear."

    /// `prompt` with `@Image<k>` replaced by the first image of `people[k - 1]` (1-based image numbers), then a
    /// sentence for each person's further views and one for the images that replace nobody. `images` is how many
    /// images go to Seedance. With `people[k - 1] == [k]` and no other images, `prompt` comes back as it is.
    public static func bind(_ prompt: String, people: [[Int]], images: Int) -> String {
        let renumbered = prompt.replacing(/@Image(\d+)/) { match in
            guard let k = Int(match.1), people.indices.contains(k - 1), let image = people[k - 1].first
            else { return String(match.0) }
            return "@Image\(image)"
        }
        var roles: [String] = []
        for images in people where images.count > 1 {
            let views = list(images.dropFirst().map { "@Image\($0)" })
            roles.append(
                images.count == 2
                    ? "\(views) is another view of the character in @Image\(images[0])."
                    : "\(views) are more views of the character in @Image\(images[0]).")
        }
        let bound = Set(people.joined())
        let extras = images > 0 ? (1...images).filter { !bound.contains($0) } : []
        if !extras.isEmpty {
            let tags = list(extras.map { "@Image\($0)" })
            roles.append(
                extras.count == 1
                    ? "\(tags) replaces no one: it is a supporting reference, used only where the instructions name it."
                    : "\(tags) replace no one: they are supporting references, used only where the instructions name them."
            )
        }
        guard !roles.isEmpty else { return renumbered }
        let text = roles.joined(separator: " ")
        // Next to the binding, before the keep and audio lines.
        guard let keep = renumbered.range(of: Self.keep) else { return renumbered + " " + text }
        return renumbered.replacingCharacters(in: keep.lowerBound..<keep.lowerBound, with: text + " ")
    }

    /// "a, b and c".
    static func list(_ items: [String]) -> String {
        items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
    }
}
