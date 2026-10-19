import Foundation
import Testing

@testable import SwapjutsuApp

/// Who is replaced, picked in Create: Main and Everyone stay presets, any other pick is stored as people and kept by
/// Prepare Again. Prep is the two-person stand-in from `AgentPrepTests`.
@MainActor
@Suite(.serialized)
struct ReplaceChoiceTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-replace-\(UUID().uuidString)")
    let found = [1, 2, 3]

    @Test func aPickThatMatchesAPresetIsThePreset() {
        let main = ReplaceChoice.preset(.main)
        #expect(main.ids(of: found) == [1])
        #expect(main.toggling(2, of: found) == .people([1, 2]))
        #expect(main.toggling(2, of: found).toggling(3, of: found) == .preset(.all))
        #expect(main.toggling(1, of: found) == main, "the last person replaced stays")
        #expect(ReplaceChoice.preset(.all).toggling(1, of: found) == .people([2, 3]))
        #expect(ReplaceChoice.people([2]).toggling(1, of: found).toggling(2, of: found) == .preset(.main))
        #expect(ReplaceChoice.preset(.all).ids(of: [1]) == [1])
    }

    @Test func thePersonPickedIsReplacedAndKeptByPrepareAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(
            root: root, providers: { _ in throw GenerationError.noKey }, preparer: AgentPrepTests.preparer(nil))
        let job = store.enqueue(
            JobSpec(
                title: "duo", source: try await AgentPrepTests.video(), references: [], prompt: "", target: .main,
                faceGuide: false, model: .seedance25))
        await store.settle(job)
        #expect(ReplaceChoice(job.spec) == .preset(.main) && job.manifest?.targets == [1])

        let right = ReplaceChoice(job.spec).toggling(2, of: [1, 2]).toggling(1, of: [1, 2])
        store.prepareAgain(job, replacing: right, faceGuide: false, replaceBackground: false)
        await store.settle(job)
        #expect(job.spec.targetIDs == [2] && job.manifest?.targets == [2])
        store.prepareAgain(job)
        await store.settle(job)
        #expect(ReplaceChoice(job.spec) == .people([2]) && job.manifest?.targets == [2])

        store.prepareAgain(job, replacing: .preset(.all), faceGuide: false, replaceBackground: false)
        await store.settle(job)
        #expect(job.spec.targetIDs == nil && job.spec.target == .all && job.manifest?.targets == [1, 2])
    }
}
