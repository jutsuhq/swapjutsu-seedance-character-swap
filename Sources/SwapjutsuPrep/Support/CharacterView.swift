import Foundation

/// The angle another image of a character shows it from. Seedance invents what a single front image doesn't show:
/// the back of the hair and clothes when the performer turns away, the profile in a side step. A view per angle,
/// bound to its character in the prompt, keeps those the same character.
public enum CharacterAngle: String, Codable, Sendable, CaseIterable {
    case threeQuarter
    case side
    case back
    /// A turnaround sheet: front, three-quarter, side and back on one image.
    case sheet

    public var title: String {
        switch self {
        case .threeQuarter: "3/4"
        case .side: "Side"
        case .back: "Back"
        case .sheet: "Sheet"
        }
    }

    /// How the prompt says what the view shows: "seen from behind".
    var seen: String {
        switch self {
        case .threeQuarter: "seen at a three-quarter angle"
        case .side: "seen in profile"
        case .back: "seen from behind"
        case .sheet: "from the front, the side and behind"
        }
    }
}

/// A view of character `@Image<character>` uploaded as `@Image<image>`, from `angle` when it is known.
public struct ReferenceView: Sendable, Equatable {
    public var image: Int
    public var angle: CharacterAngle?

    public init(image: Int, angle: CharacterAngle?) {
        self.image = image
        self.angle = angle
    }
}
