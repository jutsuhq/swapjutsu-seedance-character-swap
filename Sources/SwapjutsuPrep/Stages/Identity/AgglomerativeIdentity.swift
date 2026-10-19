import Foundation

public struct IdentityResult: Sendable {
    /// Identity number (1-based, by screen presence) for each input tracklet, in input order.
    public let identities: [Int]
    public let count: Int
    /// Closest pair of identities that were kept apart without a cannot-link, and their distance.
    public let closestSeparate: (Int, Int, Float)?
    public let merges: [Float]

    public init(identities: [Int], count: Int, closestSeparate: (Int, Int, Float)?, merges: [Float]) {
        self.identities = identities
        self.count = count
        self.closestSeparate = closestSeparate
        self.merges = merges
    }
}

/// Average-linkage agglomerative clustering with a cannot-link rule: two tracklets present in the same frame are
/// always different people.
public struct AgglomerativeIdentity: IdentityClustering {
    let tuning: Tuning

    public init(tuning: Tuning) { self.tuning = tuning }

    public func cluster(frames: [Set<Int>], weights: [Int], distance: (Int, Int) -> Float) -> IdentityResult {
        let n = frames.count
        let solid = (0..<n).filter { frames[$0].count >= tuning.minTrackletFrames }
        var groups = (solid.isEmpty ? Array(0..<n) : solid).map { [$0] }
        var cache: [Int: Float] = [:]
        func d(_ a: Int, _ b: Int) -> Float {
            let key = min(a, b) * n + max(a, b)
            if let hit = cache[key] { return hit }
            let value = distance(a, b)
            cache[key] = value
            return value
        }
        func linked(_ a: [Int], _ b: [Int]) -> Bool {
            a.contains { x in b.contains { !frames[x].isDisjoint(with: frames[$0]) } }
        }
        func linkage(_ a: [Int], _ b: [Int]) -> Float {
            a.flatMap { x in b.map { d(x, $0) } }.reduce(0, +) / Float(a.count * b.count)
        }

        var merges: [Float] = []
        while true {
            var best: (Int, Int, Float)?
            for i in groups.indices {
                for j in groups.indices where j > i && !linked(groups[i], groups[j]) {
                    let value = linkage(groups[i], groups[j])
                    if value < (best?.2 ?? tuning.mergeDistance) { best = (i, j, value) }
                }
            }
            guard let (i, j, value) = best else { break }
            merges.append(value)
            groups[i] += groups[j]
            groups.remove(at: j)
        }

        groups.sort { $0.reduce(0) { $0 + weights[$1] } > $1.reduce(0) { $0 + weights[$1] } }
        let kept = groups.count
        // Short flicker tracklets join the nearest identity that close in looks and absent from all of their frames,
        // including the frames of shorts that already joined it; anything else stays a person of its own.
        for t in 0..<n where !groups.contains(where: { $0.contains(t) }) {
            let nearest = groups.indices.prefix(kept).filter { !linked([t], groups[$0]) }
                .map { ($0, linkage([t], groups[$0])) }
                .filter { $0.1 < tuning.mergeDistance }
                .min { $0.1 < $1.1 }
            if let (k, _) = nearest { groups[k].append(t) } else { groups.append([t]) }
        }
        var identities = [Int](repeating: 0, count: n)
        for (k, group) in groups.enumerated() { for t in group { identities[t] = k + 1 } }

        var closest: (Int, Int, Float)?
        for i in 0..<kept {
            for j in 0..<kept where j > i && !linked(groups[i], groups[j]) {
                let value = linkage(groups[i], groups[j])
                if value < (closest?.2 ?? .infinity) { closest = (i + 1, j + 1, value) }
            }
        }
        return IdentityResult(identities: identities, count: groups.count, closestSeparate: closest, merges: merges)
    }
}
