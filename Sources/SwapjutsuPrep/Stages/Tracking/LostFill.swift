extension TargetMasks {
    /// One target's masks through an accepted shot: the tracked ones, and on frames where the tracker lost the target
    /// while Vision still sees it, Vision's, so the person is never left unpainted there. Not where Vision's mask is
    /// over `maxAreaRatio` times the median tracked area of the shot: that is Vision merging people
    /// (crowd-interaction), as in `DriftMonitor`. A held tracked mask would lag fast motion and ghost at exits.
    static func filled(
        tracked: [Int: TargetMask], vision: [[TargetMask]], identity: Int, frames: Range<Int>, maxAreaRatio: Double
    ) -> (masks: [Int: TargetMask], filled: [Int]) {
        let areas = frames.compactMap { tracked[$0]?.grid.area }.sorted()
        guard !areas.isEmpty else { return (tracked, []) }
        let limit = maxAreaRatio * Double(max(1, areas[areas.count / 2]))
        var (masks, filled) = (tracked, [Int]())
        for n in frames where tracked[n] == nil {
            guard let seen = vision[n].first(where: { $0.identity == identity }), seen.grid.area > 0,
                Double(seen.grid.area) <= limit
            else { continue }
            masks[n] = seen
            filled.append(n)
        }
        return (masks, filled)
    }
}
