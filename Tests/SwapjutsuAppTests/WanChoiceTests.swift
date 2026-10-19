import Foundation
import Testing

@testable import SwapjutsuApp

/// Wan 2.2 Animate in Create: offered only for an own ComfyUI that passed its Check, picked per clip, and named as
/// Wan wherever its renders show.
@MainActor
@Suite(.serialized)
struct WanChoiceTests {
    let base = JobStoreTests()

    @Test func wanIsOfferedOnlyForTheAddressThatPassedItsCheck() throws {
        let url = try #require(OwnComfy.parse("192.168.1.20:8188")).absoluteString
        #expect(OwnComfy.isReady(enabled: true, address: "192.168.1.20:8188", checked: url))
        #expect(!OwnComfy.isReady(enabled: true, address: "192.168.1.20:8188", checked: ""), "never checked")
        #expect(!OwnComfy.isReady(enabled: true, address: "192.168.1.21:8188", checked: url), "another address")
        #expect(!OwnComfy.isReady(enabled: false, address: "192.168.1.20:8188", checked: url), "turned off")
    }

    @Test func pickingWanOnAClipKeepsItsEarlierRendersSeedanceAndFinalizesWithSeedance() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let store = base.makeStore(FakeProvider(statuses: [.success(try await base.output(task: "t1"))]))
        let job = try await base.prepared(store)
        let other = try await base.prepared(store)
        let draft = try #require(store.render(job, quality: .draft, model: .seedance25))
        await store.settle(job)

        store.setModel(.wan22Animate, of: job)
        #expect(job.model == .wan22Animate && other.model == .seedance25, "only this clip")
        let done = try #require(job.render(draft.id))
        #expect(job.model(of: done) == .seedance25 && job.name(of: done) == "Draft 1")

        let final = try #require(store.finalize(done, of: job))
        #expect(job.model(of: final) == .seedance25)
    }

    @Test func aWanRenderSaysWanWhileItRuns() {
        let spec = JobSpec(
            title: "Solo", source: URL(filePath: "/jobs/solo/source.mov"), references: [], prompt: "", target: .main,
            faceGuide: false, model: .wan22Animate)
        let job = Job(spec: spec, output: URL(filePath: "/jobs/solo"))
        var render = Render(quality: .final720, prompt: "")
        render.stage = .generating
        #expect(job.stageTitle(of: render) == "Wan rendering")
        #expect(job.cancelHelp(of: render) == "Stop the render on your ComfyUI")
        render.model = .seedance25
        #expect(job.stageTitle(of: render) == "Seedance rendering")
    }
}
