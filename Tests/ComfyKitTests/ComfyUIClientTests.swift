import Foundation
import Testing

@testable import ComfyKit

/// ComfyUI's own server API against a stubbed session: upload, prompt, queue and history polling, view, cancel.
@Suite(.serialized)
struct ComfyUIClientTests {
    private func client(_ stub: Stub, token: String? = nil) -> ComfyUIClient {
        var policy = RetryPolicy()
        policy.baseDelay = 0.001
        return ComfyUIClient(
            baseURL: URL(string: "http://gpu.local:8188/")!, token: token, session: stub.session, retry: policy)
    }

    @Test func uploadSendsTheFileIntoTheInputFolder() async throws {
        let stub = Stub([
            .init(status: 200, json: ["name": "swapjutsu-1-source.mp4", "subfolder": "", "type": "input"])
        ])
        let file = FileManager.default.temporaryDirectory.appending(path: "comfyui-upload-\(UUID()).mp4")
        try Data("video bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let name = try await client(stub, token: "secret").upload(file, as: "swapjutsu-1-source.mp4")

        #expect(name == "swapjutsu-1-source.mp4")
        let call = try #require(stub.calls.first)
        #expect(call.method == "POST" && call.path == "/upload/image")
        #expect(call.authorization == "Bearer secret")
        #expect(call.contentType?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: call.body, as: UTF8.self)
        #expect(body.contains("name=\"image\"; filename=\"swapjutsu-1-source.mp4\""))
        #expect(body.contains("Content-Type: video/mp4"))
        #expect(body.contains("name=\"type\"\r\n\r\ninput"))
        #expect(body.contains("name=\"overwrite\"\r\n\r\ntrue"))
        #expect(body.contains("video bytes"))
    }

    @Test func uploadIntoASubfolderNamesIt() async throws {
        let stub = Stub([.init(status: 200, json: ["name": "a.png", "subfolder": "swapjutsu", "type": "input"])])
        let file = FileManager.default.temporaryDirectory.appending(path: "comfyui-upload-\(UUID()).png")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try await client(stub).upload(file, as: "a.png") == "swapjutsu/a.png")
        #expect(stub.calls.first?.authorization == nil)
    }

    @Test func queueSendsTheGraphWithOurPromptID() async throws {
        let stub = Stub([.init(status: 200, json: ["prompt_id": "p-1", "number": 3, "node_errors": [:]])])
        let workflow = Workflow(nodes: ["1": ["class_type": "UNETLoader", "inputs": [:]]])
        let id = try await client(stub).queue(workflow, promptID: "p-1", clientID: "swapjutsu")
        #expect(id == "p-1")
        let call = try #require(stub.calls.first)
        #expect(call.method == "POST" && call.path == "/prompt")
        let body = try JSONDecoder().decode(JSONValue.self, from: call.body)
        #expect(body["prompt_id"] == "p-1" && body["client_id"] == "swapjutsu")
        #expect(body["prompt"]?["1"]?["class_type"] == "UNETLoader")
    }

