import Foundation
import Testing

@testable import ComfyKit

/// The Comfy API v2 contract against a stubbed session: auth, idempotency, retries, errors, polling, uploads.
@Suite(.serialized)
struct ComfyClientTests {
    @Test func rateLimitedPostIsRetriedWithTheSameKey() async throws {
        let stub = Stub([
            .init(
                status: 429, json: ["error": ["code": "queue_full", "message": "busy"]], headers: ["Retry-After": "0"]),
            .init(status: 201, json: ["id": "job-1", "status": "queued", "outputs": []]),
        ])
        let job = try await stub.client.submit(Workflow(nodes: [:]), partnerAPIKey: "partner")
        #expect(job.id == "job-1" && job.status == .queued)
        let calls = stub.calls
        #expect(calls.count == 2)
        #expect(calls[0].idempotencyKey != nil && calls[0].idempotencyKey == calls[1].idempotencyKey)
        #expect(calls.allSatisfy { $0.authorization == "Bearer key" && $0.path == "/api/v2/jobs" })
        let body = try JSONDecoder().decode(JSONValue.self, from: calls[0].body)
        #expect(body["extra_data"]?["api_key_comfy_org"] == "partner")
        #expect(body["workflow"] == .object([:]))
    }

    @Test func serverErrorOnPostIsNotRetried() async throws {
        let stub = Stub([.init(status: 502, json: ["error": ["code": "upstream", "message": "bad gateway"]])])
        await #expect(throws: ComfyError.rejected(status: 502, code: "upstream", message: "bad gateway")) {
            _ = try await stub.client.submit(Workflow(nodes: [:]))
        }
        #expect(stub.calls.count == 1)
    }

    @Test func serverErrorOnGetIsRetried() async throws {
        let stub = Stub([
            .init(status: 503, json: [:]),
            .init(status: 200, json: ["id": "j", "status": "running", "outputs": []]),
        ])
        #expect(try await stub.client.job("j").status == .running)
        #expect(stub.calls.count == 2 && stub.calls[0].idempotencyKey == nil)
    }

    @Test func aLongRetryAfterIsNotShortened() async throws {
        let stub = Stub([
            .init(
                status: 429, json: ["error": ["code": "queue_full", "message": "busy"]], headers: ["Retry-After": "120"]
            )
        ])
        await #expect(throws: ComfyError.busy(code: "queue_full", message: "busy", retryAfter: 120)) {
            _ = try await stub.client.submit(Workflow(nodes: [:]))
        }
        #expect(stub.calls.count == 1)
        #expect(ComfyClient.retryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == 0)
        #expect(ComfyClient.retryAfter(" 5 ") == 5)
    }

    @Test func uploadTypesComeFromTheExtension() {
        #expect(ComfyClient.contentType(of: URL(filePath: "/a/c.PNG")) == "image/png")
        #expect(ComfyClient.contentType(of: URL(filePath: "/a/c.heic")) == "image/heic")
        #expect(ComfyClient.contentType(of: URL(filePath: "/a/c.mp4")) == "video/mp4")
        #expect(ComfyClient.contentType(of: URL(filePath: "/a/c.zzz")) == "application/octet-stream")
    }

    @Test func envelopeCodesMapToCases() {
        func map(_ status: Int, _ code: String) -> ComfyError {
            let body = try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "m"]])
            return ComfyError.from(status: status, body: body ?? Data(), retryAfter: 3)
        }
        #expect(map(402, "insufficient_credits") == .insufficientCredits("m"))
        #expect(map(422, "invalid_workflow") == .invalidWorkflow("m"))
        #expect(map(422, "missing_asset") == .missingAsset("m"))
        #expect(map(422, "idempotency_key_reuse") == .idempotencyKeyReuse("m"))
        #expect(map(429, "rate_limited") == .busy(code: "rate_limited", message: "m", retryAfter: 3))
        #expect(map(401, "unauthorized") == .unauthorized("m"))
    }

    @Test func waitPollsUntilTerminal() async throws {
        let running: [String: Any] = ["id": "j", "status": "running", "outputs": []]
        let stub = Stub([
            .init(status: 200, json: running), .init(status: 200, json: running),
            .init(
                status: 200,
                json: [
                    "id": "j", "status": "succeeded",
                    "outputs": [["node_id": "4", "content_type": "video/mp4", "id": "o"]],
                ]),
        ])
        var updates = 0
        let job = try await stub.client.waitForCompletion(of: "j") { _ in updates += 1 }
        #expect(job.outputs == [Job.Output(nodeId: "4", name: nil, contentType: "video/mp4", id: "o")])
        #expect(updates == 3)

        let failed = Stub([
            .init(
                status: 200,
                json: ["id": "j", "status": "failed", "outputs": [], "error": ["message": "boom", "node_id": "3"]])
        ])
        await #expect(throws: ComfyError.jobFailed(.init(code: nil, message: "boom", nodeId: "3", classType: nil))) {
            _ = try await failed.client.waitForCompletion(of: "j")
        }
    }

    @Test func uploadStreamsAMultipartForm() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "control-\(UUID().uuidString).mp4")
        try Data("frames".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = Stub([.init(status: 201, json: ["id": "asset-1", "hash": "blake3:ab"])])
        let asset = try await stub.client.upload(file)
        #expect(asset.id == "asset-1")
        let call = try #require(stub.calls.first)
        #expect(call.path == "/api/v2/assets" && call.idempotencyKey != nil)
        let boundary = try #require(call.contentType?.components(separatedBy: "boundary=").last)
        let form = String(decoding: call.body, as: UTF8.self)
        #expect(form.hasPrefix("--\(boundary)\r\n") && form.hasSuffix("\r\n--\(boundary)--\r\n"))
        #expect(form.contains("name=\"content_type\"\r\n\r\nvideo/mp4\r\n"))
        #expect(form.contains("name=\"file_path\"\r\n\r\n\(file.lastPathComponent)\r\n"))
        #expect(form.contains("name=\"tags\"\r\n\r\n[\"input\"]\r\n"))
        #expect(form.contains("Content-Type: video/mp4\r\n\r\nframes\r\n"))
    }

    @Test func workflowRefusesUIFormatAndKeepsIntegers() throws {
        #expect(throws: ComfyError.self) { try Workflow(apiFormat: Data(#"{"nodes": [], "links": []}"#.utf8)) }
        var workflow = try Workflow(
            apiFormat: Data(#"{"1": {"class_type": "LoadImage", "inputs": {"image": "x.png"}}}"#.utf8))
        let asset = Asset(id: "a1")
        workflow[input: "image", of: "1"] = Workflow.reference(to: asset)
        workflow[input: "seed", of: "1"] = 7
        #expect(workflow[input: "image", of: "1"]?["info"]?["id"] == "a1")
        let encoded = try JSONEncoder().encode(workflow.nodes)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(decoded["1"]?["inputs"]?["seed"] == 7)
        #expect(decoded["1"]?["inputs"]?["image"]?["__type"] == "core/ASSET")
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"seed\":7"), "a whole number stays an integer")
        #expect(Workflow.link("2") == ["2", 0])
    }
}

