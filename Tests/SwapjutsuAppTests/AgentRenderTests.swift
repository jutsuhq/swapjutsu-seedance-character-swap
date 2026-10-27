import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// quote, render, finalize and job_action against a real `JobStore` with the fake provider: what an agent may send,
/// what waits for the person, and that a request id means one render. Nothing reaches the network.
///
/// The test clip is 0.5 s: a draft is estimated at $0.08–0.11, a 1080p final at $0.51.
@MainActor
@Suite(.serialized)
struct AgentRenderTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-renders-\(UUID().uuidString)")
    /// What Settings › Agents › daily agent budget says; $0 unless a test sets it.
    let budget = Budget()

    @Test func theBudgetIsZeroUntilThePersonSetsIt() throws {
        let name = "AgentRenderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AgentPreferences(defaults: defaults, domain: name).dailyBudget == 0)
        // A launch argument isn't the person's setting.
        defaults.setVolatileDomain([AgentPreferences.budgetKey: 50.0], forName: UserDefaults.argumentDomain)
        defer { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        #expect(AgentPreferences(defaults: defaults, domain: name).dailyBudget == 0)
        #expect(AgentPreferences(defaults: defaults, domain: nil).dailyBudget == 50, "the swift run executable")
        defaults.set(2.5, forKey: AgentPreferences.budgetKey)
        #expect(AgentPreferences(defaults: defaults, domain: name).dailyBudget == 2.5)
        defaults.set(-3.0, forKey: AgentPreferences.budgetKey)
        #expect(AgentPreferences(defaults: defaults, domain: name).dailyBudget == 0)
    }

    @Test func withNoBudgetAnAgentQuotesButItsRenderWaitsForThePerson() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        let job = try await prepared(store)

        let quote = try #require(try await commands.run(.quote(QuoteCommand(clip: id(job), quality: .draft))).quote)
        #expect(quote.low == 0.08 && quote.high == 0.11 && quote.isEstimate && quote.seconds == 0.5)
        #expect(quote.budget == AgentBudget(daily: 0, spentToday: 0))

        let render = try await commands.run(.render(request(job, "r1", maxCost: 5))).renders?.first
        #expect(render?.stage == "waiting")
        #expect(render?.detail.contains("Settings › Agents") == true, "\(render?.detail ?? "")")
        #expect(render?.origin?.maxCost == 5 && render?.origin?.client == "Test Agent")
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.submits == 0)
        #expect(store.activeCount == 1, "the Jobs badge counts it")
        #expect(WorkSection.of(store.jobs).first?.title == "Waiting for you")
    }

    @Test func overMaxCostWaitsAndAtMaxCostIsSent() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 100
        let job = try await prepared(store)

        let over = try #require(try await commands.run(.render(request(job, "cheap", maxCost: 0.10))).renders?.first)
        #expect(over.stage == "waiting" && over.detail.contains("max_cost"), "\(over.detail)")
        #expect(provider.submits == 0)

        let exact = try #require(try await commands.run(.render(request(job, "exact", maxCost: 0.11))).renders?.first)
        #expect(exact.stage == "uploading")
        await store.settle(job)
        #expect(provider.submits == 1)
        #expect(job.render(UUID(uuidString: exact.id))?.stage == .done)
        #expect(store.agentSpent() == 0.11)
    }

    @Test func overTheBudgetWaitsCountingRendersOnTheirWay() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let (store, commands) = make(provider, poll: .seconds(3600))
        budget.dollars = 0.18
        let first = try await prepared(store)
        let second = try await prepared(store)

        let going = try #require(try await commands.run(.render(request(first, "a", maxCost: 1))).renders?.first)
        let render = try #require(first.render(UUID(uuidString: going.id)))
        while first.render(render.id)?.stage != .generating { await Task.yield() }
        #expect(store.agentSpent() == 0.11, "a render on its way counts")

        let held = try #require(try await commands.run(.render(request(second, "b", maxCost: 1))).renders?.first)
        #expect(held.stage == "waiting", "\(held.detail)")
        let left = "\(SeedancePrice.dollars(0.07)) left of today's \(SeedancePrice.dollars(0.18))"
        #expect(held.detail.contains(left), "\(held.detail)")
        let quote = try #require(try await commands.run(.quote(QuoteCommand(clip: id(second), quality: .draft))).quote)
        #expect(quote.budget.remaining == 0.07)
        #expect(provider.submits == 1)

        store.cancel(render, of: first)
        await store.settle(first)
    }

    @Test func anAgentsRetryIsCheckedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // The provider takes the request, then fails it: the send is spent, and a retry is a new send.
        let provider = FakeProvider(
            statuses: [.failure(GenerationError.rejected("Seedance refused it.")), .success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 0.18
        let job = try await prepared(store)

        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        await store.settle(job)
        let id = try #require(UUID(uuidString: sent.id))
        #expect(job.render(id)?.stage == .failed && job.render(id)?.providerJobID == nil)

        let retried = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .retry)))
        #expect(retried.renders?.first?.stage == "waiting", "\(retried.renders?.first?.detail ?? "")")
        #expect(provider.submits == 1, "today's $0.18 has $0.07 left")

        budget.dollars = 1
        _ = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .retry)))
        await store.settle(job)
        #expect(provider.submits == 2)
        #expect(job.render(id)?.stage == .done && store.agentSpent() == 0.22)
    }

    @Test func aRetryResumesARequestItHasWithoutSendingAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(
            statuses: [.failure(URLError(.networkConnectionLost)), .success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        await store.settle(job)
        let id = try #require(UUID(uuidString: sent.id))
        #expect(job.render(id)?.stage == .failed && job.render(id)?.providerJobID == "r1")

        budget.dollars = 0
        _ = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .retry)))
        await store.settle(job)
        #expect(job.render(id)?.stage == .done && provider.submits == 1, "resumed for free, past a $0 budget")
    }

    @Test func theSameRequestIDReturnsTheSameRenderAlsoAfterAReload() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        let first = try #require(try await commands.run(.render(request(job, "same", maxCost: 2))).renders?.first)
        let again = try #require(try await commands.run(.render(request(job, "same", maxCost: 2))).renders?.first)
        #expect(again.id == first.id && job.renders.count == 1)

        let (reloaded, reloadedCommands) = make(FakeProvider(statuses: []))
        let restored = try #require(reloaded.job(job.id))
        let third = try #require(
            try await reloadedCommands.run(.render(request(restored, "same", maxCost: 2))).renders?.first)
        #expect(third.id == first.id && third.stage == "waiting" && restored.renders.count == 1)
        #expect(third.origin == first.origin)
    }

    @Test func theSameRequestIDWithOtherParametersIsAConflict() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        _ = try await commands.run(.render(request(job, "one", maxCost: 2)))
        await #expect(throws: AgentError.Code.requestConflict) {
            try await code { try await commands.run(.render(request(job, "one", quality: .final720, maxCost: 2))) }
        }
        let finalize = FinalizeCommand(render: job.renders[0].id.uuidString, requestID: "one", maxCost: 2)
        await #expect(throws: AgentError.Code.requestConflict) {
            try await code { try await commands.run(.finalize(finalize)) }
        }
        let prepare = PrepareCommand(requestID: "one", video: "/v.mov", file: "/nowhere/v.mov")
        await #expect(throws: AgentError.Code.requestConflict) {
            try await code { try await commands.run(.prepare(prepare)) }
        }
        #expect(job.renders.count == 1)
    }

    @Test func aPersonsSendIgnoresTheAgentBudget() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        let job = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 0))).renders?.first)
        let render = try #require(job.render(UUID(uuidString: held.id)))
        #expect(render.stage == .waiting)
        #expect(job.retryTitle(of: render) == "Send · " + SeedancePrice.text(seconds: 0.5, quality: .draft))

        store.retry(render, of: job, by: .person)
        await store.settle(job)
        #expect(provider.submits == 1 && job.render(render.id)?.stage == .done)
        #expect(store.agentSpent() == 0, "the person's send isn't the agents'")
    }

    @Test func aDraftIsFinalizedWithinItsWeekUnderTheSameLimits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output(task: "cgt-1"))])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let draft = try #require(try await commands.run(.render(request(job, "d", maxCost: 1))).renders?.first)
        await store.settle(job)
        let done = try #require(try await commands.run(.clips(ClipsCommand(clip: id(job)))).renders?.first)
        #expect(done.id == draft.id && done.stage == "done" && done.finalizableUntil != nil)

        let tight = FinalizeCommand(render: draft.id, requestID: "f-tight", maxCost: 0.3)
        let waiting = try #require(try await commands.run(.finalize(tight)).renders?.first)
        #expect(waiting.stage == "waiting" && waiting.draft == draft.id && waiting.high == 0.51)
        await #expect(throws: AgentError.Code.notFinalizable) {
            try await code {
                try await commands.run(.finalize(FinalizeCommand(render: draft.id, requestID: "f2", maxCost: 1)))
            }
        }
        #expect(provider.submits == 1)

        var old = Render(quality: .draft, prompt: "", created: Date().addingTimeInterval(-8 * 24 * 3600))
        old.stage = .done
        old.draftTaskID = "cgt-0"
        job.renders.append(old)
        await #expect(throws: AgentError.Code.notFinalizable) {
            try await code {
                try await commands.run(
                    .finalize(FinalizeCommand(render: old.id.uuidString, requestID: "f3", maxCost: 1)))
            }
        }
    }

    @Test func cancelEndsAWaitingRenderWithoutSendingIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let (store, commands) = make(provider)
        let job = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        let canceled = try await commands.run(.jobAction(JobActionCommand(job: held.id, action: .cancel)))
        #expect(canceled.renders?.first?.stage == "canceled" && provider.submits == 0)
    }

    @Test func renderNeedsAPreparedClipWithItsCharacters() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []), targets: [1, 2])
        let job = try await prepared(store)
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.render(request(job, "r", maxCost: 1))) }
        }
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.render(request(job, "r", maxCost: -1))) }
        }
        #expect(job.renders.isEmpty)
    }
}

