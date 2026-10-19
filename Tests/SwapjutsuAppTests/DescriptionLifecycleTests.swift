import Foundation
import SwapjutsuDescribe
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// A description belongs to its clip: removing the clip stops it, and a late answer never undoes what happened while
/// the model read. Through the real `JobStore`, with a describer that answers only when the test lets it.
@MainActor
@Suite(.serialized)
struct DescriptionLifecycleTests {
    let base = JobStoreTests()
    nonisolated static let answer = SceneDescription(characters: [.init(noun: "WOMAN")], source: "Stand-in")

    /// Holds every describe call until `open`.
    actor Gate {
        private(set) var calls = 0
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func pass() async {
            calls += 1
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    func store(_ gate: Gate) -> JobStore {
        JobStore(
            root: base.root, providers: { _ in FakeProvider(statuses: []) },
            preparer: JobStoreTests.preparer(targets: [1]), pollInterval: .zero, maxPolls: 5,
            describer: {
                { _, _ in
                    await gate.pass()
                    return Self.answer
                }
            })
    }

    /// A prepared clip that already has a description, so prep itself asks the model nothing.
    func prepared(_ jobs: JobStore) async throws -> Job {
        var spec = try await base.spec()
        spec.description = SceneDescription(characters: [.init(noun: "ROBOT")], source: "Earlier")
        let job = jobs.enqueue(spec)
        await jobs.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        return job
    }

    func started(_ gate: Gate, calls: Int = 1) async throws {
        for _ in 0..<400 where await gate.calls < calls { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.calls == calls)
    }

    @Test func aClipRemovedWhileItIsDescribedStaysRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let gate = Gate()
        let jobs = store(gate)
        let job = try await prepared(jobs)
        jobs.describe(job)
        try await started(gate)

        jobs.remove(job)
        #expect(!job.isDescribing)
        await gate.open()
        await jobs.settle(job)
        #expect(!FileManager.default.fileExists(atPath: job.recordURL.path), "job.json isn't written back")
        #expect(jobs.jobs.isEmpty)
        #expect(store(Gate()).jobs.isEmpty, "the clip doesn't come back on a relaunch")
    }

    @Test func anEditMadeWhileTheModelReadsSurvivesItsAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let gate = Gate()
        let jobs = store(gate)
        let job = try await prepared(jobs)
        jobs.describe(job)
        try await started(gate)

        let edited = SceneDescription(characters: [.init(noun: "KNIGHT")], source: "Edited")
        jobs.setDescription(edited, of: job)
        await gate.open()
        await jobs.settle(job)
        #expect(job.spec.description == edited && job.spec.describedByPerson == true)
        #expect(!job.isDescribing)
        let saved = try #require(store(Gate()).jobs.first { $0.id == job.id })
        #expect(saved.spec.description == edited)
    }

    /// Reading a render's prompt holds the heavy work slot like prep does, so no prep starts beside the model.
    @Test func aPromptBeingReadHoldsPrepBack() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let gate = Gate()
        let jobs = store(gate)
        let job = try await prepared(jobs)
        let reading = Task { await jobs.readWish("Make it rain.", of: job) }
        try await started(gate)
        #expect(jobs.isBusy)

        let next = jobs.enqueue(try await base.spec())
        try await Task.sleep(for: .milliseconds(100))
        #expect(next.stage == .waiting, "prep waits for the slot")
        await gate.open()
        await reading.value
        await jobs.settle(next)
        #expect(next.stage == .prepared && !jobs.isBusy)
    }

    @Test func anUntouchedClipTakesTheAnswer() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let gate = Gate()
        let jobs = store(gate)
        let job = try await prepared(jobs)
        await gate.open()
        jobs.describe(job)
        await jobs.settle(job)
        #expect(job.spec.description == Self.answer && job.spec.describedByPerson == nil)
    }

    /// The generator switched while a render's request is put together (here, while its prompt is read): the render
    /// goes to the generator it was asked of, and keeps it for a retry.
    @Test func aGeneratorPickedWhileARequestIsBuiltIsntTheRendersOwn() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let gate = Gate()
        let asked = RenderSnapshotTests.Asked()
        let jobs = JobStore(
            root: base.root,
            providers: { backend in
                asked.backends.append(backend)
                return FakeProvider(statuses: [])
            }, preparer: JobStoreTests.preparer(targets: [1]), pollInterval: .seconds(3600), maxPolls: 5,
            describer: {
                { _, _ in
                    await gate.pass()
                    return Self.answer
                }
            })
        let job = try await prepared(jobs)
        job.edit { $0.prompt = "Make it rain." }
        let render = try #require(jobs.render(job, quality: .draft, model: .seedance25))
        try await started(gate)

        jobs.setModel(.wan22Animate, of: job)
        await gate.open()
        while job.render(render.id)?.stage != .generating { await Task.yield() }
        let sent = try #require(job.render(render.id))
        #expect(job.model(of: sent) == .seedance25)
        #expect(sent.snapshot?.backend.model == .seedance25)
        #expect(!asked.backends.isEmpty && asked.backends.allSatisfy { $0.model == .seedance25 })
        jobs.cancel(sent, of: job)
        await jobs.settle(job)
    }
}
