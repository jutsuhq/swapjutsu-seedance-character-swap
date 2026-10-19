import Foundation
import Testing

@testable import SwapjutsuApp

/// A paid request is never lost or sent twice: not by a stop the provider can't honour, not by a job.json that can't
/// be written.
extension JobStoreTests {
    /// The direct route can't cancel a Seedance task: stopping keeps the paid request, and Resume polls it.
    @Test func stoppingAnUncancelableRenderKeepsItsRequestForResume() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [], cancels: false)
        let store = makeStore(provider, poll: .seconds(3600))
        let job = try await prepared(store)
        let render = try #require(store.render(job, quality: .draft))
        while job.render(render.id)?.stage != .generating { await Task.yield() }
        store.cancel(render, of: job)
        await store.settle(job)
        let stopped = try #require(job.render(render.id))
        #expect(stopped.stage == .canceled && stopped.providerJobID == "r1")
        #expect(stopped.detail.contains("charged"), "\(stopped.detail)")
        #expect(provider.canceled == ["r1"])
        let saved = try #require(try JobRecord.decode(Data(contentsOf: job.recordURL)))
        #expect(saved.renders.first?.providerJobID == "r1", "the kept request survives a relaunch")

        provider.answer(.success(try await output()))
        store.retry(stopped, of: job, by: .person)
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .done, "\(job.render(render.id)?.detail ?? "")")
        #expect(job.render(render.id)?.generated == "seedance-r1.mp4")
        #expect(provider.submits == 1)
    }

    @Test func aJobThatCantBeSavedSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let store = makeStore(provider)
        let job = try await prepared(store)
        try readOnly(job.output, true)
        defer { try? readOnly(job.output, false) }
        let render = try #require(store.render(job, quality: .draft))
        await store.settle(job)
        let stopped = try #require(job.render(render.id))
        #expect(stopped.stage == .failed && stopped.detail.hasPrefix("Nothing was sent"), "\(stopped.detail)")
        #expect(provider.submits == 0)
    }

    /// The ID of a request just paid for that can't be written is shown with the ID, saved again until it lands, and
    /// the render goes on with the same request.
    @Test func aSentRequestThatCantBeSavedIsShownAndSavedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let store = makeStore(provider)
        let job = try await prepared(store)
        let folder = job.output
        provider.onSubmit = { try? Self.setReadOnly(folder, true) }
        defer { try? readOnly(job.output, false) }
        let render = try #require(store.render(job, quality: .draft))
        while !store.unsaved.contains(render.id) { await Task.yield() }
        let shown = try #require(job.render(render.id))
        #expect(shown.detail.contains("r1") && shown.detail.contains("couldn't be saved"), "\(shown.detail)")
        let onDisk = try #require(try JobRecord.decode(Data(contentsOf: job.recordURL)))
        #expect(onDisk.renders.first?.providerJobID == nil, "the folder refused the write")

        try readOnly(job.output, false)
        while store.unsaved.contains(render.id) { await Task.yield() }
        let saved = try #require(try JobRecord.decode(Data(contentsOf: job.recordURL)))
        #expect(saved.renders.first?.providerJobID == "r1")
        await store.settle(job)
        #expect(job.render(render.id)?.stage == .done, "\(job.render(render.id)?.detail ?? "")")
        #expect(provider.submits == 1)
    }

    private func readOnly(_ folder: URL, _ isReadOnly: Bool) throws { try Self.setReadOnly(folder, isReadOnly) }

    nonisolated private static func setReadOnly(_ folder: URL, _ isReadOnly: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: isReadOnly ? 0o555 : 0o755], ofItemAtPath: folder.path)
    }
}