// MARK: Helpers

extension AgentRenderTests {
    final class Budget {
        var dollars = 0.0
    }

    func make(
        _ provider: FakeProvider, poll: Duration = .zero, targets: [Int] = [1]
    ) -> (JobStore, AgentCommands) {
        let budget = budget
        let store = JobStore(
            root: root, providers: { _ in provider }, preparer: JobStoreTests.preparer(targets: targets),
            pollInterval: poll, maxPolls: 5, agentBudget: { budget.dollars })
        let commands = AgentCommands(
            credentials: Credentials(
                comfy: ComfyKeyStore(secret: KeychainSecret(service: "com.jutsustudio.swapjutsu.tests.agents"))),
            depth: DepthModel(load: { _ in throw CancellationError() }), navigation: Navigation(), jobs: store,
            inbox: root.appending(path: "inbox"), bringForward: {})
        return (store, commands)
    }

    /// A prepared clip with a character for its one replaced person.
    func prepared(_ store: JobStore) async throws -> Job {
        let inputs = root.appending(path: "originals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let video = inputs.appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: try await JobStoreTests().clip(), to: video)
        let image = inputs.appending(path: "hero.png")
        try Data(base64Encoded: JobStoreTests.onePixelPNG)?.write(to: image)
        let job = store.enqueue(
            JobSpec(
                title: "clip", source: video, references: [image], prompt: "", target: .main, faceGuide: false,
                model: .seedance25))
        await store.settle(job)
        #expect(job.stage == .prepared, "\(job.detail)")
        return job
    }

    func id(_ job: Job) -> String { job.id.uuidString }

    func output(task: String? = nil) async throws -> GenerationOutput {
        GenerationOutput(video: try await JobStoreTests().clip(), draftTaskID: task)
    }

    func request(
        _ job: Job, _ requestID: String, quality: AgentQuality = .draft, maxCost: Double
    ) -> RenderCommand {
        RenderCommand(clip: id(job), quality: quality, requestID: requestID, maxCost: maxCost, client: "Test Agent")
    }

    func code<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as AgentError {
            throw error.code
        }
    }
}
