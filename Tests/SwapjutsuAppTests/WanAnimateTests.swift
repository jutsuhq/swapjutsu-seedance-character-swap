import ComfyKit
import Foundation
import Testing

@testable import SwapjutsuApp

/// The Wan 2.2 Animate graph as it is sent to the person's own ComfyUI, Settings' Check against a canned
/// `/object_info`, and the own-ComfyUI address. Nothing reaches a server.
struct WanAnimateTests {
    private func inputs(frames: Int, width: Int = 848, height: Int = 480) -> WanAnimateWorkflow.Inputs {
        .init(
            source: "s-source.mp4", mask: "s-mask.mp4", character: "s-character.png", prompt: "  ",
            width: width, height: height, frames: frames, seed: 42, diffusionModel: WanModels.bf16)
    }

    private func number(_ value: JSONValue?) -> Int? {
        if case .number(let n)? = value { Int(n) } else { nil }
    }

    // MARK: Size and windows

    @Test func sizesKeepTheAspectRatioInMultiplesOf16() {
        #expect(WanAnimateWorkflow.size(width: 1920, height: 1080, quality: .final480) == (848, 480))
        #expect(WanAnimateWorkflow.size(width: 1920, height: 1080, quality: .final720) == (1280, 720))
        #expect(WanAnimateWorkflow.size(width: 1080, height: 1920, quality: .final480) == (480, 848))
        #expect(WanAnimateWorkflow.size(width: 1000, height: 1000, quality: .final720) == (720, 720))
        let odd = WanAnimateWorkflow.size(width: 1366, height: 768, quality: .final480)
        #expect(odd.width % 16 == 0 && odd.height % 16 == 0 && odd.height == 480)
        #expect(WanAnimateWorkflow.size(width: 0, height: 0, quality: .final480) == (16, 16))
    }

    @Test func windowsAre77FramesOverlappingBy5() {
        #expect(WanAnimateWorkflow.windows(frames: 1) == [1])
        #expect(WanAnimateWorkflow.windows(frames: 64) == [65])
        #expect(WanAnimateWorkflow.windows(frames: 77) == [77])
        #expect(WanAnimateWorkflow.windows(frames: 100) == [77, 29])
        let long = WanAnimateWorkflow.windows(frames: 480)
        #expect(long.count == 7 && long.dropLast().allSatisfy { $0 == 77 })
        for frames in [1, 8, 76, 78, 149, 150, 481, 1000] {
            let lengths = WanAnimateWorkflow.windows(frames: frames)
            #expect(lengths.allSatisfy { $0 % 4 == 1 && $0 <= 77 }, "\(frames): \(lengths)")
            let covered = lengths[0] + lengths.dropFirst().reduce(0) { $0 + $1 - 5 }
            #expect(covered >= frames, "\(frames): \(lengths)")
            #expect(covered - frames < 77, "\(frames): no window too many")
        }
    }

    // MARK: The graph

    @Test func oneWindowHasNoExtendNodes() throws {
        let workflow = try WanAnimateWorkflow.make(inputs(frames: 64))
        #expect(!workflow.nodes.keys.contains { $0.hasPrefix("2") && $0.count == 3 })
        #expect(workflow[input: "image", of: "899"] == Workflow.link("105"))
        #expect(number(workflow[input: "length", of: "899"]) == 64)
        #expect(number(workflow[input: "length", of: "101"]) == 65)
        #expect(number(workflow[input: "seed", of: "102"]) == 42)
        #expect(workflow[input: "images", of: "900"] == Workflow.link("899"))
        #expect(number(workflow[input: "fps", of: "900"]) == 16)
        #expect(workflow[input: "video", of: WanAnimateWorkflow.saveNode] == Workflow.link("900"))
    }

