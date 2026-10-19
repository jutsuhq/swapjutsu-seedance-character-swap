import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One result on its own page, as in Jutsu Studio: a large player beside its details and what to do next. The arrow
/// keys step through the results the grid shows; Escape goes back to it.
struct LibraryDetail: View {
    let entries: [LibraryEntry]
    let index: Int
    @Environment(JobStore.self) private var jobs
    @Environment(Navigation.self) private var navigation
    @State private var view = ResultView.result
    @State private var isConfirmingRemove = false
    @State private var exportFailure: String?

    private var entry: LibraryEntry { entries[index] }
    private var job: Job { entry.job }
    private var render: Render { entry.render }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            topBar
            HStack(alignment: .top, spacing: Theme.Spacing.xLarge) {
                stage
                ScrollView { details }
                    .frame(width: 320)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .pagePadding()
        .confirmationDialog(
            "Remove \(entry.name) from Library?", isPresented: $isConfirmingRemove, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                jobs.remove(render, of: job)
                navigation.result = nil
            }
        } message: {
            Text("The video stays in the clip's folder on disk.")
        }
        .alert(
            "Couldn't export",
            isPresented: Binding(get: { exportFailure != nil }, set: { if !$0 { exportFailure = nil } })
        ) {
            Button("OK") { exportFailure = nil }
        } message: {
            Text(exportFailure ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Library", systemImage: "chevron.left") { navigation.result = nil }
                .buttonStyle(.secondaryAction)
                .keyboardShortcut(.cancelAction)
                .help("Back to Library (Esc)")
            Spacer(minLength: Theme.Spacing.small)
            if entries.count > 1 {
                HStack(spacing: 2) {
                    Button("Previous", systemImage: "chevron.left") { step(-1) }
                        .buttonStyle(.iconAction)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                        .help("Previous result (←)")
                    Text("\(index + 1) of \(entries.count)")
                        .font(Theme.Typography.strongNote)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    Button("Next", systemImage: "chevron.right") { step(1) }
                        .buttonStyle(.iconAction)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index == entries.count - 1)
                        .help("Next result (→)")
                }
                .padding(.trailing, Theme.Spacing.medium)
            }
            Button("Show in Finder", systemImage: "folder") {
                if let url = entry.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .buttonStyle(.iconAction)
            .help("Show the video in Finder")
            Button("Copy Video", systemImage: "doc.on.doc") {
                guard let url = entry.url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
            .buttonStyle(.iconAction)
            .help("Copy the video, to paste in Finder or an editor")
            Button("Export…", systemImage: "square.and.arrow.up", action: export)
                .buttonStyle(.secondaryAction)
            Button("Remove from Library", systemImage: "trash", role: .destructive) { isConfirmingRemove = true }
                .buttonStyle(.iconAction)
                .help("Remove from Library (the file stays on disk)")
        }
    }

    private func step(_ offset: Int) {
        let next = index + offset
        guard entries.indices.contains(next) else { return }
        navigation.result = entries[next].id
    }

    private func export() {
        guard let url = entry.url else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(job.title) \(entry.name).mp4"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task {
            do {
                try await ResultExporter.export(url, to: target)
            } catch {
                exportFailure = error.localizedDescription
            }
        }
    }

    // MARK: Stage

    private var aspect: CGFloat {
        guard let manifest = job.manifest, manifest.height > 0 else { return 16 / 9 }
        return CGFloat(manifest.width) / CGFloat(manifest.height)
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let url = view.url(entry) {
                PlayerView(url: url)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
                    .id(url)
            }
            SegmentedControl(
                selection: $view, options: ResultView.offered(for: entry).map { ($0, $0.title) }, isCompact: true
            )
            .fixedSize()
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .well(radius: Theme.Radius.card)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.display(28)).textCase(.uppercase).foregroundStyle(Theme.text).lineLimit(2)
                Text("\(entry.name) · \(job.rangeText)").foregroundStyle(Theme.muted)
            }
            next
            versions
            characters
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SectionLabel(title: "Prompt")
                Text(render.prompt.isEmpty ? "Prep's prompt only, for the people it found." : render.prompt)
                    .font(Theme.Typography.note)
                    .foregroundStyle(render.prompt.isEmpty ? Theme.faint : Theme.text)
                    .textSelection(.enabled)
            }
            facts
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A draft that can still be finalized sends the person to its clip in Create, where renders are paid for.
    @ViewBuilder private var next: some View {
        if render.canFinalize() && job.final(of: render) == nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Button {
                    navigation.open(job.id, render: render.id)
                } label: {
                    Label("Finalize in Create…", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryAction)
                .help("Opens the clip in Create, where you finalize it with the price shown")
                Text(
                    "1080p with the same motion, \(SeedancePrice.text(seconds: job.duration ?? 0, quality: .final1080)). "
                        + "Possible until \(render.finalizableUntil.formatted(date: .abbreviated, time: .omitted))."
                )
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.faint)
            }
        } else {
            Button {
                navigation.open(job.id, render: render.id)
            } label: {
                Label("Open Clip", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondaryAction)
        }
    }

    /// Every finished render of the clip; the current one is highlighted, the others open.
    private var versions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Versions of this clip")
            HStack(spacing: 6) {
                ForEach(job.finished) { other in
                    let isCurrent = other.id == render.id
                    Button {
                        navigation.result = other.id
                    } label: {
                        Text(job.name(of: other))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isCurrent ? Theme.ink : Theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(isCurrent ? Theme.accent : Theme.glass, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .allowsHitTesting(!isCurrent)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
    }

    private var characters: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Characters", detail: "\(job.references(of: render).count)")
            HStack(spacing: 6) {
                ForEach(Array(job.references(of: render).enumerated()), id: \.offset) { index, url in
                    Thumbnail(url: url)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .overlay(alignment: .bottomLeading) { MediaTag(text: "\(index + 1)").padding(3) }
                        .help("@Image\(index + 1)")
                }
            }
        }
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: 6) {
            fact("Generator", job.model(of: render).title)
            fact("Quality", render.quality.title)
            if let parent = job.render(render.parent) { fact("From", job.name(of: parent)) }
            fact("Length", job.duration.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" } ?? "—")
            fact("Sound", "Original soundtrack")
            fact("Made", (render.finished ?? render.created).formatted(date: .abbreviated, time: .shortened))
            fact("Est. cost", job.model(of: render).priceText(seconds: job.duration ?? 0, quality: render.quality))
            if let request = render.providerJobID { fact("Request", request) }
        }
        .font(Theme.Typography.note)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(Theme.faint)
            Text(value).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(1)
        }
    }
}

/// What the player shows on a result's page.
enum ResultView: CaseIterable, Hashable {
    case result, original, control

    var title: String {
        switch self {
        case .result: "Result"
        case .original: "Original"
        case .control: "Control"
        }
    }

    /// The control video is the clip's latest prep: a result made from an earlier one doesn't offer it.
    @MainActor
    static func offered(for entry: LibraryEntry) -> [ResultView] {
        entry.job.isCurrentPrep(of: entry.render) ? allCases : allCases.filter { $0 != .control }
    }

    @MainActor
    func url(_ entry: LibraryEntry) -> URL? {
        switch self {
        case .result: entry.url
        case .original: entry.job.source
        case .control: entry.job.control
        }
    }
}
