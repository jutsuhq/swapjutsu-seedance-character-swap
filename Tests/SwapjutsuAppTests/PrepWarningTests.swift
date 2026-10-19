import Testing

@testable import SwapjutsuApp

/// Prep's look-alike warning reads as a sentence; its numbers and file name stay in Details.
struct PrepWarningTests {
    @Test func theLookAlikeWarningReadsAsASentenceWithItsNumbersInDetails() {
        let raw = "People 4 and 5 look alike (distance 0.38, merge below 0.33); check review.mp4"
        let warning = PrepWarning(raw)
        #expect(warning.sentence == "People 4 and 5 look alike — check Review.")
        #expect(warning.detail == raw)
    }

    @Test func anOrdinaryWarningStaysAsItIs() {
        let warning = PrepWarning("The target is on screen in under half of the clip")
        #expect(warning.sentence == "The target is on screen in under half of the clip" && warning.detail == nil)
    }
}
