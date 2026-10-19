import Foundation

/// Trimming, as in Jutsu Studio's `CreateForm+Ranges`: several ranges of one source, each 4–30 s, in order and never
/// overlapping, each prepared as its own clip.
extension Draft {
    /// Seedance edits 4–30 s.
    static let rangeLimits: ClosedRange<Double> = 4...30

    /// Why `ranges` can't be prepared from a source `duration` long, by the rules the trim strip keeps: each 4–30 s,
    /// inside the source, in order and apart. nil when they can.
    static func problem(with ranges: [ClipRange], duration: Double) -> String? {
        guard !ranges.isEmpty else { return "Give at least one range." }
        var previousEnd = 0.0
        for (index, range) in ranges.enumerated() {
            let name = "Range \(index + 1) (\(range.text))"
            guard range.start.isFinite, range.end.isFinite, range.start >= 0 else {
                return "\(name) isn't a time span."
            }
            guard rangeLimits.contains(range.duration) else {
                return "\(name) is \(Timecode.text(range.duration)) long; Seedance edits 4–30 s."
            }
            // A few hundredths of slack: a length read from the file can be a frame shorter than the agent's.
            guard range.end <= duration + 0.05 else {
                return "\(name) ends after the video, which is \(Timecode.text(duration)) long."
            }
            guard index == 0 || range.start >= previousEnd else {
                return "\(name) starts before the range ahead of it ends; ranges go in order and don't overlap."
            }
            previousEnd = range.end
        }
        return nil
    }

    /// The range the strip edits.
    var range: ClipRange? { ranges.indices.contains(selectedRange) ? ranges[selectedRange] : nil }

    /// "30.0 s": all ranges together.
    var rangeSeconds: String {
        "\(ranges.reduce(0) { $0 + $1.duration }.formatted(.number.precision(.fractionLength(1)))) s"
    }

    /// Parts of the source no range covers, for dimming on the strip.
    var uncoveredRanges: [ClipRange] { gaps.filter { $0.duration > 0.01 } }

    /// There is a gap of at least 4 s for another range.
    var canAddRange: Bool { nextRange != nil }

    /// Adds a range in the first gap of at least 4 s, as long as the edited one where it fits, and edits it.
    func addRange() {
        guard let next = nextRange else { return }
        let index = ranges.firstIndex { $0.start >= next.end } ?? ranges.count
        ranges.insert(next, at: index)
        selectedRange = index
    }

    /// The last range can't be removed; removing the edited one edits the next, or the previous at the end.
    func removeRange(at index: Int) {
        guard ranges.count > 1, ranges.indices.contains(index) else { return }
        ranges.remove(at: index)
        if index < selectedRange || selectedRange == ranges.count { selectedRange -= 1 }
    }

    func selectRange(at index: Int) {
        guard ranges.indices.contains(index) else { return }
        selectedRange = index
    }

    /// Moves the start, keeping the range 4–30 s long and after the previous one.
    func setStart(_ time: Double) {
        guard let range else { return }
        let limits = Self.rangeLimits
        let start = max(room.lowerBound, range.end - limits.upperBound, min(time, range.end - limits.lowerBound))
        ranges[selectedRange].start = start
    }

    /// Moves the end, keeping the range 4–30 s long and before the next one.
    func setEnd(_ time: Double) {
        guard let range else { return }
        let limits = Self.rangeLimits
        let end = min(room.upperBound, range.start + limits.upperBound, max(time, range.start + limits.lowerBound))
        ranges[selectedRange].end = end
    }

    /// Slides the whole range, keeping its length, between its neighbours.
    func moveRange(toStart time: Double) {
        guard let range else { return }
        let start = min(max(time, room.lowerBound), room.upperBound - range.duration)
        ranges[selectedRange] = ClipRange(start: start, end: start + range.duration)
    }

    /// Where the edited range may go: from the end of the previous range to the start of the next.
    var room: ClosedRange<Double> {
        let lower = ranges.indices.contains(selectedRange - 1) ? ranges[selectedRange - 1].end : 0
        let upper = ranges.indices.contains(selectedRange + 1) ? ranges[selectedRange + 1].start : (duration ?? 0)
        return lower...max(lower, upper)
    }

    /// Before, between and after the ranges, in order.
    private var gaps: [ClipRange] {
        guard let duration else { return [] }
        var gaps: [ClipRange] = []
        var start = 0.0
        for range in ranges {
            gaps.append(ClipRange(start: start, end: max(start, range.start)))
            start = range.end
        }
        gaps.append(ClipRange(start: start, end: max(start, duration)))
        return gaps
    }

    private var nextRange: ClipRange? {
        let limits = Self.rangeLimits
        let length = min(max(range?.duration ?? 10, limits.lowerBound), limits.upperBound)
        guard let gap = gaps.first(where: { $0.duration >= limits.lowerBound }) else { return nil }
        return ClipRange(start: gap.start, end: min(gap.end, gap.start + length))
    }
}
