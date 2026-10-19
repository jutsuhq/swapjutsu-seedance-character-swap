import ComfyKit
import Foundation

/// The model files Wan 2.2 Animate loads, by the names ComfyUI's loaders list them under, with where to get each. The
/// names are those of Comfy's own template (`video_wan2_2_14B_animate` in Comfy-Org/workflow_templates) and its
/// tutorial, docs.comfy.org/tutorials/video/wan/wan2-2-animate.
enum WanModels {
    /// One model file a loader node needs.
    struct File: Hashable, Sendable {
        /// The loader node and its input that lists the files.
        var loader: String
        var input: String
        var name: String
        /// The folder under `ComfyUI/models/`.
        var folder: String
        var download: URL?
    }

    /// The 14B diffusion model: Kijai's scaled FP8 (17 GB, the template's pick) or Comfy's original BF16 (32 GB).
    static let fp8 = "Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors"
    static let bf16 = "wan2.2_animate_14B_bf16.safetensors"
    static let diffusionChoices = [fp8, bf16]

    static let lightx2v = "lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
    static let textEncoder = "umt5_xxl_fp8_e4m3fn_scaled.safetensors"
    static let clipVision = "clip_vision_h.safetensors"
    static let vae = "wan_2.1_vae.safetensors"

    static let tutorial = URL(string: "https://docs.comfy.org/tutorials/video/wan/wan2-2-animate")
    static let repackaged = URL(string: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged")
    static let controlnetAux = URL(string: "https://github.com/Fannovel16/comfyui_controlnet_aux")

    /// Every file but the diffusion model, which the person picks.
    static let support: [File] = [
        File(
            loader: "LoraLoaderModelOnly", input: "lora_name", name: lightx2v, folder: "loras",
            download: URL(
                string: "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/\(lightx2v)")),
        File(
            loader: "CLIPLoader", input: "clip_name", name: textEncoder, folder: "text_encoders",
            download: URL(
                string: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/"
                    + "text_encoders/\(textEncoder)")),
        File(
            loader: "CLIPVisionLoader", input: "clip_name", name: clipVision, folder: "clip_vision",
            download: URL(
                string: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/"
                    + "clip_vision/\(clipVision)")),
        File(
            loader: "VAELoader", input: "vae_name", name: vae, folder: "vae",
            download: URL(
                string:
                    "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/\(vae)"
            )),
    ]

    static func diffusion(_ name: String) -> File {
        let link =
            name == bf16
            ? "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/\(bf16)"
            : "https://huggingface.co/Kijai/WanVideo_comfy_fp8_scaled/resolve/main/Wan22Animate/\(fp8)"
        return File(
            loader: "UNETLoader", input: "unet_name", name: name, folder: "diffusion_models",
            download: URL(string: link))
    }

    /// "FP8 scaled, 17 GB" for Settings.
    static func label(_ name: String) -> String {
        name == bf16 ? "BF16, 32 GB" : name == fp8 ? "FP8 scaled, 17 GB" : name
    }
}

/// The bundled Wan 2.2 Animate graph (`Resources/Workflows/wan-animate-character-swap.api.json`) with this render's
/// files, size and length filled in. It is Comfy's "Wan2.2 Animate" template in Mix (replacement) mode, flattened to
/// API format, with prep's `mask.mp4` instead of the template's Points Editor and SAM 2; docs/COMFY_API.md lists every
/// node. The file holds the first window (nodes 101–105) and one extend window (201–206); `make` drops the extend for
/// a short clip and repeats it, renumbered, for a long one, the way the template's note says to copy its Video Extend
/// group.
enum WanAnimateWorkflow {
    static let template = Bundle.module.url(forResource: "wan-animate-character-swap.api", withExtension: "json")

    /// The frame rate Wan 2.2 Animate generates at: the template's Create Video runs at 16 fps, and one 77-frame window
    /// is "around 4.8125 seconds" in the tutorial. The app resamples the source and the mask to it first.
    static let fps = 16
    /// Frames per window (`WanAnimateToVideo.length`, a multiple of 4 plus 1).
    static let window = 77
    /// Frames each extend window repeats from the one before (`continue_motion_max_frames`).
    static let overlap = 5
    static let saveNode = "901"
    static let defaultPrompt = "The character moves naturally in the scene."

