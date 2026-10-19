import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

// MARK: Wan 2.2 Animate

@MainActor
extension AgentRenderTests {
    /// Turns Settings › Own ComfyUI on for the test process for `work`, with a passed Check unless `checked` is false.
    private func withOwnComfy<T>(checked: Bool = true, _ work: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: OwnComfy.enabledKey)
        defaults.set("http://127.0.0.1:8188", forKey: OwnComfy.urlKey)
        if checked { defaults.set("http://127.0.0.1:8188/", forKey: OwnComfy.checkedKey) }
        defer {
            defaults.removeObject(forKey: OwnComfy.enabledKey)
            defaults.removeObject(forKey: OwnComfy.urlKey)
            defaults.removeObject(forKey: OwnComfy.checkedKey)
        }
        return try await work()
    }

    @Test func aWanQuoteIsFree() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        let quote = try #require(
            try await commands.run(.quote(QuoteCommand(clip: id(job), quality: .final480, model: .wan22Animate))).quote)
        #expect(quote.low == 0 && quote.high == 0 && quote.model == .wan22Animate)
        let seedance = try #require(try await commands.run(.quote(QuoteCommand(clip: id(job), quality: .draft))).quote)
        #expect(seedance.model == nil)
    }

    @Test func aWanRenderIsSentWithANoDollarBudget() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output())])
        let (store, commands) = make(provider)
        let job = try await prepared(store)
        let command = RenderCommand(
            clip: id(job), quality: .final480, requestID: "wan", maxCost: 0, client: "Test Agent",
            model: .wan22Animate)

        let sent = try await withOwnComfy { try await commands.run(.render(command)).renders?.first }
        let render = try #require(sent)
        #expect(render.stage == "uploading", "\(render.detail)")
        #expect(render.model == .wan22Animate)
        await store.settle(job)
        #expect(provider.submits == 1)
        guard case .animate(_, _, _, _, let quality)? = provider.requests.first else {
            Issue.record("Wan should get an animate request, not \(String(describing: provider.requests.first))")
            return
        }
        #expect(quality == .final480)
        #expect(store.agentSpent() == 0)
        #expect(job.render(UUID(uuidString: render.id))?.model == .wan22Animate)
    }

    @Test func aWanRenderNeedsAPassedCheck() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        let command = RenderCommand(
            clip: id(job), quality: .final480, requestID: "wan", maxCost: 0, client: "Test Agent",
            model: .wan22Animate)
        await #expect(throws: AgentError.Code.badRequest) {
            try await withOwnComfy(checked: false) { try await code { try await commands.run(.render(command)) } }
        }
        let capabilities = try await withOwnComfy(checked: false) { try await commands.run(.capabilities).capabilities }
        #expect(capabilities?.hasOwnComfyUI == false)
        #expect(job.renders.isEmpty)
    }

    @Test func aWanRenderIsLetThroughOnADayOverTheBudget() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider(statuses: [.success(try await output()), .success(try await output())])
        let (store, commands) = make(provider)
        budget.dollars = 1
        let job = try await prepared(store)
        _ = try await commands.run(.render(request(job, "paid", maxCost: 1)))
        await store.settle(job)
        budget.dollars = 0.05

        let command = RenderCommand(
            clip: id(job), quality: .final720, requestID: "wan", maxCost: 0, model: .wan22Animate)
        let sent = try await withOwnComfy { try await commands.run(.render(command)).renders?.first }
        #expect(sent?.stage == "uploading", "\(sent?.detail ?? "")")
        await store.settle(job)
        #expect(provider.submits == 2)
    }

    @Test func wanRefusesWhatItCantRender() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        func wan(_ quality: AgentQuality, _ requestID: String) -> AgentCommand {
            .render(
                RenderCommand(
                    clip: id(job), quality: quality, requestID: requestID, maxCost: 1, model: .wan22Animate))
        }
        // No own ComfyUI set up.
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(wan(.final480, "a")) }
        }
        try await withOwnComfy {
            await #expect(throws: AgentError.Code.badRequest) {
                try await code { try await commands.run(wan(.draft, "b")) }
            }
            await #expect(throws: AgentError.Code.badRequest) {
                try await code { try await commands.run(wan(.final1080, "c")) }
            }
        }
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.render(request(job, "d", quality: .final480, maxCost: 1))) }
        }
        #expect(job.renders.isEmpty)
    }

    @Test func wanRefusesAClipWithTwoPeople() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = make(FakeProvider(statuses: []), targets: [1, 2])
        let inputs = root.appending(path: "two-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let video = inputs.appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: try await JobStoreTests().clip(), to: video)
        var images: [URL] = []
        for name in ["a.png", "b.png"] {
            let image = inputs.appending(path: name)
            try Data(base64Encoded: JobStoreTests.onePixelPNG)?.write(to: image)
            images.append(image)
        }
        let job = store.enqueue(
            JobSpec(
                title: "two", source: video, references: images, prompt: "", target: .main, faceGuide: false,
                model: .seedance25))
        await store.settle(job)
        let reason = try #require(JobStore.whyNotAnimatable(job))
        #expect(reason.contains("one person per render"), "\(reason)")
    }

    @Test func seedanceRequestsKeepTheirParameters() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        let parameters = try #require(job.render(UUID(uuidString: held.id))?.origin?.parameters)
        #expect(parameters == #"{"clip":"\#(id(job))","command":"render","maxCost":1,"quality":"draft"}"#)
        #expect(job.render(UUID(uuidString: held.id))?.model == nil)
    }
}
