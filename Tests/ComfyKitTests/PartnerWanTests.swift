import Foundation
import Testing

@testable import ComfyKit

/// Wan 3.0 on the direct route against a stubbed session. The expected requests are read off ComfyUI's
/// `Wan3ReferenceToVideoApi` (`comfy_api_nodes/nodes_wan.py`, `apis/wan.py`) on master of 2026-10-24, and match the
/// request of a paid test render that succeeded.
@Suite(.serialized)
struct PartnerWanTests {
    @Test func anEditIsTheNodesRequestBody() throws {
        let request = try WanTaskRequest.reference(
            prompt: "Replace the person in @Video1 with the character in @Image1 and @Image2.",
            images: ["https://cdn.test/a.png", "https://cdn.test/b.png"], videos: ["https://cdn.test/c.mp4"],
            resolution: "480P", seconds: 5)
        let expected: JSONValue = [
            "model": "wan3.0-video",
            "input": [
                "prompt": "Replace the person in Video 1 with the character in Image 1 and Image 2.",
                "media": [
                    ["type": "reference_image", "url": "https://cdn.test/a.png"],
                    ["type": "reference_image", "url": "https://cdn.test/b.png"],
                    ["type": "reference_video", "url": "https://cdn.test/c.mp4"],
                ],
            ],
            "parameters": [
                "resolution": "480P", "ratio": "adaptive", "duration": 5, "seed": 42, "audio": true,
                "prompt_extend": false, "watermark": false,
            ],
        ]
        #expect(try JSONDecoder().decode(JSONValue.self, from: PartnerSeedanceClient.encode(request)) == expected)
    }

    @Test func tagsAreSpelledOutAsTheNodeDoes() throws {
        #expect(try WanPrompt.spellOutTags("@image2 then @VIDEO", images: 2, videos: 1) == "Image 2 then Video 1")
        // Glued to a word it is left alone, unless it directly follows another tag.
        #expect(try WanPrompt.spellOutTags("mail@image1", images: 1, videos: 0) == "mail@image1")
        #expect(try WanPrompt.spellOutTags("@Image1@Image2", images: 2, videos: 0) == "Image 1Image 2")
        #expect(try WanPrompt.spellOutTags("@Image10x", images: 1, videos: 0) == "@Image10x")
        #expect(throws: ComfyError.self) { try WanPrompt.spellOutTags("@Image3", images: 2, videos: 1) }
        #expect(throws: ComfyError.self) { try WanPrompt.spellOutTags("@Audio1", images: 1, videos: 1) }
    }

    @Test func aTaskIsCreatedWithTheNodesHeaders() async throws {
        let stub = Stub([
            .init(status: 200, json: ["output": ["task_id": "t-1", "task_status": "PENDING"], "request_id": "r"])
        ])
        let request = try WanTaskRequest.reference(
            prompt: "swap", images: [], videos: ["v"], resolution: "480P", seconds: 5)
        #expect(try await stub.partner.createWanTask(request) == "t-1")
        let call = try #require(stub.calls.first)
        #expect(
            call.method == "POST" && call.path == "/proxy/wan/api/v1/services/aigc/video-generation/video-synthesis")
        #expect(call.headers["X-API-KEY"] == "key" && call.idempotencyKey?.count == 32)
    }

    @Test func aReplyWithoutATaskIsWansRefusal() async throws {
        let stub = Stub([
            .init(status: 200, json: ["request_id": "r", "code": "InvalidParameter", "message": "too long"])
        ])
        let request = try WanTaskRequest.reference(
            prompt: "swap", images: [], videos: ["v"], resolution: "480P", seconds: 5)
        await #expect(
            throws: ComfyError.rejected(status: 200, code: "InvalidParameter", message: "InvalidParameter: too long")
        ) {
            try await stub.partner.createWanTask(request)
        }
    }

    @Test func pollsReadWansStatuses() async throws {
        let stub = Stub([
            .init(status: 200, json: ["output": ["task_id": "t", "task_status": "PENDING"], "request_id": "r"]),
            .init(
                status: 200,
                json: [
                    "output": ["task_id": "t", "task_status": "SUCCEEDED", "video_url": "https://v.test/o.mp4"],
                    "request_id": "r",
                ]),
            .init(status: 200, json: ["output": ["task_id": "t", "task_status": "UNKNOWN"], "request_id": "r"]),
        ])
        let pending = try await stub.partner.wanTask("t")
        #expect(!pending.isSucceeded && !pending.isFailed)
        let done = try await stub.partner.wanTask("t")
        #expect(done.isSucceeded && done.output?.videoURL == "https://v.test/o.mp4")
        #expect(try await stub.partner.wanTask("t").isFailed, "an expired task")
        #expect(stub.calls.first?.path == "/proxy/wan/api/v1/tasks/t" && stub.calls.first?.method == "GET")
    }
}
