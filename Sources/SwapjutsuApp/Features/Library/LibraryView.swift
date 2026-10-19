import SwiftUI

/// Every finished render, drafts and finals, newest first. A click opens the result on its own page, as in Jutsu
/// Studio; Escape goes back to the grid.
struct LibraryView: View {
    @Environment(JobStore.self) private var jobs
    @Environment(Navigation.self) private var navigation
    @State private var filter = LibraryFilter.all

    var body: some View {
        let all = LibraryEntry.all(in: jobs.jobs)
        let shown = all.filter(filter.includes)
        Group {
            if let index = shown.firstIndex(where: { $0.id == navigation.result }) {
                LibraryDetail(entries: shown, index: index)
                    .id(shown[index].id)
            } else {
                grid(all: all, shown: shown)
            }
        }
        // A result opened from elsewhere (an agent's show, Create) opens even when the filter hides it.
        .onChange(of: navigation.result, initial: true) {
            guard let entry = all.first(where: { $0.id == navigation.result }), !filter.includes(entry) else { return }
            filter = .all
        }
    }

    private func grid(all: [LibraryEntry], shown: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "Library", subtitle: "Every draft and final you've rendered, saved under ~/Movies/Swapjutsu"
            ) {
                SegmentedControl(
                    selection: $filter,
                    options: LibraryFilter.allCases.map { ($0, "\($0.title) \(all.filter($0.includes).count)") }
                )
                .fixedSize()
            }
            if shown.isEmpty {
                EmptyState(
                    systemImage: "film", title: all.isEmpty ? "No results yet" : "Nothing here",
                    message: all.isEmpty
                        ? "Drafts and finals you render in Create show up here."
                        : "No \(filter.title.lowercased()) yet.",
                    action: all.isEmpty
                        ? ("Go to Create", { navigation.screen = .create }) : ("Show All", { filter = .all }))
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: Theme.Spacing.medium)],
                        spacing: Theme.Spacing.medium
                    ) {
                        ForEach(shown) { entry in
                            LibraryTile(entry: entry) { navigation.result = entry.id }
                        }
                    }
                }
            }
        }
        .pagePadding()
    }
}

/// A finished render and the clip it belongs to.
struct LibraryEntry: Identifiable {
    let job: Job
    let render: Render

    var id: UUID { render.id }

    @MainActor var url: URL? { job.resultURL(of: render) }
    @MainActor var name: String { job.name(of: render) }

    @MainActor
    static func all(in jobs: [Job]) -> [LibraryEntry] {
        jobs.flatMap { job in job.finished.map { LibraryEntry(job: job, render: $0) } }
            .sorted { ($0.render.finished ?? $0.render.created) > ($1.render.finished ?? $1.render.created) }
    }
}

enum LibraryFilter: CaseIterable, Hashable {
    case all, drafts, finals

    var title: String {
        switch self {
        case .all: "All"
        case .drafts: "Drafts"
        case .finals: "Finals"
        }
    }

    func includes(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all: true
        case .drafts: entry.render.quality.isDraft
        case .finals: !entry.render.quality.isDraft
        }
    }
}

/// A frame of the result that plays while the pointer is over it, with the clip's name and the version.
private struct LibraryTile: View {
    let entry: LibraryEntry
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            ZStack {
                if let url = entry.url {
                    VideoStill(url: url)
                    if isHovered { LoopingVideo(url: url) }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                MediaTag(text: entry.job.title).padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Text(entry.name)
                    .font(.system(size: 9, weight: .heavy))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(entry.render.quality.isDraft ? Theme.text : Theme.ink)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(entry.render.quality.isDraft ? Theme.scrim : Theme.accent, in: Capsule())
                    .padding(6)
            }
            .card(radius: Theme.Radius.field, isHighlighted: isHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(entry.job.title), \(entry.name)")
    }
}
