import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

// MARK: A replaced background

extension JobStoreTests {
    /// With the background replaced the place goes right after the characters, before the extras, and the request
    /// waits for it.
    @Test func theNewBackgroundUploadsAfterTheCharacters() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let store = makeStore(provider, background: .replace)
        var replaced = try await spec()
        replaced.replaceBackground = true
        #expect(replaced.options.background == .replace)
        let job = store.enqueue(replaced)
        await store.settle(job)
        #expect(job.missingBackground)
        let refused = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        #expect(job.render(refused.id)?.stage == .failed && provider.submits == 0)

        store.addReferences([try picture()], to: job)
        #expect(store.setBackground(try picture(), of: job) == nil)
        let place = try #require(job.spec.background)
        #expect(place.path.hasPrefix(job.output.appending(path: "inputs").path) && !job.missingBackground)
        store.render(job, quality: .draft)
        await store.settle(job)
        guard case .edit(_, let images, _, _) = provider.requests.first else {
            Issue.record("no edit was sent")
            return
        }
        #expect(images == [job.spec.references[0], place, job.spec.references[1]])
    }

    /// A background image left on a clip prepared again without the replaced background stays unsent.
    @Test func aKeptBackgroundSendsNoPlace() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let store = makeStore(provider)
        let job = try await prepared(store)
        store.setBackground(try picture(), of: job)
        store.render(job, quality: .draft)
        await store.settle(job)
        guard case .edit(_, let images, _, _) = provider.requests.first else {
            Issue.record("no edit was sent")
            return
        }
        #expect(images == job.spec.references)
    }
}
