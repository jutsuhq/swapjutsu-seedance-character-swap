import ComfyKit
import Foundation
import Testing

@testable import SwapjutsuApp

/// The bundled Seedance workflow as the app fills it in. The HTTP side is covered in ComfyKitTests.
struct ComfySeedanceTests {
    private func asset(_ id: String) -> Asset {
        Asset(id: id)
    }

    @Test func draftGetsAssetsPromptAndOneLoaderPerCharacter() throws {
        let workflow = try SeedanceWorkflow.make(
            control: asset("vid"), images: [asset("a"), asset("b")], prompt: "swap", quality: .draft)
        #expect(workflow.nodes["3"]?["class_type"] == "ByteDance2ReferenceNodeV2")
        #expect(workflow[input: "model", of: "3"] == "Seedance 2.5 Draft")
        #expect(workflow[input: "model.resolution", of: "3"] == "480p")
        #expect(workflow[input: "model.task_type", of: "3"] == "edit")
        #expect(workflow[input: "model.prompt", of: "3"] == "swap")
        #expect(workflow[input: "model.reference_videos.video_1", of: "3"] == Workflow.link("1"))
        #expect(workflow[input: "model.reference_images.image_1", of: "3"] == Workflow.link("2"))
        #expect(workflow[input: "model.reference_images.image_2", of: "3"] == Workflow.link("11"))
        #expect(workflow[input: "file", of: "1"]?["info"]?["id"] == "vid")
        #expect(workflow[input: "image", of: "2"]?["info"]?["id"] == "a")
        #expect(workflow[input: "image", of: "11"]?["info"]?["id"] == "b")
        #expect(workflow.nodes["11"]?["class_type"] == "LoadImage")
        #expect(workflow.nodes["4"]?["class_type"] == "SaveVideo")
        #expect(workflow.nodes["5"]?["class_type"] == "SaveText")
        #expect(workflow[input: "text", of: "5"] == Workflow.link("3", 1))
    }

    @Test func finalKeepsTheBundledPromptWhenNoneIsGiven() throws {
        let workflow = try SeedanceWorkflow.make(
            control: asset("vid"), images: [asset("a")], prompt: "", quality: .final1080)
        #expect(workflow[input: "model", of: "3"] == "Seedance 2.5")
        #expect(workflow[input: "model.resolution", of: "3"] == "1080p")
        // The node refuses a final whose draft_task_id output is linked.
        #expect(workflow.nodes["5"] == nil)
        #expect(workflow[input: "model.prompt", of: "3"]?.string?.hasPrefix("Replace the person painted") == true)
        #expect(workflow.nodes["11"] == nil)
    }

    @Test func aDraftsFinalSendsOnlyItsTask() throws {
        let workflow = try SeedanceWorkflow.finalize(draftTaskID: "cgt-123")
        #expect(workflow.nodes["1"]?["class_type"] == "ByteDance2DraftToFinalVideoNode")
        #expect(workflow[input: "draft_task_id", of: "1"] == "cgt-123")
        #expect(workflow[input: "video", of: "2"] == Workflow.link("1"))
    }

    @Test func draftsFollowTheBillAndFinalsTheNodesBadge() {
        // The bill: 180 credits for a 5 s draft, 211 credits a dollar.
        let draft = SeedancePrice.estimate(seconds: 5, quality: .draft)
        #expect(abs(draft.lowerBound - 180 / 211) < 0.001 && abs(draft.upperBound - 1.2 * 180 / 211) < 0.001)
        #expect(SeedancePrice.cents(seconds: 10, quality: .draft) == 1.70...2.05, "what Settings shows")
        #expect(SeedancePrice.text(seconds: 10, quality: .draft).contains("–"), "a range")
        // The top of the badge for a 10 s edit: the 10 s it renders plus the 10 s it reads.
        let final720 = SeedancePrice.estimate(seconds: 10, quality: .final720)
        #expect(abs(final720.lowerBound - 3.96) < 0.01 && final720.lowerBound == final720.upperBound)
        #expect(!SeedancePrice.text(seconds: 10, quality: .final1080).contains("–"), "one figure")
        #expect(SeedancePrice.estimate(seconds: 10, quality: .final1080).lowerBound > final720.upperBound)
    }

    @Test func seedanceCodesBecomeReadable() {
        #expect(
            ComfySeedance.explain("InvalidParameter.TaskTypeConstraint: x") == "Seedance edits clips of 4–30 s only.")
        #expect(ComfySeedance.explain("something else") == "something else")
    }
}
