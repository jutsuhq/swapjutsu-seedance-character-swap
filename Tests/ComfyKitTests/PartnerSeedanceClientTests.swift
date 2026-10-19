import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import ComfyKit

/// The direct route against a stubbed session. The expected requests are read off ComfyUI's
/// `comfy_api_nodes/nodes_bytedance.py`, `util/client.py`, `util/_helpers.py` and `util/upload_helpers.py` at
/// commit 5cc4b870094c89090db54bd8d12649dcaf89f2ba.
@Suite(.serialized)
struct PartnerSeedanceClientTests {
    private static var storage: [String: Any] {
        ["download_url": "https://cdn.test/in/a.bin", "upload_url": "https://storage.test/put/a?sig=1"]
    }

    @Test func everyComfyCallCarriesTheNodesHeaders() async throws {
        let stub = Stub([.init(status: 200, json: ["id": "cgt-1"])])
        _ = try await stub.partner.createTask(.draftToFinal(taskID: "d", watermark: false))
        let call = try #require(stub.calls.first)
        #expect(call.method == "POST" && call.url?.host == "api.comfy.org")
        #expect(call.headers["X-API-KEY"] == "key" && call.authorization == nil)
        #expect(call.headers["Comfy-Env"] == "swapjutsu" && call.headers["Comfy-Usage-Source"] == "swapjutsu")
        #expect(call.headers["Comfy-Core-Version"] == "0.41.0")
        #expect(call.headers["Accept"] == "application/json" && call.contentType == "application/json")
        // `uuid.uuid4().hex`.
        #expect(call.idempotencyKey?.count == 32 && call.idempotencyKey?.contains("-") == false)
    }

