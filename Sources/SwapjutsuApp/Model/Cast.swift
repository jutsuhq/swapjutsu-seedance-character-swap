import Foundation

/// Who one replaced person becomes (#60): `person` is a `Manifest.Identity.id`, `images` index `JobSpec.references`.
/// The first image is the character; the rest are more views of the same character, not other people. Images in
/// no binding replace no one: a prop, an outfit, a detail the person's wishes name.
struct CharacterBinding: Codable, Hashable, Sendable {
    var person: Int
    var images: [Int]

    var character: Int? { images.first }
    var views: ArraySlice<Int> { images.dropFirst() }
}

extension JobSpec {
    /// One binding per replaced person, in `targets` order. A job saved before the bindings existed (`cast` nil)
    /// gives the replaced people the images in order, as it rendered then; a binding to someone no longer replaced
    /// is left out, so their images become extras.
    func cast(for targets: [Int]) -> [CharacterBinding] {
        guard let cast else {
            return targets.enumerated().map { slot, person in
                CharacterBinding(person: person, images: references.indices.contains(slot) ? [slot] : [])
            }
        }
        return targets.map { person in
            let images = cast.first { $0.person == person }?.images ?? []
            return CharacterBinding(person: person, images: images.filter(references.indices.contains))
        }
    }

    /// The images that replace no one, in order.
    func extras(for targets: [Int]) -> [Int] {
        let bound = Set(cast(for: targets).flatMap(\.images))
        return references.indices.filter { !bound.contains($0) }
    }

    /// Gives `image` to `person`: as their character, or with `asView` as one more view of it; nil makes it an
    /// extra. A character dragged from another person swaps with the one `person` had; otherwise the one replaced
    /// becomes an extra, unless it is `person`'s own view moved up, where the old character stays as a view.
    mutating func assign(_ image: Int, to person: Int?, asView: Bool = false, targets: [Int]) {
        guard references.indices.contains(image) else { return }
        var cast = cast(for: targets)
        let from = cast.firstIndex { $0.images.contains(image) }
        let wasCharacter = from.map { cast[$0].character == image } ?? false
        if let from { cast[from].images.removeAll { $0 == image } }
        if let person, let to = cast.firstIndex(where: { $0.person == person }) {
            if asView || cast[to].images.isEmpty {
                cast[to].images.append(image)
            } else if from == to {
                cast[to].images.insert(image, at: 0)
            } else {
                let previous = cast[to].images[0]
                cast[to].images[0] = image
                if let from, wasCharacter { cast[from].images.insert(previous, at: 0) }
            }
        }
        self.cast = cast
    }

    /// Takes the image at `index` off the clip; later images move up a place, in the bindings too.
    mutating func removeReference(at index: Int) {
        guard references.indices.contains(index) else { return }
        references.remove(at: index)
        cast = cast?.map { binding in
            var binding = binding
            binding.images = binding.images.compactMap { $0 == index ? nil : $0 > index ? $0 - 1 : $0 }
            return binding
        }
    }
}
