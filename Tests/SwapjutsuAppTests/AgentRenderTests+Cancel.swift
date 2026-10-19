import ComfyKit
import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// A cancel during the paid request doesn't say whether it reached Comfy, so the render's outcome is unknown and an
/// agent can't send it again; a cancel during the uploads before it sent nothing and can be retried.
extension AgentRenderTests {
    @Test func aCancelDuringThePaidRequestLeavesItToThePerson() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [], hang: .send)
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        let id = try #require(UUID(uuidString: sent.id))
        while provider.submits == 0 { await Task.yield() }

        _ = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .cancel)))
        await store.settle(job)
        let stopped = try #require(job.render(id))
        #expect(stopped.stage == .unknown, "\(stopped.stage): \(stopped.detail)")
        #expect(stopped.detail.contains("check your history"), "\(stopped.detail)")
        await #expect(throws: AgentError.Code.needsPerson) {
            try await code { try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .retry))) }
        }
        await store.settle(job)
        #expect(provider.submits == 1)
        #expect(store.agentSpent() == 0.11, "it may have been paid, so it still counts")
    }

    @Test func aCancelDuringTheUploadsSendsNothingAndCanBeRetried() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [], hang: .upload)
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        let id = try #require(UUID(uuidString: sent.id))
        while job.render(id)?.detail.hasPrefix("Uploading") != true { await Task.yield() }

        _ = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .cancel)))
        await store.settle(job)
        let stopped = try #require(job.render(id))
        #expect(stopped.stage == .canceled && stopped.detail == "Canceled before the request was sent")
        #expect(provider.submits == 0 && store.agentSpent() == 0, "nothing was sent, so nothing is counted")

        let retried = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .retry)))
        #expect(retried.renders?.first?.stage == "uploading", "\(retried.renders?.first?.detail ?? "")")
        _ = try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .cancel)))
        await store.settle(job)
    }

    @Test func anInFlightCreateTheClientStoppedWaitingForIsUnknown() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inFlight = ComfyError.rejected(status: 409, code: ComfyError.inFlight, message: "Still running.")
        let provider = FakeProvider(statuses: [], submitError: inFlight, sendsOnce: true)
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        await store.settle(job)
        #expect(job.render(UUID(uuidString: sent.id))?.stage == .unknown)
        await #expect(throws: AgentError.Code.needsPerson) {
            try await code { try await commands.run(.jobAction(JobActionCommand(job: sent.id, action: .retry))) }
        }
        #expect(provider.submits == 1)
    }

    @Test func anAgentCantCancelThePersonsRender() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        var mine = Render(quality: .draft, prompt: "")
        mine.stage = .generating
        mine.providerJobID = "cgt-person"
        job.renders.append(mine)
        await #expect(throws: AgentError.Code.needsPerson) {
            try await code {
                try await commands.run(.jobAction(JobActionCommand(job: mine.id.uuidString, action: .cancel)))
            }
        }
        #expect(job.render(mine.id)?.stage == .generating && job.render(mine.id)?.providerJobID == "cgt-person")
    }

    /// A stopped final isn't sent again while its draft has another final on its way or done: that would pay for
    /// two 1080p renders of one draft.
    @Test func aFinalIsntRetriedNextToAnotherFinalOfItsDraft() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [])
        let (store, _) = make(provider)
        let job = try await prepared(store)
        var draft = Render(quality: .draft, prompt: "")
        draft.stage = .done
        draft.draftTaskID = "cgt-0"
        var failed = Render(quality: .final1080, parent: draft.id, prompt: "")
        failed.stage = .failed
        var done = Render(quality: .final1080, parent: draft.id, prompt: "")
        done.stage = .done
        job.renders += [draft, failed, done]

        store.retry(failed, of: job, by: .person)
        await store.settle(job)
        #expect(provider.submits == 0 && job.render(failed.id)?.stage == .failed)
    }

    /// A request the provider no longer knows can't be resumed: its ID goes, so Retry sends a new one instead of
    /// failing the same way forever.
    @Test func aRequestComfyNoLongerHasIsLetGo() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.failure(ComfyError.notFound("no task cgt-1"))])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        await store.settle(job)
        let stopped = try #require(job.render(UUID(uuidString: sent.id)))
        #expect(stopped.stage == .failed && stopped.providerJobID == nil, "\(stopped.stage): \(stopped.detail)")
        #expect(stopped.detail.contains("full price"))
    }
}
