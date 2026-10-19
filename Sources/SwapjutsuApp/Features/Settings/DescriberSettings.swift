import SwiftUI

/// Who writes the characters, the place and the moves into the prompt: a local model downloaded here, Apple's
/// system model, an OpenAI-compatible API, or nobody. Whatever is chosen falls back to Apple's model and then to
/// the person's wishes alone.
struct DescriberSettings: View {
    @Environment(VisionModels.self) private var models
    @State private var key = ""
    @State private var isSaved = false
    @FocusState private var focus: Field?

    private enum Field { case base, model, key }

    var body: some View {
        @Bindable var models = models
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Prompt writer",
                footer: "Before prep, a vision model looks at the character images, the new place and a few frames "
                    + "of the clip, and writes who each character is, what they wear and how they move into the "
                    + "prompt, as Higgsfield's server does. It runs on its own and is unloaded before prep. You can "
                    + "edit what it wrote on the clip, and your own wishes win over it."
            ) {
                SettingsRow(label: "Describe with", detail: choiceDetail, isFirst: true) {
                    SegmentedControl(selection: $models.choice, options: choices, isCompact: true).fixedSize()
                }
            }
            if models.choice == .local, models.backend != nil { localModels }
            if models.choice == .api { api }
            if let failure = models.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private var choices: [(value: DescriberChoice, title: String)] {
        DescriberChoice.allCases.filter { $0 != .local || models.backend != nil }.map { ($0, $0.title) }
    }

    private var choiceDetail: String {
        switch models.choice {
        case .local: "On this Mac; falls back to Apple's model until one is downloaded"
        case .system: "Apple Intelligence's on-device model, macOS 27"
        case .api: "Sends the images to the API you set; falls back to Apple's model"
        case .off: "Only your wishes go into the prompt"
        }
    }

    private var localModels: some View {
        SettingsSection(
            title: "Local model",
            footer: "MLX, 4-bit, from Hugging Face into Application Support, only when you click Download; each is "
                + "pinned to one commit and checked file by file. Qwen3-VL 8B writes the best prompts on 16 GB. Larger "
                + "models are listed on Macs with 32 GB or more."
        ) {
            ForEach(Array(VisionModelOption.offered().enumerated()), id: \.element) { index, option in
                ModelRow(option: option, isFirst: index == 0)
            }
        }
    }

    private var api: some View {
        @Bindable var models = models
        return SettingsSection(
            title: "API",
            footer: "Any OpenAI-compatible chat completions API with images: OpenAI, OpenRouter, or LM Studio and "
                + "Ollama on this Mac. The character images and frames of the clip go to it."
        ) {
            SettingsRow(label: "Base URL", isFirst: true) {
                TextField("http://localhost:1234/v1", text: $models.apiBase)
                    .focused($focus, equals: .base)
                    .themedField(isFocused: focus == .base)
                    .frame(width: 260)
            }
            SettingsRow(label: "Model") {
                TextField("qwen3-vl-8b-instruct", text: $models.apiModel)
                    .focused($focus, equals: .model)
                    .themedField(isFocused: focus == .model)
                    .frame(width: 260)
            }
            SettingsRow(label: "Key", detail: "Kept in the Keychain; empty for a local server") {
                HStack(spacing: Theme.Spacing.small) {
                    SecureField("sk-…", text: $key)
                        .focused($focus, equals: .key)
                        .themedField(isFocused: focus == .key)
                        .frame(width: 180)
                        .onSubmit(saveKey)
                    Button(isSaved ? "Saved" : "Save", action: saveKey).buttonStyle(.primaryAction)
                }
            }
        }
    }

    private func saveKey() {
        try? models.apiKey.write(key.trimmingCharacters(in: .whitespacesAndNewlines))
        key = ""
        isSaved = true
    }
}

/// One local model: chosen or not, its size and note, and Download (with progress and Cancel) or Delete.
private struct ModelRow: View {
    let option: VisionModelOption
    let isFirst: Bool
    @Environment(VisionModels.self) private var models

    var body: some View {
        SettingsRow(
            label: option.title + (models.chosen == option ? " · in use" : ""),
            detail: String(format: "%.1f GB · ", option.gigabytes) + option.note, isFirst: isFirst
        ) {
            HStack(spacing: Theme.Spacing.small) {
                if let share = models.progress[option.id] {
                    ProgressView(value: share).frame(width: 90)
                    Text("\(Int(share * 100)) %").font(Theme.Typography.meta).monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    Button("Cancel") { models.cancelDownload(option) }.buttonStyle(.secondaryAction)
                } else if models.isDownloaded(option) {
                    if models.chosen != option {
                        Button("Use") { models.chosen = option }.buttonStyle(.secondaryAction)
                    }
                    Button("Delete", role: .destructive) { models.delete(option) }.buttonStyle(.secondaryAction)
                } else {
                    Button("Download") {
                        models.chosen = option
                        models.download(option)
                    }
                    .buttonStyle(.primaryAction)
                }
            }
        }
    }
}
