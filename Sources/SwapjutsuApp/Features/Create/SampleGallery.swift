import SwiftUI

/// Higgsfield's public Genjutsu examples. Hover plays the result; a click loads its clip, characters and prompt.
/// Nothing reaches Higgsfield until the person turns the examples on, here or in Settings › Prep.
struct SampleGallery: View {
    @AppStorage(SampleLibrary.consentKey) private var showsExamples = false
    @Environment(SampleLibrary.self) private var library
    @Environment(Draft.self) private var draft
    @Environment(Navigation.self) private var navigation

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: Theme.Spacing.medium)]

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start from a clip")
                        .font(.display(30))
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.text)
                    Text(
                        showsExamples
                            ? "Hover to preview a result, click to use its clip, characters and prompt."
                            : "Choose a video of your own, or show Higgsfield's public examples.")
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button {
                    navigation.isChoosingVideo = true
                } label: {
                    Label("Choose Video…", systemImage: "video.badge.plus")
                }
                .buttonStyle(.secondaryAction)
                .help("Choose a video of your own (⌘O)")
            }
            if showsExamples {
                SegmentedControl(selection: $library.shelf, options: SampleShelf.allCases.map { ($0, $0.title) })
                    .frame(maxWidth: 360)
                examples
            } else {
                EmptyState(
                    systemImage: "globe", title: "Examples from Higgsfield",
                    message: "The examples come from Higgsfield's public Genjutsu gallery. Showing them loads the "
                        + "list, thumbnails and previews from Higgsfield's servers; Swapjutsu sends them no account or "
                        + "data of yours.",
                    action: ("Show Examples", { showsExamples = true }))
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .well(radius: Theme.Radius.card)
    }

    private var examples: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.medium) {
                ForEach(library.current) { sample in
                    SampleTile(sample: sample, isLoading: draft.loadingSampleID == sample.id) {
                        Task { await draft.apply(sample) }
                    }
                    .disabled(draft.loadingSampleID != nil)
                }
            }
            footer
        }
        .id(library.shelf)
        .task(id: library.shelf) { await library.loadIfNeeded() }
    }

    @ViewBuilder private var footer: some View {
        if let failure = library.failure {
            VStack(spacing: Theme.Spacing.small) {
                Text(failure).foregroundStyle(Theme.muted)
                Button("Try Again") { Task { await library.loadMore() } }.buttonStyle(.secondaryAction)
            }
            .padding(Theme.Spacing.large)
        } else if library.hasMore {
            ProgressView()
                .controlSize(.small)
                .padding(Theme.Spacing.large)
                .onAppear { Task { await library.loadMore() } }
        }
    }
}

private struct SampleTile: View {
    let sample: Sample
    let isLoading: Bool
    let onPick: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onPick) {
            Theme.well
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { Thumbnail(url: sample.thumbnail) }
                .overlay {
                    if isHovering, !reduceMotion, let preview = sample.preview {
                        LoopingVideo(url: preview)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        MediaTag(text: sample.kind == .swap ? "Swap" : "Motion")
                        MediaTag(text: sample.title)
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    MediaTag(text: "\(Int(sample.duration.rounded())) s").padding(6)
                }
                .overlay {
                    if isLoading {
                        ZStack {
                            Theme.scrim
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .card(radius: Theme.Radius.field, isHighlighted: isHovering)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help("Use this clip, its characters and prompt")
        .accessibilityLabel("\(sample.title), use as source")
    }
}
