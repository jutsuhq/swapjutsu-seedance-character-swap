import AppKit
import SwiftUI

/// One piece of work: what it is, its steps, the latest line, and Cancel, Resume or Dismiss.
struct WorkRow: View {
    let work: Work
    @Environment(JobStore.self) private var jobs
    @Environment(Navigation.self) private var navigation
    @State private var isConfirmingRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.large) {
            VideoStill(url: job.manifest != nil ? job.control : job.source)
                .frame(width: 168, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .opacity(isActive ? 1 : 0.6)
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(job.title).font(Theme.Typography.rowTitle).lineLimit(1)
                    Text(job.spec.range?.text ?? job.rangeText)
                        .font(Theme.Typography.note)
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                    Pill(text: kind, dot: color)
                    if case .render(_, let render) = work, let origin = render.origin {
                        OriginTag(origin: origin)
                    } else if let origin = job.origin {
                        OriginTag(origin: origin)
                    }
                    Spacer(minLength: 0)
                    actions
                }
                WorkSteps(steps: steps)
                if isActive {
                    Text(detail)
                        .font(Theme.Typography.note)
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                        .help(detail)
                } else {
                    // Why it stopped, whole and copyable: paths and request ids included.
                    FullText(text: detail, color: detailColor)
                }
                if isActive { ProgressView().progressViewStyle(.linear).tint(Theme.accent) }
            }
        }
        .padding(Theme.Spacing.medium)
        .card()
    }

    private var job: Job {
        switch work {
        case .prep(let job), .render(let job, _): job
        }
    }

    private var isActive: Bool {
        switch work {
        case .prep(let job): job.stage.isActive
        case .render(_, let render): render.stage.isActive
        }
    }

    private var kind: String {
        switch work {
        case .prep(let job): job.stage.title
        case .render(let job, let render):
            "\(render.parent == nil ? job.name(of: render) : "Finalizing") · \(job.stageTitle(of: render))"
        }
    }

    private var color: Color {
        switch work {
        case .prep(let job): job.stage.color
        case .render(_, let render): render.stage.color
        }
    }

    private var detail: String {
        switch work {
        case .prep(let job): job.detail.isEmpty ? "Free, on this Mac" : job.detail
        case .render(_, let render): render.detail.isEmpty ? "Started \(render.created.shortStamp)" : render.detail
        }
    }

    private var detailColor: Color {
        switch work {
        case .prep(let job): job.stage == .failed ? Theme.danger : Theme.muted
        case .render(_, let render):
            render.stage == .failed
                ? Theme.danger : [.unknown, .waiting].contains(render.stage) ? Theme.warning : Theme.muted
        }
    }

    private var steps: [WorkSteps.Step] {
        switch work {
        case .prep(let job):
            let state: WorkSteps.State =
                switch job.stage {
                case .preparing: .now
                case .failed: .failed
                default: .later
                }
            return [.init(title: "Prep on Mac", state: state)]
        case .render(_, let render):
            let order: [Render.Stage] = [.uploading, .generating, .downloading, .exporting]
            let titles = [render.parent == nil ? "Upload" : "Send", "Render", "Download", "Soundtrack"]
            // A stopped render stopped at the step after what it has; one waiting for the person has started none.
            let reached: Int =
                switch render.stage {
                case .uploading, .generating, .downloading, .exporting: order.firstIndex(of: render.stage) ?? 0
                case .waiting: -1
                default: render.generated != nil ? 3 : render.providerJobID != nil ? 1 : 0
                }
            return titles.enumerated().map { index, title in
                let state: WorkSteps.State =
                    index < reached ? .done : index > reached ? .later : render.stage.isActive ? .now : .failed
                return .init(title: title, state: state)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            switch work {
            case .prep(let job):
                if job.stage.isActive {
                    Button("Cancel Prep", systemImage: "stop.circle") { jobs.cancel(job) }
                        .buttonStyle(.secondaryAction)
                        .help("Stop preparing this clip; it can be prepared again, for free")
                } else {
                    Button("Prepare Again", systemImage: "arrow.clockwise") { jobs.prepareAgain(job) }
                        .buttonStyle(.secondaryAction)
                    Button("Remove", systemImage: "trash", role: .destructive) { isConfirmingRemove = true }
                        .buttonStyle(.iconAction)
                        .help("Remove the clip (files stay on disk)")
                        .confirmationDialog(
                            "Remove \(job.title)?", isPresented: $isConfirmingRemove, titleVisibility: .visible
                        ) {
                            Button("Remove", role: .destructive) { jobs.remove(job) }
                        } message: {
                            Text("It leaves Create and Library. The files stay in its folder on disk.")
                        }
                }
            case .render(let job, let render):
                Button("Open Clip in Create", systemImage: "arrow.up.forward.app") { navigation.open(job.id) }
                    .buttonStyle(.iconAction)
                    .help("Open the clip in Create")
                if render.stage.isActive {
                    Button("Cancel Render", systemImage: "stop.circle") { jobs.cancel(render, of: job) }
                        .buttonStyle(.iconAction)
                        .help(job.cancelHelp(of: render))
                } else {
                    Button(
                        job.retryTitle(of: render),
                        systemImage: render.stage == .waiting ? "paperplane" : "arrow.clockwise"
                    ) {
                        jobs.retry(render, of: job, by: .person)
                    }
                    .buttonStyle(.secondaryAction)
                    .help(job.retryHelp(of: render))
                    Button("Dismiss", systemImage: "xmark") { jobs.remove(render, of: job) }
                        .buttonStyle(.iconAction)
                        .disabled(!render.canDismiss)
                        .help(job.dismissHelp(of: render))
                }
            }
        }
    }
}

/// "✓ Upload — 2 Render — 3 Download — 4 Soundtrack".
struct WorkSteps: View {
    enum State { case done, now, later, failed }

    struct Step {
        let title: String
        let state: State
    }

    let steps: [Step]

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Rectangle()
                        .fill(step.state == .later ? Theme.stroke : Theme.accent.opacity(0.4))
                        .frame(height: 1)
                        .frame(minWidth: 12, maxWidth: 48)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(fill(step.state))
                        Circle().strokeBorder(stroke(step.state), lineWidth: 1)
                        Text(symbol(step.state, index))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(color(step.state))
                    }
                    .frame(width: 18, height: 18)
                    Text(step.title)
                        .font(Theme.Typography.strongMeta)
                        .foregroundStyle(
                            step.state == .later ? Theme.faint : step.state == .failed ? Theme.danger : Theme.text)
                }
                .fixedSize()
            }
        }
    }

    private func symbol(_ state: State, _ index: Int) -> String {
        switch state {
        case .done: "✓"
        case .failed: "!"
        case .now, .later: "\(index + 1)"
        }
    }

    private func color(_ state: State) -> Color {
        switch state {
        case .done: Theme.accent
        case .now: Theme.ink
        case .later: Theme.faint
        case .failed: Theme.danger
        }
    }

    private func fill(_ state: State) -> Color {
        switch state {
        case .now: Theme.accent
        case .done: Theme.glass
        default: .clear
        }
    }

    private func stroke(_ state: State) -> Color {
        switch state {
        case .later: Theme.glassStroke
        case .failed: Theme.danger
        default: .clear
        }
    }
}
