import SwiftUI

/// The new clip: the example gallery until there is a video, then the video with its trim on the left and the first
/// steps on the right. Everything after prep is shown ahead, dimmed, so the way to a result is clear from the start.
struct NewClipWorkspace: View {
    let onSubmit: () -> Void
    @Environment(Draft.self) private var draft
    @Environment(Navigation.self) private var navigation

    var body: some View {
        Group {
            if let source = draft.source {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    header
                    StageAndSide {
                        SourceStage(source: source)
                    } side: {
                        steps
                    }
                    Divider().overlay(Theme.stroke)
                    prepare
                }
                .padding(Theme.Spacing.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card()
            } else {
                SampleGallery()
            }
        }
        .acceptsMedia(into: draft)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.sourceTitle.isEmpty ? "New clip" : draft.sourceTitle)
                    .font(.display(30))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(draft.duration.map { "New clip · \(Timecode.text($0))" } ?? "New clip")
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: Theme.Spacing.small)
            Button("Replace Video…", systemImage: "film") { navigation.isChoosingVideo = true }
                .buttonStyle(.secondaryAction)
                .help("Choose another video for this new clip (⌘O)")
            Button {
                draft.clear()
            } label: {
                Label("Examples", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.secondaryAction)
            .help("Back to the examples; this video is dropped")
        }
    }

    @ViewBuilder private var steps: some View {
        @Bindable var draft = draft
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            Step(number: 1, title: "Video", detail: draft.ranges.isEmpty ? nil : ranges, state: videoState) {
                Text(videoText)
                    .font(Theme.Typography.note)
                    .foregroundStyle(draft.duration != nil && draft.ranges.isEmpty ? Theme.warning : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Step(number: 2, title: "Prep", detail: "Free") {
                CreateOptions(
                    target: $draft.target, faceGuide: $draft.faceGuide, replaceBackground: $draft.replaceBackground)
                Text("Runs on this Mac: finds the people and makes the control video Seedance reads. Nothing is paid.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Step(number: 3, title: "Characters", detail: carried, state: .later) {
                if draft.references.isEmpty {
                    later("One image per person prep finds; you see who is who once it's done.")
                } else {
                    CarriedCharacters(images: draft.references)
                }
            }
            Step(number: 4, title: "Prompt", detail: "Optional", state: .later) {
                later(
                    draft.prompt.isEmpty
                        ? "Your wishes, after the prompt prep writes." : "From the example: \(draft.prompt)")
            }
            Step(number: 5, title: "Render", state: .later) {
                later("A 480p draft to check, or a final at 720p or 1080p, with the price before you pay.")
            }
        }
    }

    /// Always in sight, under the stage and the steps.
    private var prepare: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Text(draft.canSubmit ? "\(ranges) · prep is free; characters and the render come next." : videoText)
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
            Spacer(minLength: Theme.Spacing.small)
            Button(action: onSubmit) {
                Label(
                    draft.ranges.count > 1 ? "Prepare \(draft.ranges.count) Clips" : "Prepare Clip",
                    systemImage: "scissors")
            }
            .buttonStyle(.primaryAction)
            .disabled(!draft.canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .fixedSize()
        }
    }

    private var videoState: StepState { draft.ranges.isEmpty ? .now : .done }

    private var ranges: String {
        let count = draft.ranges.count
        return count == 1 ? draft.rangeSeconds : "\(count) clips · \(draft.rangeSeconds)"
    }

    private var videoText: String {
        guard draft.duration != nil else { return "Reading the video…" }
        if draft.ranges.isEmpty { return "Seedance edits 4–30 s; this video is too short." }
        return "Trim under the player. Each range becomes its own clip, 4–30 s long."
    }

    private var carried: String? {
        draft.references.isEmpty ? nil : "\(draft.references.count) from the example"
    }

    private func later(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.note)
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The example's characters, which every clip from this video starts with.
private struct CarriedCharacters: View {
    let images: [URL]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { index, url in
                Thumbnail(url: url)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay(alignment: .bottomLeading) { MediaTag(text: "\(index + 1)").padding(2) }
            }
            Spacer(minLength: 0)
        }
    }
}
