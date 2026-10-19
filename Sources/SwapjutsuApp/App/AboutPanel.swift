import AppKit

/// The standard About panel, with the credits the README lists: the models the app downloads, the open-source
/// generator and the server it runs on, and the fonts. The licenses of the packages compiled into the app are in
/// ThirdPartyNotices.txt (`scripts/third-party-notices.sh`), opened by Swapjutsu › Acknowledgements.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = """
            Depth Anything V2 Small, Core ML conversion by Apple. Apache License 2.0.
            EdgeTAM by Meta Platforms, Inc. and affiliates, our Core ML conversion (jutsuhq/edgetam-coreml). \
            Apache License 2.0; not affiliated with or endorsed by Meta.
            Prompt writer models, downloaded from Hugging Face when you choose them, MLX 4-bit conversions by \
            mlx-community: Qwen3-VL 8B, Qwen3.5 9B, Qwen3.5 35B-A3B and Qwen3.8 27B by the Qwen team, Alibaba Cloud; \
            Gemma 4 E4B by Google. Apache License 2.0; the Gemma conversion is labeled with the Gemma Terms of Use.
            Wan 2.2 Animate by the Wan team, Alibaba Group. Apache License 2.0. It runs on your own ComfyUI and is \
            not part of Swapjutsu.
            ComfyUI by Comfy Org. GNU GPL v3.0. Used over its API only; not bundled.
            Barlow Condensed by The Barlow Project Authors. SIL Open Font License 1.1.
            Open-source packages in the app: Swapjutsu › Acknowledgements.
            Swapjutsu is MIT-licensed and unofficial.
            """
        let text = NSAttributedString(
            string: credits,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: text])
        NSApplication.shared.activate()
    }

    /// The bundled third-party licenses, in the person's text viewer.
    static func showNotices() {
        guard let url = Bundle.module.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }
}
