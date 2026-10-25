import ComfyKit
import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// Wan 3.0 as the app uses it: the price against Comfy's bill, the provider's statuses, download names and the agent
/// model. The wire format is covered in ComfyKitTests.
@MainActor
@Suite(.serialized)
struct PartnerWanTests {
    @Test func thePriceFollowsComfysBill() {
        // The bill: a 5 s 480p edit, 10 s billed, 150.87 credits at 211 a dollar.
        let bill = WanPrice.estimate(seconds: 5, quality: .final480)
        #expect(abs(bill.lowerBound - 150.87 / 211) < 0.001 && bill.lowerBound == bill.upperBound)
        #expect(GenerationModel.wan30.price(seconds: 5, quality: .final480) == 0.71...0.72)
        // A clip of 4.2 s renders 4 s and may be billed for 5 s of reference video.
        #expect(WanPrice.outputSeconds(4.2) == 4)
        let partial = WanPrice.estimate(seconds: 4.2, quality: .final720)
        #expect(abs(partial.lowerBound - 8.2 * 0.143) < 0.001 && abs(partial.upperBound - 9 * 0.143) < 0.001)
        #expect(GenerationModel.wan30.maxSeconds == 15 && GenerationModel.seedance25.maxSeconds == nil)
    }

    @Test func taskStatesBecomeRenderStates() async throws {
        let stub = PartnerStub([
            .init(json: ["output": ["task_id": "t-1", "task_status": "RUNNING"], "request_id": "r"]),
            .init(json: [
                "output": ["task_id": "t-1", "task_status": "SUCCEEDED", "video_url": "https://v.test/o.mp4"],
                "request_id": "r",
            ]),
            .init(json: [
                "output": [
                    "task_id": "t-1", "task_status": "FAILED", "code": "DataInspectionFailed", "message": "unsafe",
                ],
                "request_id": "r",
            ]),
        ])
        let provider = PartnerWan(client: stub.client)
        #expect(try await provider.status(of: "wan3:t-1") == .pending)
        let link = try #require(URL(string: "https://v.test/o.mp4"))
        #expect(try await provider.status(of: "wan3:t-1") == .completed(GenerationOutput(video: link)))
        #expect(try await provider.status(of: "wan3:t-1") == .failed("DataInspectionFailed: unsafe"))
        #expect(try await provider.cancel("wan3:t-1") == false)
    }

    @Test func downloadsAreNamedAfterWan3() {
        #expect(JobStore.downloadName(for: "wan3:0385dc1a-91f5", model: .wan30) == "wan3-0385dc1a-91f5")
    }

    @Test func agentsNameWan30AndSeedanceStaysTheDefault() {
        #expect(GenerationModel(AgentModel.wan30) == .wan30 && GenerationModel(nil) == .seedance25)
        #expect(AgentModel(GenerationModel.wan30) == .wan30 && AgentModel(GenerationModel.seedance25) == nil)
    }
}