    @Test func theControlVideoGoesToStorageThenTheVirtualLibrary() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "control-\(UUID().uuidString).mp4")
        try Data("frames".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = Stub([
            .init(status: 200, json: Self.storage), .init(status: 200, json: [:]),
            .init(status: 200, json: ["asset_id": "v1"]),
            .init(status: 200, json: ["id": "v1", "asset_type": "Video", "group_id": "g", "status": "Processing"]),
            .init(status: 200, json: ["id": "v1", "asset_type": "Video", "group_id": "g", "status": "Active"]),
        ])
        #expect(try await stub.partner.uploadReferenceVideo(file) == "asset://v1")
        let calls = stub.calls
        #expect(calls.map(\.method) == ["POST", "PUT", "POST", "GET", "GET"])
        #expect(calls[0].path == "/customers/storage")
        let slot = try JSONDecoder().decode([String: String].self, from: calls[0].body)
        #expect(slot["content_type"] == "video/mp4" && slot["file_name"]?.hasSuffix(".mp4") == true)
        // The signed PUT carries the type and the bytes, and no Comfy credentials.
        #expect(calls[1].url?.absoluteString == "https://storage.test/put/a?sig=1")
        #expect(calls[1].contentType == "video/mp4" && calls[1].headers["X-API-KEY"] == nil)
        #expect(calls[1].body == Data("frames".utf8))
        #expect(calls[2].path == "/proxy/seedance/virtual-library/assets")
        let hash = SHA256.hash(data: Data("frames".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(try body(calls[2]) == ["url": "https://cdn.test/in/a.bin", "hash": .string(hash), "asset_type": "Video"])
        #expect(calls[3].path == "/proxy/seedance/assets/v1" && calls[3].idempotencyKey == nil)
    }

    @Test func aCharacterIsSentAsAnRGBPNGOfAtMost2048Squared() async throws {
        let file = try picture(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = Stub([
            .init(status: 200, json: Self.storage), .init(status: 200, json: [:]),
            .init(status: 200, json: ["asset_id": "i1"]),
            .init(status: 200, json: ["id": "i1", "asset_type": "Image", "group_id": "g", "status": "Active"]),
        ])
        #expect(try await stub.partner.uploadReferenceImage(file) == "asset://i1")
        let calls = stub.calls
        #expect(calls[1].contentType == "image/png")
        let png = calls[1].body
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2508 && image.height == 1672 && image.alphaInfo != .last)
        let library = try body(calls[2])
        #expect(library["asset_type"] == nil, "an image leaves the type to the server")
        #expect(library["hash"]?.string == SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
        #expect(PartnerSeedanceClient.downscaledSize(width: 2048, height: 2048, total: 2048 * 2048) == nil)
        let portrait = PartnerSeedanceClient.downscaledSize(width: 1000, height: 6000, total: 2048 * 2048)
        #expect(portrait.map { [$0.width, $0.height] } == [836, 5016])
    }

    @Test func aFailedUploadStopsWithSeedancesReason() async throws {
        let stub = Stub([
            .init(
                status: 200,
                json: [
                    "id": "i1", "asset_type": "Image", "group_id": "g", "status": "Failed",
                    "error": ["code": "InputImageSensitiveContentDetected", "message": "real person"],
                ])
        ])
        await #expect(throws: ComfyError.self) { try await stub.partner.waitUntilActive("i1") }
    }

    @Test func anEditIsTheNodesRequestBody() throws {
        let inputs = SeedanceTaskRequest.ReferenceInputs(
            model: "Seedance 2.5 Draft", prompt: "swap", resolution: "480p", ratio: "16:9", duration: 5,
            generateAudio: true, taskType: "edit", outputFormat: "mp4", seed: 0, watermark: false)
        let draft = SeedanceTaskRequest.reference(inputs, images: ["asset://i1", "asset://i2"], videos: ["asset://v1"])
        let expected: JSONValue = [
            "model": "dreamina-seedance-2-5-260628",
            "content": [
                ["type": "text", "text": "swap"],
                ["type": "image_url", "image_url": ["url": "asset://i1"], "role": "reference_image"],
                ["type": "image_url", "image_url": ["url": "asset://i2"], "role": "reference_image"],
                ["type": "video_url", "video_url": ["url": "asset://v1"], "role": "reference_video"],
            ],
            "generate_audio": true, "resolution": "480p", "ratio": "adaptive", "duration": -1, "seed": 0,
            "watermark": false, "output_format": "mp4", "omni_reference_task_type": "edit", "draft": true,
        ]
        #expect(try json(draft) == expected)

        var final = inputs
        final.model = "Seedance 2.5"
        final.resolution = "720p"
        let finalBody = try json(.reference(final, images: [], videos: ["asset://v1"]))
        #expect(finalBody["draft"] == nil && finalBody["resolution"] == "720p")
        var auto = inputs
        auto.taskType = "auto"
        let autoBody = try json(.reference(auto, images: [], videos: []))
        #expect(autoBody["omni_reference_task_type"] == nil && autoBody["ratio"] == "16:9" && autoBody["duration"] == 5)
    }

    @Test func aDraftsFinalSendsOnlyItsTaskAt1080p() async throws {
        let stub = Stub([.init(status: 200, json: ["id": "cgt-final"])])
        #expect(try await stub.partner.createTask(.draftToFinal(taskID: " cgt-1 ", watermark: false)) == "cgt-final")
        let call = try #require(stub.calls.first)
        #expect(call.path == "/proxy/byteplus/api/v3/contents/generations/tasks")
        #expect(
            try body(call) == [
                "model": "dreamina-seedance-2-5-260628", "content": [["type": "draft_task", "draft_task": ["id": "cgt-1"]]],
                "resolution": "1080p", "watermark": false,
            ])
    }

    @Test func aTaskIsPolledOnTheSeedance2Path() async throws {
        let stub = Stub([
            .init(status: 200, json: ["id": "cgt-1", "model": "m", "status": "running"]),
            .init(
                status: 200,
                json: ["id": "cgt-1", "model": "m", "status": "succeeded", "content": ["video_url": "https://v.test/o.mp4"]]
            ),
            .init(
                status: 200,
                json: [
                    "id": "cgt-1", "model": "m", "status": "failed",
                    "error": ["code": "InvalidParameter.TaskTypeConstraint", "message": "no"],
                ]),
            .init(status: 200, json: ["id": "cgt-1", "model": "m", "status": "cancelled"]),
        ])
        let running = try await stub.partner.task("cgt-1")
        #expect(!running.isSucceeded && !running.isFailed)
        let done = try await stub.partner.task("cgt-1")
        #expect(done.isSucceeded && done.content?.videoURL == "https://v.test/o.mp4")
        let failed = try await stub.partner.task("cgt-1")
        #expect(failed.isFailed && failed.error?.code == "InvalidParameter.TaskTypeConstraint")
        #expect(try await stub.partner.task("cgt-1").isFailed)
        #expect(stub.calls.allSatisfy { $0.path == "/proxy/byteplus-seedance2/api/v3/contents/generations/tasks/cgt-1" })
        #expect(stub.calls.allSatisfy { $0.method == "GET" && $0.idempotencyKey == nil })
    }

    @Test func retriesKeepTheIdempotencyKey() async throws {
        let stub = Stub([
            .init(status: 503, json: ["message": "down"]),
            .init(status: 429, json: [:], headers: ["Retry-After": "0"]),
            .init(status: 409, json: ["error_type": "idempotency_in_flight"]),
            .init(status: 200, json: ["id": "cgt-1"]),
        ])
        #expect(try await stub.partner.createTask(.draftToFinal(taskID: "d", watermark: false)) == "cgt-1")
        let keys = Set(stub.calls.map(\.idempotencyKey))
        #expect(stub.calls.count == 4 && keys.count == 1 && keys.first != nil)
    }

    @Test func aConsumedKeyIsNotRetried() async throws {
        let stub = Stub([.init(status: 409, json: ["message": "gone"], headers: ["X-Comfy-Error-Type": "idempotency_consumed"])])
        await #expect(throws: ComfyError.idempotencyKeyReuse("gone")) {
            _ = try await stub.partner.createTask(.draftToFinal(taskID: "d", watermark: false))
        }
        #expect(stub.calls.count == 1)
    }

    /// A replayed rate limit created nothing, so it is asked again under a fresh key; a replayed 5xx may stand for a
    /// task the server made, so it comes back as the refusal instead of a second create.
    @Test func onlyAReplayedRateLimitGetsAFreshKey() async throws {
        let limited = Stub([
            .init(status: 429, json: [:], headers: ["Retry-After": "0", "Idempotent-Replayed": "true"]),
            .init(status: 200, json: ["id": "cgt-1"]),
        ])
        #expect(try await limited.partner.createTask(.draftToFinal(taskID: "d", watermark: false)) == "cgt-1")
        #expect(Set(limited.calls.map(\.idempotencyKey)).count == 2)

        let failed = Stub([
            .init(status: 502, json: ["message": "bad gateway"], headers: ["Idempotent-Replayed": "true"]),
            .init(status: 200, json: ["id": "cgt-2"]),
        ])
        do {
            _ = try await failed.partner.createTask(.draftToFinal(taskID: "d", watermark: false))
            Issue.record("a second create was sent")
        } catch ComfyError.rejected(let status, _, _) {
            #expect(status == 502)
        }
        #expect(failed.calls.count == 1)
    }

    /// A create the server still runs when the waits run out may yet become a task: the refusal says it was in
    /// flight, which the app treats as an unknown outcome.
    @Test func anInFlightCreateWaitedOutSaysSo() async throws {
        let inFlight = Stub.Reply(
            status: 409, json: ["message": "running"], headers: ["X-Comfy-Error-Type": "idempotency_in_flight"])
        let stub = Stub(Array(repeating: inFlight, count: 3))
        var policy = PartnerRetryPolicy()
        policy.inFlightWait = 0.001
        policy.maxInFlightWaits = 2
        let client = PartnerSeedanceClient(apiKey: "key", session: stub.session, retry: policy)
        do {
            _ = try await client.createTask(.draftToFinal(taskID: "d", watermark: false))
            Issue.record("the create succeeded")
        } catch ComfyError.rejected(let status, let code, _) {
            #expect(status == 409 && code == ComfyError.inFlight)
        }
        #expect(stub.calls.count == 3 && Set(stub.calls.map(\.idempotencyKey)).count == 1)
    }

    @Test func refusalsMapToWhatTheAppShows() async throws {
        func refusal(_ status: Int, _ json: [String: Any], headers: [String: String] = [:]) async -> ComfyError? {
            let stub = Stub(Array(repeating: .init(status: status, json: json, headers: headers), count: 5))
            do {
                _ = try await stub.partner.createTask(.draftToFinal(taskID: "d", watermark: false))
                return nil
            } catch { return error as? ComfyError }
        }
        #expect(await refusal(401, [:]) == .unauthorized("Check the key in Settings › Comfy."))
        let tier = "API key authentication is not available for free tier accounts"
        #expect(await refusal(403, ["error": "forbidden", "message": tier]) == .unauthorized(tier))
        #expect(
            await refusal(402, ["error": "insufficient_credits", "message": "Balance too low."])
                == .insufficientCredits("Balance too low. Add credits at platform.comfy.org/profile/billing."))
        #expect(
            await refusal(429, [:], headers: ["Retry-After": "0"])
                == .busy(code: "rate_limited", message: "Rate limit exceeded. Please wait and try again.", retryAfter: 0))
        let nested: [String: Any] = [
            "error": ["message": "Bad request", "type": "invalid", "metadata": ["raw": #"{"error":{"message":"duration"}}"#]]
        ]
        #expect(await refusal(400, nested) == .rejected(status: 400, code: nil, message: "Bad request: duration (invalid)"))
        #expect(await refusal(502, ["message": "upstream"]) == .rejected(status: 502, code: nil, message: "upstream"))
    }

    @Test func aPollRidesOutServerErrors() async throws {
        let stub = Stub([
            .init(status: 500, json: [:]), .init(status: 502, json: [:]),
            .init(status: 200, json: ["id": "cgt-1", "status": "queued"]),
        ])
        #expect(try await stub.partner.task("cgt-1").status == "queued")
        #expect(stub.calls.count == 3)
    }

    // MARK: Helpers

    private func body(_ call: Stub.Call) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: call.body)
    }

    private func json(_ request: SeedanceTaskRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: PartnerSeedanceClient.encode(request))
    }

    /// A PNG with an alpha channel, `width` × `height`.
    private func picture(width: Int, height: Int) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "character-\(UUID().uuidString).png")
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return file
    }
}

extension Stub {
    var partner: PartnerSeedanceClient {
        var policy = PartnerRetryPolicy()
        policy.retryDelay = 0.001
        policy.pollRetryDelay = 0.001
        policy.inFlightWait = 0.001
        policy.assetPollInterval = 0.001
        policy.maxRateLimitRetries = 2
        return PartnerSeedanceClient(apiKey: "key", session: session, retry: policy)
    }
}
