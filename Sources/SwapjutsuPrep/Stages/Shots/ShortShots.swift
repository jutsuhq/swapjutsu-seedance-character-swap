/// Shots too short to be real: a flash, a transition or one odd frame makes the detector call two cuts a frame or
/// two apart, or a cut right at the clip's start or end. Each is absorbed into a neighbour, at the clip's ends into
/// the only one, mid-clip into the longer one, which is the shot those frames most likely belong to.
enum ShortShots {
    /// `cuts`: frames where a shot starts, ascending, none at 0. Returns the cuts that stay.
    static func absorbed(cuts: [Int], frameCount: Int, minFrames: Int) -> [Int] {
        var bounds = [0] + cuts + [frameCount]
        while bounds.count > 2 {
            let lengths = zip(bounds.dropFirst(), bounds).map { $0 - $1 }
            guard let shortest = lengths.indices.min(by: { lengths[$0] < lengths[$1] }), lengths[shortest] < minFrames
            else { break }
            let intoPrevious =
                shortest == lengths.count - 1
                || (shortest > 0 && lengths[shortest - 1] >= lengths[shortest + 1])
            // The bound between the shot and the neighbour it joins goes.
            bounds.remove(at: intoPrevious ? shortest : shortest + 1)
        }
        return Array(bounds.dropFirst().dropLast())
    }
}
