import SwiftUI

/// Jobs: only the work on its way (prep on the Mac, renders on Comfy) and what stopped. Finished work leaves the
/// list: clips go back to Create, results to Library.
struct JobsView: View {
    @Environment(JobStore.self) private var jobs
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let sections = WorkSection.of(jobs.jobs)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "Jobs",
                subtitle: "What's running on this Mac and on Comfy. Quitting is safe; renders resume.")
            if sections.isEmpty {
                EmptyState(
                    systemImage: "square.stack.3d.up", title: "Nothing running",
                    message: "Prep and renders start from Create. Finished results are in Library.",
                    action: ("Go to Create", { navigation.screen = .create }))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        ForEach(sections, id: \.title) { section in
                            SectionLabel(title: section.title, detail: "\(section.items.count)")
                                .padding(.top, section.title == sections.first?.title ? 0 : Theme.Spacing.small)
                            ForEach(section.items) { WorkRow(work: $0) }
                        }
                    }
                }
            }
        }
        .pagePadding()
    }
}

/// One piece of work: a clip's prep, or one of its renders.
enum Work: Identifiable {
    case prep(Job)
    case render(Job, Render)

    var id: UUID {
        switch self {
        case .prep(let job): job.id
        case .render(_, let render): render.id
        }
    }
}

struct WorkSection {
    let title: String
    let items: [Work]

    /// Agents' renders waiting for the person first, then running, then waiting for prep, then stopped; newest first
    /// inside each.
    @MainActor
    static func of(_ jobs: [Job]) -> [WorkSection] {
        var held: [Work] = [], running: [Work] = [], waiting: [Work] = [], stopped: [Work] = []
        for job in jobs {
            switch job.stage {
            case .preparing: running.append(.prep(job))
            case .waiting: waiting.append(.prep(job))
            case .failed: stopped.append(.prep(job))
            case .prepared, .canceled: break
            }
            for render in job.renders.reversed() {
                if render.stage == .waiting { held.append(.render(job, render)) }
                if render.stage.isActive { running.append(.render(job, render)) }
                // A canceled render whose request runs on stays listed: it may still finish and be charged.
                if render.stage == .failed || render.stage == .unknown
                    || (render.stage == .canceled && render.providerJobID != nil)
                {
                    stopped.append(.render(job, render))
                }
            }
        }
        return [("Waiting for you", held), ("Running", running), ("Waiting", waiting), ("Stopped", stopped)]
            .filter { !$0.1.isEmpty }
            .map { WorkSection(title: $0.0, items: $0.1) }
    }
}