    /// What the graph is filled in with: the names the files were uploaded under, the render size and length.
    struct Inputs: Equatable, Sendable {
        var source: String
        var mask: String
        var character: String
        var prompt: String
        var width: Int
        var height: Int
        /// Frames of the 16 fps source; the output is cut to exactly this many.
        var frames: Int
        var seed: Int
        var diffusionModel: String
    }

    /// The render size: the short side at the quality's height, the long side keeping the clip's aspect ratio, both
    /// rounded to multiples of 16 as `WanAnimateToVideo` requires.
    static func size(width: Int, height: Int, quality: RenderQuality) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (16, 16) }
        let scale = Double(quality.shortSide) / Double(min(width, height))
        func snap(_ side: Int) -> Int { max(16, Int((Double(side) * scale / 16).rounded()) * 16) }
        return (snap(width), snap(height))
    }

    /// Each window's length. The first takes up to 77 frames; each extend repeats the last 5 frames before it and adds
    /// up to 72, the last one only as long as what is left needs. Every length is 4k + 1.
    static func windows(frames: Int) -> [Int] {
        func grid(_ n: Int) -> Int { (max(n, 1) + 2) / 4 * 4 + 1 }
        var lengths = [min(window, grid(frames))]
        var covered = lengths[0]
        while covered < frames {
            let length = min(window, grid(frames - covered + overlap))
            lengths.append(length)
            covered += length - overlap
        }
        return lengths
    }

    static func make(_ inputs: Inputs) throws -> Workflow {
        var workflow = try SeedanceWorkflow.load(template)
        let extend = (1...6).map { "20\($0)" }
        guard ["1", "5", "9", "11", "16", "101", "899", "900"].allSatisfy({ workflow.nodes[$0] != nil }),
            extend.allSatisfy({ workflow.nodes[$0] != nil })
        else { throw ComfyError.invalidWorkflow("The bundled Wan 2.2 Animate workflow is missing a node.") }

        workflow[input: "unet_name", of: "1"] = .string(inputs.diffusionModel)
        let prompt = inputs.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        workflow[input: "text", of: "5"] = .string(prompt.isEmpty ? defaultPrompt : prompt)
        workflow[input: "image", of: "9"] = .string(inputs.character)
        workflow[input: "file", of: "11"] = .string(inputs.source)
        workflow[input: "file", of: "16"] = .string(inputs.mask)
        for node in ["13", "18", "20", "23"] {
            workflow[input: "width", of: node] = .number(Double(inputs.width))
            workflow[input: "height", of: node] = .number(Double(inputs.height))
        }
        // What the template's Pixel Perfect Resolution works out for frames already at the render size.
        for node in ["14", "15"] {
            workflow[input: "resolution", of: node] = .number(Double(min(inputs.width, inputs.height)))
        }

        let template = Dictionary(uniqueKeysWithValues: extend.map { ($0, workflow.nodes[$0] ?? .null) })
        for id in extend { workflow.nodes[id] = nil }
        let lengths = windows(frames: inputs.frames)
        // The frames so far, and the window whose `video_frame_offset` the next one continues from.
        var (images, previous) = (Workflow.link("105"), "101")
        for (index, length) in lengths.enumerated() {
            let base = (index + 1) * 100
            if index > 0 {
                for (id, node) in template {
                    workflow.nodes[String(base + (Int(id) ?? 0) - 200)] = renumber(
                        node, base: base, images: images, previous: previous)
                }
                images = Workflow.link(String(base + 6))
            }
            let wan = String(base + 1)
            workflow[input: "width", of: wan] = .number(Double(inputs.width))
            workflow[input: "height", of: wan] = .number(Double(inputs.height))
            workflow[input: "length", of: wan] = .number(Double(length))
            workflow[input: "seed", of: String(base + 2)] = .number(Double(inputs.seed))
            previous = wan
        }
        workflow[input: "image", of: "899"] = images
        workflow[input: "length", of: "899"] = .number(Double(max(1, inputs.frames)))
        return workflow
    }

    /// An extend node of the template at window `base`: its links inside the window renumbered, the template's links
    /// to the first window (the frames so far, `105`, and the offset, `101`) pointed at the window before.
    private static func renumber(_ node: JSONValue, base: Int, images: JSONValue, previous: String) -> JSONValue {
        guard var inputs = node["inputs"]?.object else { return node }
        for (name, value) in inputs {
            guard case .array(let link) = value, link.count == 2, let target = link[0].string else { continue }
            switch target {
            case "105": inputs[name] = images
            case "101": inputs[name] = [.string(previous), link[1]]
            case let id where id.hasPrefix("20") && id.count == 3:
                inputs[name] = [.string(String(base + (Int(id) ?? 0) - 200)), link[1]]
            default: break
            }
        }
        var node = node
        node["inputs"] = .object(inputs)
        return node
    }
}