    @Test func extendWindowsChainTheFramesAndTheOffset() throws {
        let workflow = try WanAnimateWorkflow.make(inputs(frames: 200))
        let lengths = WanAnimateWorkflow.windows(frames: 200)
        #expect(lengths == [77, 77, 56] || lengths.count == 3, "\(lengths)")
        for (index, length) in lengths.enumerated() {
            let base = (index + 1) * 100
            let wan = String(base + 1)
            #expect(workflow.nodes[wan]?["class_type"] == "WanAnimateToVideo")
            #expect(number(workflow[input: "length", of: wan]) == length)
            #expect(
                number(workflow[input: "width", of: wan]) == 848 && number(workflow[input: "height", of: wan]) == 480)
            #expect(number(workflow[input: "seed", of: String(base + 2)]) == 42)
            #expect(workflow[input: "model", of: String(base + 2)] == Workflow.link("3"))
            #expect(workflow[input: "positive", of: wan] == Workflow.link("5"))
            guard index > 0 else { continue }
            let frames = index == 1 ? Workflow.link("105") : Workflow.link(String(base - 100 + 6))
            #expect(workflow[input: "continue_motion", of: wan] == frames)
            #expect(workflow[input: "video_frame_offset", of: wan] == Workflow.link(String(base - 100 + 1), 5))
            #expect(workflow[input: "image1", of: String(base + 6)] == frames)
            #expect(workflow[input: "image2", of: String(base + 6)] == Workflow.link(String(base + 5)))
            #expect(workflow[input: "positive", of: String(base + 2)] == Workflow.link(wan, 0))
            #expect(workflow[input: "batch_index", of: String(base + 5)] == Workflow.link(wan, 4))
        }
        #expect(workflow[input: "image", of: "899"] == Workflow.link("306"))
        #expect(workflow.nodes["406"] == nil)
        #expect(number(workflow[input: "length", of: "899"]) == 200)
    }

    @Test func everyLinkPointsAtANodeOfTheGraph() throws {
        let workflow = try WanAnimateWorkflow.make(inputs(frames: 480))
        for (id, node) in workflow.nodes {
            for (name, value) in node["inputs"]?.object ?? [:] {
                guard case .array(let link) = value, link.count == 2, let target = link[0].string else { continue }
                #expect(workflow.nodes[target] != nil, "\(id).\(name) → \(target)")
            }
        }
    }

    @Test func theMaskReplacesTheSegmentationAndBlanksTheBackground() throws {
        let workflow = try WanAnimateWorkflow.make(inputs(frames: 100))
        #expect(workflow[input: "file", of: "16"] == "s-mask.mp4")
        #expect(workflow[input: "file", of: "11"] == "s-source.mp4")
        #expect(workflow[input: "image", of: "9"] == "s-character.png")
        for wan in ["101", "201"] {
            #expect(workflow[input: "character_mask", of: wan] == Workflow.link("22"))
            #expect(workflow[input: "background_video", of: wan] == Workflow.link("24"))
            #expect(workflow[input: "pose_video", of: wan] == Workflow.link("15"))
            #expect(workflow[input: "face_video", of: wan] == Workflow.link("14"))
            #expect(workflow[input: "reference_image", of: wan] == Workflow.link("9"))
        }
        #expect(workflow[input: "mask", of: "24"] == Workflow.link("22"))
        #expect(workflow[input: "destination", of: "24"] == Workflow.link("13"))
        for node in ["13", "18", "20", "23"] {
            #expect(number(workflow[input: "width", of: node]) == 848, "\(node)")
            #expect(number(workflow[input: "height", of: node]) == 480, "\(node)")
        }
        #expect(number(workflow[input: "resolution", of: "14"]) == 480)
        #expect(number(workflow[input: "resolution", of: "15"]) == 480)
        let classes = Set(workflow.nodes.values.compactMap { $0["class_type"]?.string })
        #expect(!classes.contains { $0.contains("SAM") || $0.contains("Points") || $0.contains("Blockify") })
    }

    @Test func theModelsAreTheListedFiles() throws {
        let workflow = try WanAnimateWorkflow.make(inputs(frames: 10))
        #expect(workflow[input: "unet_name", of: "1"] == .string(WanModels.bf16))
        #expect(workflow[input: "lora_name", of: "2"] == .string(WanModels.lightx2v))
        #expect(workflow[input: "clip_name", of: "4"] == .string(WanModels.textEncoder))
        #expect(workflow[input: "vae_name", of: "7"] == .string(WanModels.vae))
        #expect(workflow[input: "clip_name", of: "8"] == .string(WanModels.clipVision))
        #expect(workflow[input: "text", of: "5"] == .string(WanAnimateWorkflow.defaultPrompt), "a blank prompt")
        var mine = inputs(frames: 10)
        mine.prompt = "She waves."
        mine.diffusionModel = WanModels.fp8
        let other = try WanAnimateWorkflow.make(mine)
        #expect(other[input: "text", of: "5"] == "She waves.")
        #expect(other[input: "unet_name", of: "1"] == .string(WanModels.fp8))
    }

    // MARK: Check

    /// `/object_info` for the graph's classes, with `files` in the loaders, in the old or the new combo format.
    private func objectInfo(
        missing: Set<String> = [], files: [String], newCombo: Bool = false
    ) throws -> [String: JSONValue] {
        func combo(_ values: [String]) -> JSONValue {
            newCombo
                ? .array(["COMBO", .object(["options": .array(values.map(JSONValue.string))])])
                : .array([.array(values.map(JSONValue.string)), .object([:])])
        }
        var info: [String: JSONValue] = [:]
        for name in try WanAnimateCheck.requiredNodes() where !missing.contains(name) {
            info[name] = .object(["input": .object(["required": .object([:])])])
        }
        for (loader, input) in [
            ("UNETLoader", "unet_name"), ("LoraLoaderModelOnly", "lora_name"), ("CLIPLoader", "clip_name"),
            ("CLIPVisionLoader", "clip_name"), ("VAELoader", "vae_name"),
        ] where info[loader] != nil {
            info[loader] = .object(["input": .object(["required": .object([input: combo(files)])])])
        }
        return info
    }

    private let everything = [
        WanModels.fp8, WanModels.lightx2v, WanModels.textEncoder, WanModels.clipVision, WanModels.vae,
        "other.safetensors",
    ]

    @Test func aCompleteComfyUIIsReady() throws {
        for newCombo in [false, true] {
            let check = try WanAnimateCheck.evaluate(try objectInfo(files: everything, newCombo: newCombo))
            #expect(check.isReady, "\(check)")
            #expect(check.diffusionModels == [WanModels.fp8])
        }
    }

    @Test func checkListsTheMissingCustomNodeAndModels() throws {
        let info = try objectInfo(missing: ["DWPreprocessor"], files: [WanModels.bf16, WanModels.vae])
        let check = try WanAnimateCheck.evaluate(info)
        #expect(!check.isReady)
        #expect(check.missingNodes.map(\.name) == ["DWPreprocessor"])
        #expect(check.missingNodes.first?.source == "comfyui_controlnet_aux")
        #expect(check.missingNodes.first?.link == WanModels.controlnetAux)
        #expect(
            Set(check.missingModels.map(\.name)) == [WanModels.lightx2v, WanModels.textEncoder, WanModels.clipVision])
        #expect(check.missingModels.allSatisfy { $0.download?.host() == "huggingface.co" })
        #expect(check.diffusionModels == [WanModels.bf16])
    }

    @Test func noDiffusionModelAsksForTheFP8One() throws {
        let check = try WanAnimateCheck.evaluate(try objectInfo(files: Array(everything.dropFirst())))
        #expect(check.diffusionModels.isEmpty && !check.isReady)
        #expect(check.missingModels.map(\.name) == [WanModels.fp8])
        #expect(check.missingModels.first?.folder == "diffusion_models")
    }

    @Test func anOldComfyUIMissingACoreNodeIsToldToUpdate() throws {
        let check = try WanAnimateCheck.evaluate(try objectInfo(missing: ["WanAnimateToVideo"], files: everything))
        #expect(
            check.missingNodes == [
                .init(name: "WanAnimateToVideo", source: "ComfyUI (update it)", link: WanModels.tutorial)
            ])
        #expect(try WanAnimateCheck.evaluate([:]).missingNodes.count == WanAnimateCheck.requiredNodes().count)
    }

    @Test func theOnlyCustomNodeIsDWPose() throws {
        let core: Set = [
            "UNETLoader", "LoraLoaderModelOnly", "ModelSamplingSD3", "CLIPLoader", "CLIPTextEncode", "VAELoader",
            "CLIPVisionLoader", "CLIPVisionEncode", "LoadImage", "LoadVideo", "GetVideoComponents", "ImageScale",
            "ImageScaleBy", "ImageToMask", "ThresholdMask", "EmptyImage", "ImageCompositeMasked", "WanAnimateToVideo",
            "KSampler", "TrimVideoLatent", "VAEDecode", "ImageFromBatch", "ImageBatch", "CreateVideo", "SaveVideo",
        ]
        #expect(Set(try WanAnimateCheck.requiredNodes()).subtracting(core) == ["DWPreprocessor"])
    }

    // MARK: Address

    @Test func addressesBecomeBaseURLs() {
        #expect(OwnComfy.parse("192.168.1.20:8188")?.absoluteString == "http://192.168.1.20:8188/")
        #expect(OwnComfy.parse(" http://gpu.local:8188 ")?.absoluteString == "http://gpu.local:8188/")
        #expect(OwnComfy.parse("https://box.example/comfy?x=1")?.absoluteString == "https://box.example/comfy/")
        #expect(OwnComfy.parse("") == nil)
        #expect(OwnComfy.parse("ftp://box") == nil)
        #expect(OwnComfy.parse("http://") == nil)
    }

    @Test func plainHTTPOnlyWhereATSAllowsIt() throws {
        func needs(_ text: String) throws -> Bool { OwnComfy.needsHTTPS(try #require(OwnComfy.parse(text))) }
        for allowed in [
            "127.0.0.1:8188", "localhost:8188", "gpu.local:8188", "gpubox:8188", "10.0.0.5:8188", "172.20.1.1:8188",
            "192.168.1.20:8188", "169.254.3.4:8188", "http://[::1]:8188", "http://[fd00::1]:8188",
            "https://gpu.lan", "https://203.0.113.9",
        ] {
            #expect(try !needs(allowed), "\(allowed)")
        }
        for refused in [
            "gpu.lan:8188", "box.tailnet.ts.net:8188", "100.101.102.103:8188", "203.0.113.9:8188", "172.32.0.1",
        ] {
            #expect(try needs(refused), "\(refused)")
        }
    }

    // MARK: Video

    @Test func resamplingGivesThe16FPSGridAtTheRenderSize() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "wan-resample-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        // 0.5 s at 24 fps.
        let frames = try await WanVideo.resample(try await JobStoreTests().clip(), to: output, width: 32, height: 16, fps: 16)
        #expect(frames == 8)
        let size = try await WanVideo.size(of: output)
        #expect(size.width == 32 && size.height == 16)
    }
}
