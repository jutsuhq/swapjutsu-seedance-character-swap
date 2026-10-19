import Foundation
import Testing

@testable import SwapjutsuApp

/// Images moved between people in Create (#60), through the store the drag calls.
extension JobStoreTests {
    @Test func anImageOfTheClipIsMovedNotCopied() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(FakeProvider(statuses: []), targets: [1, 2])
        let job = try await prepared(store)
        store.addReferences([try picture()], to: job, person: 2)
        let (a, b) = (job.spec.references[0], job.spec.references[1])
        store.addReferences([b], to: job, person: 1)
        #expect(job.spec.references == [a, b] && job.cast.map(\.images) == [[1], [0]], "the two swap")
        store.addReferences([a], to: job, person: 1, asView: true)
        #expect(job.cast.map(\.images) == [[1, 0], []])
        store.addReferences([a], to: job)
        #expect(job.cast.map(\.images) == [[1], []] && job.spec.extras(for: [1, 2]) == [0])
    }
}
