import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// What an agent spent today stays spent: the ledger keeps each send let through, whatever happens to its render.
extension AgentRenderTests {
    @Test func dismissingARenderOrRemovingItsClipGivesNoBudgetBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 0.18
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r1", maxCost: 1))).renders?.first)
        await store.settle(job)
        let render = try #require(job.render(UUID(uuidString: sent.id)))
        #expect(render.stage == .done && store.agentSpent() == 0.11)

        store.remove(render, of: job)
        #expect(job.renders.isEmpty && store.agentSpent() == 0.11, "a dismissed render still counts")
        store.remove(job)
        #expect(store.jobs.isEmpty && store.agentSpent() == 0.11, "a removed clip still counts")

        let second = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(second, "r2", maxCost: 1))).renders?.first)
        #expect(held.stage == "waiting", "today's $0.18 has $0.07 left")
        #expect(provider.submits == 1)
        #expect(make(FakeProvider(statuses: [])).0.agentSpent() == 0.11, "the ledger is on disk")
    }

    /// A version before the ledger counted the renders' sends; the first launch with it starts from them.
    @Test func theLedgerStartsFromTheSendsTheRendersList() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: [.success(try await output())]))
        budget.dollars = 1
        let job = try await prepared(store)
        _ = try await commands.run(.render(request(job, "r1", maxCost: 1)))
        await store.settle(job)
        try FileManager.default.removeItem(at: root.appending(path: "agent-spend.json"))

        let (reloaded, _) = make(FakeProvider(statuses: []))
        #expect(reloaded.agentSpent() == 0.11)
        let restored = try #require(reloaded.job(job.id))
        reloaded.remove(try #require(restored.renders.first), of: restored)
        #expect(reloaded.agentSpent() == 0.11)
        #expect(make(FakeProvider(statuses: [])).0.agentSpent() == 0.11, "seeded once, then read")
    }

    /// Money from an agent or from Settings is capped where it comes in, and no amount crashes the budget's sums.
    @Test func aHugeMaxCostIsRefusedAndAHugeBudgetCapped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output(task: "cgt-1"))])
        let (store, commands) = make(provider)
        let job = try await prepared(store)
        for maxCost in [1e20, 10_000.01, .greatestFiniteMagnitude] {
            await #expect(throws: AgentError.Code.badRequest) {
                try await code { try await commands.run(.render(request(job, "huge", maxCost: maxCost))) }
            }
        }
        #expect(job.renders.isEmpty)

        let name = "AgentRenderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1e20, forKey: AgentPreferences.budgetKey)
        let saved = AgentPreferences(defaults: defaults, domain: name).dailyBudget
        #expect(saved == AgentPreferences.maxDollars)
        budget.dollars = saved
        let sent = try #require(try await commands.run(.render(request(job, "top", maxCost: 10_000))).renders?.first)
        #expect(sent.stage == "uploading")
        await store.settle(job)
        #expect(provider.submits == 1 && store.agentSpent() == 0.11)

        // The guard reads the budget closure as it is; even an unclamped huge one only lets the send through.
        budget.dollars = 1e300
        let final = FinalizeCommand(render: sent.id, requestID: "f", maxCost: 1)
        #expect(try await commands.run(.finalize(final)).renders?.first?.stage == "uploading")
        await #expect(throws: AgentError.Code.badRequest) {
            try await code {
                try await commands.run(.finalize(FinalizeCommand(render: sent.id, requestID: "f2", maxCost: 1e20)))
            }
        }
        await store.settle(job)
        #expect(JobStore.cents(1e20) == Int.max / 2 && JobStore.cents(-1e300) == -Int.max / 2)
        #expect(JobStore.cents(.nan) == Int.max / 2 && JobStore.cents(12.34) == 1234)
    }
}
