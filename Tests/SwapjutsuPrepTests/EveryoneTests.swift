import Testing

@testable import SwapjutsuPrep

/// `--target all` on a two-person clip: two dancers in all 168 frames, and two one-frame fragments of one of them.
struct EveryoneTests {
    @Test func everyoneLeavesOutPeopleSeenInAFrameOrTwo() {
        let minFrames = Tuning().minTrackletFrames
        #expect(Pipeline.everyone(frames: [168, 168, 1, 1], minFrames: minFrames) == [1, 2])
        #expect(Pipeline.everyone(frames: [120, 3], minFrames: minFrames) == [1, 2], "three frames is a person")
        #expect(Pipeline.everyone(frames: [2, 1], minFrames: minFrames) == [1, 2], "only fragments: all of them")
    }
}
