import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// The ledger's entry for an agent's send is written before the paid request, or the request doesn't go; and a send
/// a render lists but the ledger lost is counted again on the next launch.
extension AgentRenderTests {
    @Test func aLedgerThatCantBeWrittenStopsTheSend() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        // A folder where the ledger's file goes: the atomic write can't replace it.
        let ledger = root.appending(path: "agent-spend.json")
        try? FileManager.default.removeItem(at: ledger)
        let blocked = ledger.appending(path: "blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        let sent = try #require(try await commands.run(.render(request(job, "r1", maxCost: 1))).renders?.first)
        await store.settle(job)
        let render = try #require(job.render(UUID(uuidString: sent.id)))
        #expect(render.stage == .failed && render.detail.contains("ledger"), "\(render.detail)")
        #expect(provider.submits == 0)
        #expect(store.agentSpent() == 0 && render.origin?.sends.isEmpty == true)
    }

    @Test func sendsTheLedgerLostAreCountedAgainOnLoad() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: [.success(try await output())]))
        budget.dollars = 1
        let job = try await prepared(store)
        _ = try await commands.run(.render(request(job, "r1", maxCost: 1)))
        await store.settle(job)
        #expect(store.agentSpent() == 0.11)
        // job.json listed the send, but the ledger's write of it never landed.
        try Data("[]".utf8).write(to: root.appending(path: "agent-spend.json"))

        #expect(make(FakeProvider(statuses: [])).0.agentSpent() == 0.11)
        #expect(make(FakeProvider(statuses: [])).0.agentSpent() == 0.11, "added back once, not on every load")
    }

    /// A request that never reached Comfy (no connection) charged nothing, so its reservation goes back.
    @Test func aSendThatNeverConnectedGivesTheBudgetBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [], submitError: URLError(.cannotConnectToHost), sendsOnce: true)
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r1", maxCost: 1))).renders?.first)
        await store.settle(job)
        let render = try #require(job.render(UUID(uuidString: sent.id)))
        #expect(render.stage == .failed && provider.submits == 1)
        #expect(store.agentSpent() == 0 && render.origin?.sends.isEmpty == true)
    }
}
