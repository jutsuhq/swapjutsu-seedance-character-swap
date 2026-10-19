import CoreGraphics
import Foundation
import Testing

@testable import SwapjutsuPrep

struct IdentityTests {
    let tuning = Tuning()

    @Test func peopleSeenTogetherNeverMerge() {
        // Two tracklets in the same frames look identical; a third, later one looks like both.
        let frames: [Set<Int>] = [Set(0..<10), Set(0..<10), Set(20..<30)]
        let distance: (Int, Int) -> Float = { a, b in Set([a, b]) == [0, 1] ? 0.01 : 0.1 }
        let result = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: frames, weights: [10, 5, 10], distance: distance)
        #expect(result.count == 2)
        #expect(result.identities[0] != result.identities[1])
        #expect(result.identities[2] == result.identities[0])
    }

    @Test func differentLooksStayApart() {
        let result = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: [Set(0..<10), Set(20..<30)], weights: [1, 1], distance: { _, _ in 0.9 })
        #expect(result.count == 2)
        #expect(result.closestSeparate?.2 == 0.9)
    }

    @Test func identityOneHasTheMostScreenPresence() {
        let result = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: [Set(0..<10), Set(0..<10)], weights: [3, 50], distance: { _, _ in 0.9 })
        #expect(result.identities == [2, 1])
    }

    @Test func flickerTrackletJoinsNearestIdentity() {
        // Tracklet 2 is one frame long: too short to be a person of its own.
        let frames: [Set<Int>] = [Set(0..<10), Set(0..<10), [20]]
        let result = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: frames, weights: [10, 10, 1], distance: { a, b in Set([a, b]) == [1, 2] ? 0.05 : 0.8 })
        #expect(result.count == 2)
        #expect(result.identities[2] == result.identities[1])
    }

    /// Regressions from the 2026-10-16 audit: a short tracklet never joins someone it shares a frame with, also
    /// when another short already took that frame.
    @Test func shortTrackletsRespectCannotLink() {
        let alike: (Int, Int) -> Float = { _, _ in 0.05 }
        let overlapping = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: [Set(0..<10), [5]], weights: [10, 1], distance: alike)
        #expect(overlapping.identities[0] != overlapping.identities[1])
        let twins = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: [Set(0..<10), [20], [20]], weights: [10, 1, 1], distance: alike)
        #expect(twins.identities[1] != twins.identities[2])
        #expect(twins.identities.contains(1))
    }

    @Test func aShortTrackletUnlikeEveryoneStaysApart() {
        let result = AgglomerativeIdentity(tuning: tuning).cluster(
            frames: [Set(0..<10), [20]], weights: [10, 1], distance: { _, _ in 0.9 })
        #expect(result.identities == [1, 2])
        #expect(result.count == 2)
    }

    @Test func trackerSplitsWhenClothingColourJumps() {
        var tracker = Tracker(tuning: tuning)
        let full = MaskGrid(side: 4, cells: .init(repeating: true, count: 16))
        func detection(_ frame: Int, colour bin: Int) -> PersonDetection {
            var colour = [Float](repeating: 0, count: 192)
            colour[bin] = 1
            return PersonDetection(
                frame: frame, index: 0, grid: full, box: .zero, appearance: Appearance(colour: colour),
                face: nil, confirmed: true)
        }
        tracker.add([detection(0, colour: 5)])
        tracker.add([detection(1, colour: 5)])
        tracker.add([detection(2, colour: 90)])  // same place, different person: a missed cut
        #expect(tracker.tracklets.map(\.detections.count) == [2, 1])
    }
}

struct MeasureTests {
    @Test func aBrokenDepthCacheThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swapjutsu-depth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DepthCache(directory: dir)
        #expect(throws: PrepError.self) { try cache.load(frame: 0, size: CGSize(width: 4, height: 4)) }
        try Data(count: 10).write(to: dir.appendingPathComponent("0.depth"))
        #expect(throws: PrepError.self) { try cache.load(frame: 0, size: CGSize(width: 4, height: 4)) }
        try Data(count: 32).write(to: dir.appendingPathComponent("0.depth"))
        #expect(try cache.load(frame: 0, size: CGSize(width: 4, height: 4)).extent.width == 4)
    }

    @Test func histogramDistanceBounds() {
        let a: [Float] = [0.5, 0.5, 0], b: [Float] = [0, 0, 1]
        #expect(abs(histogramDistance(a, a)) < 1e-6)
        #expect(abs(histogramDistance(a, b) - 1) < 1e-6)
    }

    @Test func gridBoxUsesBottomLeftOrigin() {
        // Only the top row of a 4 × 4 grid is set: the box sits at the top of the unit square.
        let grid = MaskGrid(side: 4, cells: [true, true, true, true] + .init(repeating: false, count: 12))
        #expect(grid.unitBox == CGRect(x: 0, y: 0.75, width: 1, height: 0.25))
        #expect(grid.iou(grid) == 1)
        #expect(grid.iou(MaskGrid(side: 4, cells: .init(repeating: true, count: 16))) == 0.25)
    }

    @Test func shotDepthRangeIgnoresOutlierFrames() throws {
        // 18 steady frames, one with a far outlier, one with a near outlier.
        let ranges = [Float](repeating: 0.3, count: 18).map { $0...0.7 } + [0.0...0.7, 0.3...1.0]
        let range = try #require(ShotDepthRange(ranges))
        #expect(range.low == 0.3)
        #expect(range.high == 0.7)
    }
}
