import Foundation
import Testing

@testable import SwapjutsuApp

/// A stopped render whose request may still run stays in Jobs: Dismiss can't hide it, nor can removing its clip.
@MainActor
@Suite(.serialized)
struct DismissTests {
    let base = JobStoreTests()

    @Test func onlyARenderWithoutALiveRequestCanBeDismissed() {
        var render = Render(quality: .draft, prompt: "")
        render.stage = .canceled
        #expect(render.canDismiss, "canceled before it was sent")
        render.providerJobID = "r1"
        #expect(!render.canDismiss, "Seedance couldn't cancel it")
        render.stage = .failed
        #expect(!render.canDismiss, "a failed poll keeps the request")
        render.stage = .done
        #expect(render.canDismiss, "a result")
        render.stage = .generating
        render.providerJobID = nil
        #expect(!render.canDismiss, "on its way")
    }

    @Test func aRenderWhoseRequestMayStillRunStaysWithItsClip() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let store = base.makeStore(FakeProvider(statuses: [.failure(URLError(.networkConnectionLost))]))
        let job = try await base.prepared(store)
        let render = try #require(store.render(job, quality: .draft, model: .seedance25))
        await store.settle(job)
        let stopped = try #require(job.render(render.id))
        #expect(stopped.stage == .failed && stopped.providerJobID != nil)

        store.remove(stopped, of: job)
        #expect(job.render(render.id) != nil)
        store.remove(job)
        #expect(store.jobs.contains { $0.id == job.id })
    }
}
