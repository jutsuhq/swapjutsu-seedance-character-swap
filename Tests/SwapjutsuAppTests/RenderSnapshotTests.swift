import Foundation
import Testing

@testable import SwapjutsuApp

/// A render keeps what it was sent with: later changes to the clip or to Settings reach new renders only.
@MainActor
@Suite(.serialized)
struct RenderSnapshotTests {
    let base = JobStoreTests()

    @Test func aRenderSavedBeforeTheSnapshotStillOpensAndOneWithItRoundTrips() throws {
        let old = """
            {"id": "\(UUID().uuidString)", "created": 0, "quality": "draft", "prompt": "", "stage": "done", "detail": ""}
            """
        let decoded = try JSONDecoder().decode(Render.self, from: Data(old.utf8))
        #expect(decoded.snapshot == nil && decoded.stage == .done)

        var render = decoded
        render.snapshot = RenderInputSnapshot(
            prompt: "Replace the person.", images: ["inputs/character-1.png"], references: ["inputs/character-1.png"],
            prepRevision: 2,
            backend: RenderBackend(
                model: .wan22Animate, comfyURL: URL(string: "http://gpu.local:8188/"), diffusionModel: "wan.safetensors"
            ))
        let again = try JSONDecoder().decode(Render.self, from: JSONEncoder().encode(render))
        #expect(again.snapshot == render.snapshot)
    }

    @Test func libraryShowsTheCharactersARenderWasSentWith() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let provider = FakeProvider(statuses: [.success(try await base.output())])
        let store = base.makeStore(provider)
        let job = try await base.prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        let sent = job.spec.references
        let snapshot = try #require(job.render(render.id)?.snapshot)
        #expect(snapshot.prepRevision == job.prepRevision && snapshot.backend.model == .seedance25)
        guard case .edit(_, let images, let prompt, _)? = provider.requests.first else {
            Issue.record("no edit was sent")
            return
        }
        #expect(snapshot.images.map(job.file(at:)) == images && snapshot.prompt == prompt)

        store.addReferences([try base.picture()], to: job, person: 1)
        #expect(job.spec.references != sent)
        let done = try #require(job.render(render.id))
        #expect(job.references(of: done) == sent)
        #expect(ResultView.offered(for: LibraryEntry(job: job, render: done)).contains(.control))

        store.prepareAgain(job)
        await store.settle(job)
        #expect(!ResultView.offered(for: LibraryEntry(job: job, render: done)).contains(.control))
    }

    /// A render sent again after its request failed goes with its own inputs, not the clip's new character.
    @Test func aResubmitSendsWhatTheRenderSentFirst() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let provider = FakeProvider(statuses: [.failure(GenerationError.rejected("busy")), .success(try await base.output())])
        let store = base.makeStore(provider)
        let job = try await base.prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .failed && job.render(render.id)?.providerJobID == nil)

        store.addReferences([try base.picture()], to: job, person: 1)
        store.retry(try #require(job.render(render.id)), of: job, by: .person)
        await store.settle(job)
        #expect(provider.submits == 2 && provider.requests[0] == provider.requests[1])
        #expect(job.render(render.id)?.stage == .done)
    }

    /// A prep run again that fails may leave the control video half written; a render sent before isn't sent again
    /// on it.
    @Test func aRetryAfterAFailedPrepAgainSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let provider = FakeProvider(statuses: [.failure(GenerationError.rejected("busy"))])
        let runs = Runs()
        let good = JobStoreTests.preparer(targets: [1])
        let store = JobStore(
            root: base.root, providers: { _ in provider },
            preparer: { spec, output, log in
                guard runs.next() > 1 else { return try await good(spec, output, log) }
                try Data("half".utf8).write(to: output.appending(path: "control.mp4"))
                throw CocoaError(.fileWriteOutOfSpace)
            }, pollInterval: .zero, maxPolls: 5)
        let job = try await base.prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .failed && provider.submits == 1)

        store.prepareAgain(job)
        await store.settle(job)
        #expect(job.stage == .failed)
        store.retry(try #require(job.render(render.id)), of: job, by: .person)
        await store.settle(job)
        let retried = try #require(job.render(render.id))
        #expect(retried.stage == .failed && retried.detail.contains("prepared again"), "\(retried.detail)")
        #expect(provider.submits == 1)
    }

    /// Prepare Again waits behind another clip's prep; a retry meanwhile doesn't send what that prep will replace.
    @Test func aRetryWhilePrepAgainWaitsSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let provider = FakeProvider(statuses: [.failure(GenerationError.rejected("busy"))])
        let (runs, gate) = (Runs(), Gate())
        let good = JobStoreTests.preparer(targets: [1])
        let store = JobStore(
            root: base.root, providers: { _ in provider },
            preparer: { spec, output, log in
                if runs.next() == 2 { await gate.wait() }
                return try await good(spec, output, log)
            }, pollInterval: .zero, maxPolls: 5)
        let job = try await base.prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .failed && provider.submits == 1)

        let other = store.enqueue(try await base.spec())
        for _ in 0..<400 where other.stage != .preparing { try await Task.sleep(for: .milliseconds(5)) }
        store.prepareAgain(job)
        #expect(job.stage == .waiting)
        store.retry(try #require(job.render(render.id)), of: job, by: .person)
        await store.settle(job)
        let retried = try #require(job.render(render.id))
        #expect(retried.stage == .failed && retried.detail.contains("prepared again"), "\(retried.detail)")
        #expect(provider.submits == 1)
        await gate.release()
        await store.settle(other)
        await store.settle(job)
    }

    /// Settings › Own ComfyUI points somewhere else after the send; the render's poll still asks the server it went to.
    @Test func aWanRenderResumesOnTheServerItWasSentTo() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: OwnComfy.enabledKey)
        defaults.set("http://127.0.0.1:8188", forKey: OwnComfy.urlKey)
        defer {
            defaults.removeObject(forKey: OwnComfy.enabledKey)
            defaults.removeObject(forKey: OwnComfy.urlKey)
        }
        let first = JobStore(
            root: base.root, providers: { _ in FakeProvider(statuses: [], cancels: false) },
            preparer: JobStoreTests.preparer(targets: [1]),
            pollInterval: .seconds(3600), maxPolls: 5)
        let job = try await base.prepared(first)
        let render = try #require(first.render(job, quality: .final480, model: .wan22Animate))
        while job.render(render.id)?.stage != .generating { await Task.yield() }
        first.cancel(render, of: job)
        await first.settle(job)

        defaults.set("http://gpu.local:8188", forKey: OwnComfy.urlKey)
        let asked = Asked()
        let provider = FakeProvider(statuses: [.success(try await base.output())])
        let second = JobStore(
            root: base.root,
            providers: { backend in
                asked.backends.append(backend)
                return provider
            }, preparer: JobStoreTests.preparer(targets: [1]), pollInterval: .zero, maxPolls: 5)
        let restored = try #require(second.job(job.id))
        second.retry(try #require(restored.render(render.id)), of: restored, by: .person)
        await second.settle(restored)
        #expect(restored.render(render.id)?.stage == .done, "\(restored.render(render.id)?.detail ?? "")")
        #expect(provider.submits == 0)
        #expect(!asked.backends.isEmpty && asked.backends.allSatisfy { $0.comfyURL?.host() == "127.0.0.1" })
    }

    final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    @MainActor
    final class Asked {
        var backends: [RenderBackend] = []
    }
}
