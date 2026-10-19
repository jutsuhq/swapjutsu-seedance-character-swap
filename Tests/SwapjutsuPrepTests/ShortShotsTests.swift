import Testing

@testable import SwapjutsuPrep

/// False cuts a frame or two apart are absorbed; real shots, however short the fixtures have them, stay.
struct ShortShotsTests {
    func absorbed(_ cuts: [Int], frames: Int = 120) -> [Int] {
        ShortShots.absorbed(cuts: cuts, frameCount: frames, minFrames: Tuning().minShotFrames)
    }

    @Test func aShortShotAtAnEndJoinsItsOnlyNeighbour() {
        #expect(absorbed([1, 80]) == [80], "a one-frame shot at the start")
        #expect(absorbed([40, 117]) == [40], "three frames at the end")
        #expect(absorbed([3]) == [], "the whole clip is one shot")
    }

    @Test func aShortShotMidClipJoinsTheLongerNeighbour() {
        #expect(absorbed([30, 31, 100]) == [30, 100], "the 69-frame shot after it takes the frame")
        #expect(absorbed([80, 82]) == [82], "the 80-frame shot before it takes both frames")
        #expect(absorbed([50, 51, 52, 53]) == [52], "a run of one-frame shots, each into the longer side")
    }

    @Test func realShotsStay() {
        let duoCuts = [8, 114, 141, 163, 194]
        #expect(absorbed(duoCuts, frames: 230) == duoCuts)
        #expect(absorbed([4, 116]) == [4, 116], "four frames is a shot")
        #expect(absorbed([], frames: 2) == [])
    }
}