    @Test func aRefusedGraphSaysWhichNodeAndIsNotResent() async throws {
        let refusal: [String: Any] = [
            "error": ["type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation"],
            "node_errors": [
                "1": [
                    "class_type": "UNETLoader",
                    "errors": [["message": "Value not in list", "details": "unet_name: 'x.safetensors' not in []"]],
                ]
            ],
        ]
        let stub = Stub([.init(status: 400, json: refusal), .init(status: 200, json: ["prompt_id": "p"])])
        await #expect(
            throws: ComfyError.invalidWorkflow(
                "Prompt outputs failed validation · UNETLoader (1): Value not in list: unet_name: 'x.safetensors' not in []"
            )
        ) {
            _ = try await client(stub).queue(Workflow(nodes: [:]), promptID: "p", clientID: "c")
        }
        #expect(stub.calls.count == 1)
    }

    @Test func aServerErrorOnThePromptIsNotResent() async throws {
        let stub = Stub([.init(status: 500, json: [:]), .init(status: 200, json: ["prompt_id": "p"])])
        await #expect(throws: ComfyError.self) {
            _ = try await client(stub).queue(Workflow(nodes: [:]), promptID: "p", clientID: "c")
        }
        #expect(stub.calls.count == 1)
    }

    @Test func aProxyRefusingTheTokenIsUnauthorized() {
        guard case .unauthorized = ComfyUIClient.error(status: 401, body: Data()) else {
            Issue.record("401 should be unauthorized")
            return
        }
        guard case .notFound = ComfyUIClient.error(status: 404, body: Data()) else {
            Issue.record("404 should be notFound")
            return
        }
    }

    @Test func queueListsRunningAndPendingPrompts() async throws {
        let stub = Stub([
            .init(
                status: 200,
                json: ["queue_running": [[0, "run-1", [:], [:], []]], "queue_pending": [[1, "wait-1", [:], [:], []]]])
        ])
        let state = try await client(stub).queueState()
        #expect(state == QueueState(running: ["run-1"], pending: ["wait-1"]))
        #expect(state.contains("wait-1") && !state.contains("other"))
        #expect(stub.calls.first?.path == "/queue")
    }

    @Test func historyIsEmptyUntilThePromptFinishes() async throws {
        let stub = Stub([
            .init(status: 503, json: [:]),
            .init(status: 200, json: [:]),
            .init(
                status: 200,
                json: [
                    "p": [
                        "status": ["status_str": "success", "completed": true, "messages": []],
                        "outputs": [
                            "901": [
                                "images": [["filename": "wan_00001_.mp4", "subfolder": "swapjutsu", "type": "output"]],
                                "animated": [true],
                            ]
                        ],
                    ]
                ]),
        ])
        let comfy = client(stub)
        #expect(try await comfy.history("p") == nil)
        let history = try #require(try await comfy.history("p"))
        #expect(history.succeeded && history.failure == nil)
        #expect(history.files(of: "901") == [OutputFile(filename: "wan_00001_.mp4", subfolder: "swapjutsu")])
        #expect(stub.calls.map(\.path) == ["/history/p", "/history/p", "/history/p"])
    }

    @Test func aFailedPromptSaysWhichNodeFailed() throws {
        let json = """
            {"p": {"status": {"status_str": "error", "completed": false, "messages": [
              ["execution_start", {"prompt_id": "p"}],
              ["execution_error", {"node_id": "102", "node_type": "KSampler", "exception_message": "Allocation on device \\n"}]
            ]}, "outputs": {}}}
            """
        let history = try #require(try JSONDecoder().decode([String: PromptHistory].self, from: Data(json.utf8))["p"])
        #expect(!history.succeeded)
        #expect(history.failure == "KSampler (102): Allocation on device")

        let interrupted = """
            {"status": {"status_str": "error", "messages": [["execution_interrupted", {"node_id": "102"}]]}}
            """
        let stopped = try JSONDecoder().decode(PromptHistory.self, from: Data(interrupted.utf8))
        #expect(stopped.failure == "The render was interrupted on ComfyUI.")
    }

    @Test func downloadFetchesTheOutputFromView() async throws {
        let stub = Stub([.init(status: 502, json: [:]), .init(status: 200, json: [:], raw: Data("mp4".utf8))])
        let destination = FileManager.default.temporaryDirectory.appending(path: "comfyui-view-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await client(stub, token: "t").download(
            OutputFile(filename: "wan 1.mp4", subfolder: "swapjutsu"), to: destination)

        #expect(try Data(contentsOf: destination) == Data("mp4".utf8))
        #expect(stub.calls.count == 2)
        let call = try #require(stub.calls.last)
        #expect(call.path == "/view" && call.authorization == "Bearer t")
        let query = URLComponents(url: try #require(call.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(
            query == [
                .init(name: "filename", value: "wan 1.mp4"), .init(name: "subfolder", value: "swapjutsu"),
                .init(name: "type", value: "output"),
            ])
    }

    @Test func cancellingAWaitingPromptDropsItFromTheQueue() async throws {
        let stub = Stub([
            .init(
                status: 200,
                json: ["queue_running": [[0, "other", [:], [:], []]], "queue_pending": [[1, "p", [:], [:], []]]]),
            .init(status: 200, json: [:]),
        ])
        try await client(stub).cancel("p")
        #expect(stub.calls.map(\.path) == ["/queue", "/queue"])
        let body = try JSONDecoder().decode(JSONValue.self, from: stub.calls[1].body)
        #expect(stub.calls[1].method == "POST" && body["delete"] == .array(["p"]))
    }

    @Test func cancellingARunningPromptInterruptsOnlyIt() async throws {
        let stub = Stub([
            .init(status: 200, json: ["queue_running": [[0, "p", [:], [:], []]], "queue_pending": []]),
            .init(status: 200, json: [:]),
        ])
        try await client(stub).cancel("p")
        #expect(stub.calls.map(\.path) == ["/queue", "/interrupt"])
        let body = try JSONDecoder().decode(JSONValue.self, from: stub.calls[1].body)
        #expect(body["prompt_id"] == "p")
    }

    @Test func cancellingAFinishedPromptSendsNothingElse() async throws {
        let stub = Stub([.init(status: 200, json: ["queue_running": [], "queue_pending": []])])
        try await client(stub).cancel("p")
        #expect(stub.calls.map(\.path) == ["/queue"])
    }

    @Test func objectInfoIsTheNodeCatalog() async throws {
        let stub = Stub([.init(status: 200, json: ["UNETLoader": ["input": ["required": [:]]]])])
        let info = try await client(stub).objectInfo()
        #expect(info.keys.sorted() == ["UNETLoader"])
        #expect(stub.calls.first?.path == "/object_info")
    }

    @Test func aReverseProxyPathPrefixIsKept() async throws {
        let stub = Stub([.init(status: 200, json: [:])])
        var policy = RetryPolicy()
        policy.baseDelay = 0.001
        let comfy = ComfyUIClient(
            baseURL: URL(string: "https://box.example/comfy/")!, session: stub.session, retry: policy)
        _ = try await comfy.objectInfo()
        #expect(stub.calls.first?.url?.absoluteString == "https://box.example/comfy/object_info")
    }
}