/// What Settings › Own ComfyUI › Check finds on the person's ComfyUI, from `/object_info`: the node classes and model files
/// the bundled graph needs that aren't there, and which of the diffusion models are.
struct WanAnimateCheck: Equatable {
    /// A node the graph uses and the server doesn't have.
    struct MissingNode: Hashable {
        var name: String
        /// Where it comes from: a custom node pack, or ComfyUI itself (then it needs an update).
        var source: String
        var link: URL?
    }

    var missingNodes: [MissingNode]
    var missingModels: [WanModels.File]
    /// The diffusion models (`WanModels.diffusionChoices`) the UNETLoader lists.
    var diffusionModels: [String]

    var isReady: Bool { missingNodes.isEmpty && missingModels.isEmpty && !diffusionModels.isEmpty }

    /// Custom node packs by class; every other class the graph uses is ComfyUI's own.
    static let customNodes: [String: (pack: String, link: URL?)] = [
        "DWPreprocessor": ("comfyui_controlnet_aux", WanModels.controlnetAux)
    ]

    /// The node classes of the bundled graph.
    static func requiredNodes() throws -> [String] {
        let workflow = try SeedanceWorkflow.load(WanAnimateWorkflow.template)
        return Set(workflow.nodes.values.compactMap { $0["class_type"]?.string }).sorted()
    }

    static func evaluate(_ info: [String: JSONValue]) throws -> WanAnimateCheck {
        let missingNodes = try requiredNodes().filter { info[$0] == nil }.map { name in
            let custom = customNodes[name]
            return MissingNode(
                name: name, source: custom?.pack ?? "ComfyUI (update it)", link: custom?.link ?? WanModels.tutorial)
        }
        let missingModels = WanModels.support.filter { file in
            !options(of: file.loader, file.input, in: info).contains(file.name)
        }
        let listed = options(of: "UNETLoader", "unet_name", in: info)
        let diffusion = WanModels.diffusionChoices.filter(listed.contains)
        return WanAnimateCheck(
            missingNodes: missingNodes,
            missingModels: missingModels + (diffusion.isEmpty ? [WanModels.diffusion(WanModels.fp8)] : []),
            diffusionModels: diffusion)
    }

    /// A combo input's options. `object_info` writes them as `[[options…], {…}]`, or, for nodes on ComfyUI's newer
    /// schema, as `["COMBO", {"options": [options…]}]`.
    static func options(of node: String, _ input: String, in info: [String: JSONValue]) -> [String] {
        let spec = info[node]?["input"]?["required"]?[input] ?? info[node]?["input"]?["optional"]?[input]
        guard case .array(let parts)? = spec, let first = parts.first else { return [] }
        let list: JSONValue? =
            if case .array = first { first } else if parts.count > 1 { parts[1]["options"] } else { nil }
        guard case .array(let values)? = list else { return [] }
        return values.compactMap(\.string)
    }
}
