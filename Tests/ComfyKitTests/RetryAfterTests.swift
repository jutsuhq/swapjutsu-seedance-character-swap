import Foundation
import Testing

@testable import ComfyKit

/// A server's `Retry-After` is waited in full or ends the call; neither client asks again early. The waits are
/// recorded, not slept.
@Suite(.serialized)
struct RetryAfterTests {
    @Test func theDirectRouteWaitsALongRetryAfterInFull() async throws {
        let stub = Stub([
            .init(status: 429, json: [:], headers: ["Retry-After": "300"]), .init(status: 200, json: ["id": "cgt-1"]),
        ])
        let waits = Waits()
        #expect(try await stub.partner(waits).createTask(.draftToFinal(taskID: "d", watermark: false)) == "cgt-1")
        #expect(waits.seconds == [300])
        #expect(stub.calls.count == 2)
    }

    @Test func theDirectRouteGivesUpOnARetryAfterBeyondItsLimitWithoutAskingAgain() async throws {
        let stub = Stub([.init(status: 503, json: ["message": "down"], headers: ["Retry-After": "3600"])])
        let waits = Waits()
        await #expect(throws: ComfyError.rejected(status: 503, code: nil, message: "down")) {
            _ = try await stub.partner(waits).task("cgt-1")
        }
        #expect(waits.seconds.isEmpty && stub.calls.count == 1)
    }

    @Test func comfyCloudWaitsAPollsRetryAfterInsteadOfItsOwnBackoff() async throws {
        let stub = Stub([
            .init(status: 503, json: [:], headers: ["Retry-After": "20"]),
            .init(status: 200, json: ["id": "j", "status": "running", "outputs": []]),
        ])
        let waits = Waits()
        #expect(try await stub.client(waits).job("j").status == .running)
        #expect(waits.seconds == [20])
    }

    @Test func comfyCloudGivesUpOnAPollsRetryAfterBeyondItsLimit() async throws {
        let stub = Stub([.init(status: 503, json: [:], headers: ["Retry-After": "300"])])
        let waits = Waits()
        await #expect(throws: ComfyError.self) { _ = try await stub.client(waits).job("j") }
        #expect(waits.seconds.isEmpty && stub.calls.count == 1)
    }
}

/// A sleeper that records each wait and returns at once.
final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    var seconds: [TimeInterval] { lock.withLock { recorded } }
    var sleeper: Sleeper { { seconds in self.lock.withLock { self.recorded.append(seconds) } } }
}

extension Stub {
    func partner(_ waits: Waits) -> PartnerSeedanceClient {
        PartnerSeedanceClient(apiKey: "key", session: session, sleep: waits.sleeper)
    }

    func client(_ waits: Waits) -> ComfyClient { ComfyClient(apiKey: "key", session: session, sleep: waits.sleeper) }
}
