import ComfyKit
import Foundation
import Testing

@testable import SwapjutsuApp

/// The direct route as the app uses it: the bundled workflow's settings, routing by saved request, the provider's
/// statuses, and a render submitted on the direct route that resumes after a relaunch. The wire format itself is
/// covered in ComfyKitTests.
@MainActor
@Suite(.serialized)
struct PartnerSeedanceTests {
    @Test func theDirectRouteAsksForWhatTheWorkflowRuns() throws {
        let draft = try SeedanceWorkflow.referenceInputs(prompt: "", quality: .draft)
        #expect(draft.model == "Seedance 2.5 Draft" && draft.resolution == "480p")
        #expect(draft.prompt.hasPrefix("Replace the person painted"))
        #expect(draft.ratio == "adaptive" && draft.duration == 5 && draft.taskType == "edit")
        #expect(draft.generateAudio && draft.outputFormat == "mp4" && draft.seed == 0 && !draft.watermark)
        let final = try SeedanceWorkflow.referenceInputs(prompt: "swap", quality: .final1080)
        #expect(final.model == "Seedance 2.5" && final.resolution == "1080p" && final.prompt == "swap")
        #expect(try SeedanceWorkflow.finalWatermark() == false)
        #expect(throws: GenerationError.self) { try SeedanceWorkflow.referenceInputs(prompt: "  ", quality: .draft) }
    }

    @Test func downloadsAreNamedWithoutTheRoutesPrefix() {
        #expect(JobStore.downloadName(for: "seedance:cgt-20261017202154-nl117") == "seedance-cgt-20261017202154-nl117")
        #expect(JobStore.downloadName(for: "6f1e0c4a-job") == "seedance-6f1e0c4a-job")
        #expect(JobStore.downloadName(for: "a/b:c d") == "seedance-a-b-c-d")
    }

    @Test func directIsTheDefaultRoute() {
        let saved = UserDefaults.standard.string(forKey: RenderRoute.key)
        defer { UserDefaults.standard.set(saved, forKey: RenderRoute.key) }
        UserDefaults.standard.removeObject(forKey: RenderRoute.key)
        #expect(RenderRoute.current == .direct)
        UserDefaults.standard.set("cloud", forKey: RenderRoute.key)
        #expect(RenderRoute.current == .cloud)
    }

    @Test func newRendersFollowTheSettingAndSavedOnesTheirRoute() async throws {
        let (cloud, direct) = (FakeProvider(statuses: []), FakeProvider(statuses: []))
        let routes = SeedanceRoutes(route: .cloud, cloud: cloud, direct: direct)
        _ = try await routes.submit(.finalize(draftTaskID: "cgt-1"))
        #expect(cloud.submits == 1 && direct.submits == 0)
        try await routes.cancel("seedance:cgt-2")
        try await routes.cancel("6f1e0c4a-job")
        #expect(direct.canceled == ["seedance:cgt-2"] && cloud.canceled == ["6f1e0c4a-job"])
    }

    @Test func taskStatesBecomeRenderStates() async throws {
        let stub = PartnerStub([
            .init(json: ["id": "cgt-1", "status": "running"]),
            .init(json: ["id": "cgt-1", "status": "succeeded", "content": ["video_url": "https://v.test/o.mp4"]]),
            .init(json: [
                "id": "cgt-1", "status": "failed",
                "error": ["code": "InvalidParameter.TaskTypeConstraint", "message": "edit constraints"],
            ]),
        ])
        let provider = PartnerSeedance(client: stub.client)
        #expect(try await provider.status(of: "seedance:cgt-1") == .pending)
        let done = GenerationOutput(video: try #require(URL(string: "https://v.test/o.mp4")), draftTaskID: "cgt-1")
        #expect(try await provider.status(of: "seedance:cgt-1") == .completed(done))
        #expect(try await provider.status(of: "seedance:cgt-1") == .failed("Seedance edits clips of 4–30 s only."))
    }

    @Test func aCreateThatMayHaveLandedIsNotSentAgain() async throws {
        let stub = PartnerStub(Array(repeating: .init(status: 502, json: ["message": "bad gateway"]), count: 4))
        await #expect(throws: GenerationError.self) {
            _ = try await PartnerSeedance(client: stub.client).submit(.finalize(draftTaskID: "cgt-1"))
        }
        #expect(stub.paths.count == 4 && stub.paths.allSatisfy { $0.hasSuffix("/contents/generations/tasks") })
    }

