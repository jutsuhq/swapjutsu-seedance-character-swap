import SwiftUI

/// A new clip first, then every clip grouped by what it needs, with one button to draft all the ready ones.
struct ClipRail: View {
    @Binding var selection: UUID?
    @Environment(JobStore.self) private var jobs
    @Environment(Credentials.self) private var credentials
    @State private var isConfirmingBatch = false

    var body: some View {
        let groups = ClipGroup.ordered(jobs.jobs)
        let ready = groups.first { $0.group == .ready }?.jobs ?? []
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    NewClipRow(isSelected: selection == nil) { selection = nil }
                    ForEach(groups, id: \.group) { section in
                        SectionLabel(title: section.group.title, detail: "\(section.jobs.count)")
                            .padding(.horizontal, 6)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                        ForEach(section.jobs) { job in
                            ClipRow(job: job, isSelected: job.id == selection) { selection = job.id }
                        }
                    }
                }
                .padding(Theme.Spacing.small)
            }
            if ready.count > 1 {
                Divider().overlay(Theme.stroke)
                Button {
                    isConfirmingBatch = true
                } label: {
                    Label("Draft All \(ready.count) Ready", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryAction)
                .disabled(!credentials.hasComfyKey)
                .help(
                    credentials.hasComfyKey
                        ? "A 480p draft of every ready clip, with the total before anything is sent"
                        : "Add your Comfy API key in Settings to render"
                )
                .padding(Theme.Spacing.medium)
                .confirmationDialog(
                    "Render \(ready.count) drafts?", isPresented: $isConfirmingBatch, titleVisibility: .visible
                ) {
                    Button("Render \(ready.count) Drafts") {
                        for job in ready { jobs.render(job, quality: .draft, model: .seedance25) }
                    }
                } message: {
                    Text(
                        "480p drafts of every ready clip, about \(SeedancePrice.text(total(ready))) from your Comfy credits."
                    )
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func total(_ ready: [Job]) -> ClosedRange<Double> {
        ready.reduce(0...0) { sum, job in
            let price = SeedancePrice.estimate(seconds: job.duration ?? 0, quality: .draft)
            return (sum.lowerBound + price.lowerBound)...(sum.upperBound + price.upperBound)
        }
    }
}

/// The new clip: where a video is dropped, trimmed and prepared.
private struct NewClipRow: View {
    let isSelected: Bool
    let action: () -> Void
    @Environment(Draft.self) private var draft

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let source = draft.source {
                        VideoStill(url: source)
                    } else {
                        Theme.well.overlay {
                            Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(
                                Theme.accent)
                        }
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New clip").font(Theme.Typography.strong).foregroundStyle(Theme.text)
                    Text(draft.source == nil ? "Drop a video or pick an example" : draft.sourceTitle)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.faint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.small)
            .background(isSelected ? Theme.glass : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field)
                    .strokeBorder(
                        isSelected ? Theme.accent : Theme.stroke,
                        style: StrokeStyle(lineWidth: 1, dash: isSelected ? [] : [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A clip in the rail: a frame of its best version, its name, range and where it stands.
private struct ClipRow: View {
    let job: Job
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VideoStill(url: preview)
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .opacity(job.stage.isActive ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(Theme.Typography.strong).foregroundStyle(Theme.text).lineLimit(2)
                    Text(status)
                        .font(Theme.Typography.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if job.isActive { ProgressView().controlSize(.small) }
            }
            .padding(Theme.Spacing.small)
            .background(isSelected ? Theme.glass : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var preview: URL {
        if let done = job.finished.last, let url = job.resultURL(of: done) { return url }
        return job.manifest != nil ? job.control : job.source
    }

    /// The range, then what's happening or what there is.
    private var status: String {
        let range = job.spec.range?.text ?? job.rangeText
        if job.stage != .prepared { return job.stage.title }
        if let active = job.renders.last(where: { $0.stage.isActive }) {
            return "\(job.name(of: active)) · \(job.stageTitle(of: active))"
        }
        let done = job.finished
        if done.isEmpty, job.missingCharacters > 0 {
            return "\(range) · \(job.missingCharacters) missing"
        }
        if done.isEmpty { return range }
        return "\(range) · \(done.map { job.name(of: $0) }.joined(separator: ", "))"
    }
}