/// A session whose every request is answered from a queue of canned responses and recorded.
final class Stub: @unchecked Sendable {
    struct Reply {
        var status: Int
        var json: [String: Any]
        var headers: [String: String] = [:]
        /// Bytes sent as they are instead of `json`, for a download.
        var raw: Data?
    }

    struct Call {
        let path: String
        let authorization: String?
        let idempotencyKey: String?
        let contentType: String?
        let body: Data
        var method = "GET"
        var url: URL?
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var recorded: [Call] = []
    let id = UUID().uuidString
    var calls: [Call] { lock.withLock { recorded } }

    init(_ replies: [Reply]) {
        self.replies = replies
        Self.registryLock.withLock { Self.registry[id] = self }
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub": id]
        return URLSession(configuration: configuration)
    }

    var client: ComfyClient {
        var policy = RetryPolicy()
        policy.baseDelay = 0.001
        policy.pollStart = 0.001
        return ComfyClient(apiKey: "key", session: session, retry: policy)
    }

    func answer(_ request: URLRequest, body: Data) -> Reply {
        lock.withLock {
            recorded.append(
                Call(
                    path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"),
                    idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key"),
                    contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body,
                    method: request.httpMethod ?? "GET", url: request.url,
                    headers: request.allHTTPHeaderFields ?? [:]))
            return replies.isEmpty ? Reply(status: 404, json: [:]) : replies.removeFirst()
        }
    }

    /// Shared by every suite that stubs a session, which Swift Testing runs in parallel.
    nonisolated(unsafe) private static var registry: [String: Stub] = [:]
    private static let registryLock = NSLock()

    static func stub(_ id: String) -> Stub? { registryLock.withLock { registry[id] } }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = request.value(forHTTPHeaderField: "X-Stub").flatMap(Stub.stub)
        let reply = stub?.answer(request, body: Self.body(of: request)) ?? .init(status: 500, json: [:])
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: reply.status, httpVersion: nil,
            headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a })
        client?.urlProtocol(self, didReceive: response ?? HTTPURLResponse(), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self, didLoad: reply.raw ?? (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data())
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
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
