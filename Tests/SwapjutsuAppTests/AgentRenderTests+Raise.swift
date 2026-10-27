import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// A render held over its `maxCost` is the agent's to lift: the same request with a higher `maxCost` sends it, under
/// the same checks as any agent send. The 0.5 s test clip's draft is estimated at up to $0.11.
extension AgentRenderTests {
    @Test func aHigherMaxCostOnTheSameRequestSendsARenderHeldOverIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)

        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 0.05))).renders?.first)
        #expect(held.stage == "waiting" && held.detail.contains("max_cost"))
        let lower = try #require(try await commands.run(.render(request(job, "r", maxCost: 0.01))).renders?.first)
        #expect(lower.id == held.id && lower.stage == "waiting" && lower.origin?.maxCost == 0.05)

        let tooLow = try #require(try await commands.run(.render(request(job, "r", maxCost: 0.08))).renders?.first)
        #expect(tooLow.id == held.id && tooLow.stage == "waiting" && tooLow.origin?.maxCost == 0.08)
        #expect(tooLow.detail.contains(SeedancePrice.dollars(0.08)), "\(tooLow.detail)")
        #expect(provider.submits == 0)

        let raised = try #require(try await commands.run(.render(request(job, "r", maxCost: 0.11))).renders?.first)
        #expect(raised.id == held.id && raised.stage == "uploading" && raised.origin?.maxCost == 0.11)
        await store.settle(job)
        #expect(provider.submits == 1 && store.agentSpent() == 0.11 && job.renders.count == 1)

        // Repeats after the raise, with the new limit or an old one, answer the render and send nothing.
        for maxCost in [0.11, 0.05] {
            let again = try #require(try await commands.run(.render(request(job, "r", maxCost: maxCost))).renders?.first)
            #expect(again.id == held.id && again.stage == "done")
        }
        let (_, reloaded) = make(FakeProvider(statuses: []))
        let restored = try #require(try await reloaded.run(.render(request(job, "r", maxCost: 0.11))).renders?.first)
        #expect(restored.id == held.id && restored.origin?.maxCost == 0.11)
        #expect(provider.submits == 1)
    }

    @Test func aHigherMaxCostLeavesARenderHeldForTheBudgetAsItIs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let (store, commands) = make(provider)
        let job = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        #expect(held.detail.contains("Settings › Agents"))

        let again = try #require(try await commands.run(.render(request(job, "r", maxCost: 2))).renders?.first)
        #expect(again.id == held.id && again.stage == "waiting" && again.origin?.maxCost == 1)
        #expect(provider.submits == 0)
    }

    @Test func aRaiseAfterThePersonSentTheRenderChangesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 0.05))).renders?.first)
        let render = try #require(job.render(UUID(uuidString: held.id)))
        store.retry(render, of: job, by: .person)

        let raised = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        #expect(raised.origin?.maxCost == 0.05)
        await store.settle(job)
        #expect(provider.submits == 1 && store.agentSpent() == 0, "the person's send, not the agent's")
    }

    @Test func aFinalHeldOverMaxCostIsLiftedTheSameWay() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output(task: "cgt-1")), .success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 2
        let job = try await prepared(store)
        let draft = try #require(try await commands.run(.render(request(job, "d", maxCost: 1))).renders?.first)
        await store.settle(job)

        let held = try #require(
            try await commands.run(.finalize(FinalizeCommand(render: draft.id, requestID: "f", maxCost: 0.3))).renders?
                .first)
        #expect(held.stage == "waiting" && held.high == 0.51)
        let raised = try #require(
            try await commands.run(.finalize(FinalizeCommand(render: draft.id, requestID: "f", maxCost: 0.6))).renders?
                .first)
        #expect(raised.id == held.id && raised.stage == "uploading")
        await store.settle(job)
        #expect(provider.submits == 2)
    }

    @Test func onlyMaxCostMayDifferInARepeat() {
        let render = #"{"clip":"c","command":"render","maxCost":1,"quality":"draft"}"#
        #expect(AgentCommands.sameButMaxCost(render, #"{"clip":"c","command":"render","maxCost":2.5,"quality":"draft"}"#))
        #expect(!AgentCommands.sameButMaxCost(render, #"{"clip":"c","command":"render","maxCost":1,"quality":"final720"}"#))
        #expect(
            !AgentCommands.sameButMaxCost(
                render, #"{"clip":"c","command":"render","maxCost":1,"model":"wan30","quality":"draft"}"#))
        #expect(!AgentCommands.sameButMaxCost(render, "not json"))
    }
}