    @Test func aDirectRenderResumesAfterARelaunch() async throws {
        let store = JobStoreTests()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let storage: [String: Any] = ["download_url": "https://cdn.test/a", "upload_url": "https://storage.test/a"]
        let active: [String: Any] = ["id": "a", "asset_type": "Image", "group_id": "g", "status": "Active"]
        let first = PartnerStub([
            .init(json: storage), .init(json: [:]), .init(json: ["asset_id": "i1"]), .init(json: active),
            .init(json: storage), .init(json: [:]), .init(json: ["asset_id": "v1"]), .init(json: active),
            .init(json: ["id": "cgt-1"]), .init(json: ["id": "cgt-1", "status": "running"]),
        ])
        let cloud = FakeProvider(statuses: [])
        let sending = JobStore(
            root: store.root,
            providers: { _ in SeedanceRoutes(route: .direct, cloud: cloud, direct: PartnerSeedance(client: first.client)) },
            preparer: JobStoreTests.preparer(targets: [1]), pollInterval: .seconds(3600), maxPolls: 5)
        let job = try await store.prepared(sending)
        // The stand-in prep writes no control video; the upload reads one.
        try FileManager.default.copyItem(at: try await store.clip(), to: job.control)
        let render = try #require(sending.render(job, quality: .draft))
        while job.render(render.id)?.stage == .uploading { await Task.yield() }
        let sent = try #require(job.render(render.id))
        try #require(sent.providerJobID == "seedance:cgt-1", "\(sent.stage): \(sent.detail)")
        let create = try #require(first.requests.first { $0.path.hasSuffix("/contents/generations/tasks") })
        let body = try JSONDecoder().decode(JSONValue.self, from: create.body)
        #expect(body["draft"] == true && body["omni_reference_task_type"] == "edit" && body["duration"] == -1)
        #expect(body["content"] == [
            ["type": "text", "text": .string(job.effectivePrompt(with: render.prompt))],
            ["type": "image_url", "image_url": ["url": "asset://i1"], "role": "reference_image"],
            ["type": "video_url", "video_url": ["url": "asset://v1"], "role": "reference_video"],
        ])

        // Relaunched with Cloud picked meanwhile: the saved task still resumes on the direct route, unpaid.
        let video = try await store.clip().absoluteString
        let second = PartnerStub([.init(json: ["id": "cgt-1", "status": "succeeded", "content": ["video_url": video]])])
        let resuming = JobStore(
            root: store.root,
            providers: { _ in SeedanceRoutes(route: .cloud, cloud: cloud, direct: PartnerSeedance(client: second.client)) },
            preparer: JobStoreTests.preparer(targets: [1]), pollInterval: .zero, maxPolls: 5)
        let restored = try #require(resuming.jobs.first { $0.id == job.id })
        await resuming.settle(restored)
        let done = try #require(restored.render(render.id))
        #expect(done.stage == .done, "\(done.detail)")
        #expect(done.draftTaskID == "cgt-1" && done.canFinalize())
        #expect(second.paths == ["/proxy/byteplus-seedance2/api/v3/contents/generations/tasks/cgt-1"])
        #expect(cloud.submits == 0)
        sending.cancel(render, of: job)
        await sending.settle(job)
    }
}

/// A session answered from a queue of canned JSON replies, recording each request.
final class PartnerStub: @unchecked Sendable {
    struct Reply {
        var status = 200
        var json: [String: Any]
    }

    struct Request {
        let path: String
        let body: Data
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [Request] = []
    let id = UUID().uuidString

    init(_ replies: [Reply]) {
        self.replies = replies
        Self.registryLock.withLock { Self.registry[id] = self }
    }

    var requests: [Request] { lock.withLock { recorded } }
    var paths: [String] { requests.map(\.path) }

    var client: PartnerSeedanceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PartnerStubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Partner-Stub": id]
        var policy = PartnerRetryPolicy()
        policy.retryDelay = 0.001
        policy.pollRetryDelay = 0.001
        policy.assetPollInterval = 0.001
        return PartnerSeedanceClient(apiKey: "key", session: URLSession(configuration: configuration), retry: policy)
    }

    fileprivate func answer(_ request: URLRequest) -> Reply {
        lock.withLock {
            recorded.append(Request(path: request.url?.path ?? "", body: PartnerStubProtocol.body(of: request)))
            return replies.isEmpty ? Reply(status: 404, json: [:]) : replies.removeFirst()
        }
    }

    nonisolated(unsafe) private static var registry: [String: PartnerStub] = [:]
    private static let registryLock = NSLock()
    fileprivate static func stub(_ id: String) -> PartnerStub? { registryLock.withLock { registry[id] } }
}

final class PartnerStubProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply =
            request.value(forHTTPHeaderField: "X-Partner-Stub").flatMap(PartnerStub.stub)?.answer(request)
            ?? .init(status: 500, json: [:])
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])
        client?.urlProtocol(self, didReceive: response ?? HTTPURLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
