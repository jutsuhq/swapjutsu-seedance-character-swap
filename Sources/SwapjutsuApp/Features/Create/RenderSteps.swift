import SwiftUI

/// What the renders in the player are doing: the one on its way, the one that stopped, and finalizing the draft on
/// screen. It sits above the steps, next to the result it is about.
struct RenderStatus: View {
    let job: Job
    let version: ClipVersion
    let show: (ClipVersion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let active = job.renders.last(where: { $0.stage.isActive }) {
                ActiveRender(job: job, render: active)
            } else if let stopped = job.renders.last, stopped.stage.isStopped || stopped.stage == .waiting {
                StoppedRender(job: job, render: stopped)
            }
            if let draft = version.draft(in: job) { DraftBox(job: job, draft: draft, show: show) }
        }
    }
}

extension ClipVersion {
    /// The draft this version shows, if it is one.
    @MainActor
    func draft(in job: Job) -> Render? {
        guard case .render(let id) = self, let render = job.render(id), render.quality.isDraft else { return nil }
        return render
    }
}

/// What a new render of the clip would be: the generator, the quality, its price and what blocks it. Step 5 picks
/// it; the bar under the steps sends it.
@MainActor
struct RenderPlan {
    let job: Job
    let quality: RenderQuality
    let hasOwnComfy: Bool
    let hasComfyKey: Bool

    /// The generator this render goes to: the clip's, except Wan 2.2 Animate without an own ComfyUI that passed its
    /// Check, which falls back to Seedance.
    var model: GenerationModel { job.model == .wan22Animate && !hasOwnComfy ? .seedance25 : job.model }

    /// The generators step 5 offers: Wan 2.2 Animate only with an own ComfyUI.
    var models: [GenerationModel] { hasOwnComfy ? GenerationModel.allCases : [.seedance25, .wan30] }

    /// The picked quality, or the generator's first when it doesn't render that one.
    var chosen: RenderQuality { model.qualities.contains(quality) ? quality : model.qualities[0] }

    var price: String { model.priceText(seconds: job.duration ?? 0, quality: chosen) }

    /// Why nothing can be rendered yet.
    var blocker: String? {
        if job.stage != .prepared { return "Renders once prep is done." }
        if job.isRendering { return "One render at a time; this one is on its way." }
        if let limit = model.maxSeconds, let seconds = job.duration, seconds > limit + 0.01 {
            return "\(model.title) edits clips of up to \(Int(limit)) s; this one is \(Int(seconds.rounded(.up))) s."
        }
        if model == .wan22Animate { return JobStore.whyNotAnimatable(job) }
        let missing = job.missingCharacters
        if missing > 0 { return "Add \(missing == 1 ? "a character image" : "\(missing) character images") first." }
        if job.missingBackground { return "Add the image of the new background first." }
        if !model.isLocal, !hasComfyKey { return "Add your Comfy API key in Settings to render." }
        return nil
    }

    var title: String {
        model == .wan22Animate
            ? "Generate with Wan \(chosen.resolution)"
            : chosen.isDraft ? "Generate Draft" : "Generate \(chosen.title)"
    }
}

/// Step 5: the generator (Seedance 2.5, Wan 3.0, and Wan 2.2 Animate when the person set up their own ComfyUI), then
/// Draft 480p or a final at 720p or 1080p with the price for Seedance, a final at 480p, 720p or 1080p for Wan 3.0, or
/// 480p or 720p for $0 for Wan 2.2 Animate. The Generate button is in `RenderBar`, always
/// in sight under the steps.
struct NewRender: View {
    let job: Job
    @Binding var quality: RenderQuality
    @Environment(JobStore.self) private var jobs
    @Environment(Credentials.self) private var credentials
    @Environment(Navigation.self) private var navigation
    @AppStorage(OwnComfy.enabledKey) private var ownComfyEnabled = false
    @AppStorage(OwnComfy.urlKey) private var ownComfyURL = OwnComfy.defaultURL
    @AppStorage(OwnComfy.checkedKey) private var ownComfyChecked = ""

    private var plan: RenderPlan {
        RenderPlan(
            job: job, quality: quality,
            hasOwnComfy: OwnComfy.isReady(enabled: ownComfyEnabled, address: ownComfyURL, checked: ownComfyChecked),
            hasComfyKey: credentials.hasComfyKey)
    }

    var body: some View {
        let plan = plan
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 6) {
                SegmentedControl(
                    selection: Binding(get: { plan.model }, set: { jobs.setModel($0, of: job) }),
                    options: plan.models.map { ($0, $0.title) }, isCompact: true)
                Text(
                    plan.model == .wan22Animate
                        ? "Your ComfyUI, open source · runs on your machine"
                        : "Comfy Cloud · paid from your credits"
                )
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.faint)
            }
            .help(plan.model.pickerTitle)
            ownComfyLink(plan)
            if !plan.model.isLocal, !credentials.hasComfyKey {
                Notice(
                    systemImage: "key", text: "Add your Comfy API key to render; prep needs none.",
                    action: ("Open Settings", { navigation.settings(.comfy) }))
            }
            SegmentedControl(
                selection: Binding(get: { plan.chosen }, set: { quality = $0 }),
                options: plan.model.qualities.map { ($0, $0.title) }, isCompact: true)
            if plan.model == .seedance25, plan.chosen.isDraft, let small = job.facePixels(at: .draft),
                small < Job.smallFace,
                let larger = job.facePixels(at: .final720)
            {
                Notice(
                    systemImage: "face.smiling",
                    text: "Faces are about \(small) px tall at 480p, too small to keep the character's face. Final "
                        + "720p draws them at \(larger) px for "
                        + "\(SeedancePrice.text(seconds: job.duration ?? 0, quality: .final720)).",
                    action: ("Use 720p", { quality = .final720 }))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(explanation(plan))
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.small)
                Text(plan.price)
                    .font(Theme.Typography.strong)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            Text(plan.blocker ?? footnote(plan))
                .font(Theme.Typography.meta)
                .foregroundStyle(plan.blocker == nil ? Theme.faint : Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the own ComfyUI is set up: to add Wan 2.2 Animate, or to change it.
    private func ownComfyLink(_ plan: RenderPlan) -> some View {
        Button(plan.hasOwnComfy ? "Own ComfyUI settings…" : "Render free with Wan 2.2 Animate on your own ComfyUI…") {
            navigation.settings(.ownComfy)
        }
        .buttonStyle(.plain)
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.accent)
        .pointerCursor()
        .help("Settings › Own ComfyUI")
    }

    private func footnote(_ plan: RenderPlan) -> String {
        plan.model == .wan22Animate
            ? "Runs on your ComfyUI at \(OwnComfy.parse(ownComfyURL)?.host() ?? "your server"), on its GPU; nothing is "
                + "paid. It runs in Jobs; the result opens here and lands in Library."
            : "Paid from your Comfy credits. It runs in Jobs; the result opens here and lands in Library."
    }

    private func explanation(_ plan: RenderPlan) -> String {
        if plan.model == .wan22Animate {
            let windows = WanAnimateWorkflow.windows(
                frames: Int(((job.duration ?? 0) * Double(WanAnimateWorkflow.fps)).rounded())
            ).count
            return "Wan 2.2 Animate replaces the person with your character and keeps the clip's light and background. "
                + (windows > 1 ? "Renders in \(windows) windows of about 5 s; " : "")
                + "needs a GPU with enough memory."
        }
        if plan.model == .wan30 {
            return "Wan 3.0 redraws the person from the same depth control, as long as the clip (up to 15 s). No draft; "
                + "Comfy bills the control video's seconds and the render's."
        }
        switch plan.chosen {
        case .draft: return "A quick 480p look, about 2 min. Finalize the one you like within 7 days, same motion."
        case .final480, .final720, .final1080: return "Full quality straight away, no draft."
        }
    }
}

/// Under the clip's steps, always in sight: what step 5 picked (quality, generator, price) and Generate. A draft on
/// screen that can be finalized makes Finalize the main action and Generate the second.
struct RenderBar: View {
    let job: Job
    let version: ClipVersion
    let quality: RenderQuality
    let show: (ClipVersion) -> Void
    @Environment(JobStore.self) private var jobs
    @Environment(Credentials.self) private var credentials
    @AppStorage(OwnComfy.enabledKey) private var ownComfyEnabled = false
    @AppStorage(OwnComfy.urlKey) private var ownComfyURL = OwnComfy.defaultURL
    @AppStorage(OwnComfy.checkedKey) private var ownComfyChecked = ""

    var body: some View {
        let plan = RenderPlan(
            job: job, quality: quality,
            hasOwnComfy: OwnComfy.isReady(enabled: ownComfyEnabled, address: ownComfyURL, checked: ownComfyChecked),
            hasComfyKey: credentials.hasComfyKey)
        HStack(spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.chosen.title) · \(plan.model.title) · \(plan.price)")
                    .font(Theme.Typography.strongNote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(plan.blocker ?? (plan.model.isLocal ? "Free, on your ComfyUI" : "Paid from your Comfy credits"))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(plan.blocker == nil ? Theme.faint : Theme.warning)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.small)
            Group {
                if finalizeComesFirst {
                    Button {
                        render(plan)
                    } label: {
                        Label(plan.title, systemImage: "sparkles")
                    }
                    .buttonStyle(.secondaryAction)
                } else {
                    Button {
                        render(plan)
                    } label: {
                        Label(plan.title, systemImage: "sparkles")
                    }
                    .buttonStyle(.primaryAction)
                }
            }
            .fixedSize()
            .disabled(plan.blocker != nil)
            .help(plan.blocker ?? "\(plan.title), \(plan.price)")
        }
    }

    /// The draft on screen can be finalized: then that is the main action and a new render the second.
    private var finalizeComesFirst: Bool {
        guard let draft = version.draft(in: job) else { return false }
        return draft.canFinalize() && job.final(of: draft) == nil
    }

    private func render(_ plan: RenderPlan) {
        guard let render = jobs.render(job, quality: plan.chosen, model: plan.model) else { return }
        show(.render(render.id))
    }
}

/// The draft on screen: finalize it at 1080p, or where its final is, or why it can't be finalized any more.
private struct DraftBox: View {
    let job: Job
    let draft: Render
    let show: (ClipVersion) -> Void
    @Environment(JobStore.self) private var jobs
    @Environment(Credentials.self) private var credentials

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text("Finalize \(job.name(of: draft))").font(Theme.Typography.rowTitle).foregroundStyle(Theme.text)
                Spacer()
                Text(SeedancePrice.text(seconds: job.duration ?? 0, quality: .final1080))
                    .font(Theme.Typography.strong)
                    .monospacedDigit()
            }
            if let final = job.final(of: draft) {
                Text(
                    final.stage == .done
                        ? "Finalized as \(job.name(of: final))."
                        : final.stage == .waiting ? "Its final waits for you to send it." : "Its final is rendering."
                )
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.muted)
                if final.stage == .done {
                    Button("Show the Final", systemImage: "play.rectangle") { show(.render(final.id)) }
                        .buttonStyle(.secondaryAction)
                }
            } else if draft.canFinalize() {
                Text(
                    "Renders this draft at 1080p: the motion, timing and faces stay as you see them. Only the draft's "
                        + "task is sent. Possible until \(draft.finalizableUntil.formatted(date: .abbreviated, time: .shortened))."
                )
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    jobs.finalize(draft, of: job)
                } label: {
                    Label("Finalize 1080p", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryAction)
                .disabled(!credentials.hasComfyKey || job.isRendering)
                .help(
                    !credentials.hasComfyKey
                        ? "Add your Comfy API key in Settings to finalize"
                        : job.isRendering
                            ? "One render at a time; wait for the one on its way" : "Render this draft at 1080p")
            } else {
                Text(
                    draft.draftTaskID == nil
                        ? "Comfy didn't return this draft's task, so it can't be finalized; render a final instead."
                        : "Seedance keeps drafts for 7 days; this one expired. Render a final instead."
                )
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.large)
        .background(
            Theme.accent.opacity(job.final(of: draft) == nil && draft.canFinalize() ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: Theme.Radius.field)
        )
        .well(radius: Theme.Radius.field)
    }
}

/// The render on its way: stage, progress line, Cancel, and the way to Jobs.
private struct ActiveRender: View {
    let job: Job
    let render: Render
    @Environment(JobStore.self) private var jobs
    @Environment(Navigation.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(job.name(of: render)).font(Theme.Typography.rowTitle)
                Pill(text: job.stageTitle(of: render), dot: render.stage.color)
                Spacer()
            }
            ProgressView().progressViewStyle(.linear).tint(Theme.accent)
            Text(render.detail.isEmpty ? "Started \(render.created.shortStamp)" : render.detail)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
            HStack {
                Button("Cancel", systemImage: "stop.circle") { jobs.cancel(render, of: job) }
                    .buttonStyle(.secondaryAction)
                    .help(job.cancelHelp(of: render))
                Button("See in Jobs") { navigation.screen = .jobs }
                    .buttonStyle(.secondaryAction)
            }
            if jobs.unsaved.contains(render.id) {
                Text("Don't quit: this paid request isn't saved yet, and quitting now would lose it.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.warning)
            } else {
                Text("Quitting is safe: the render resumes on the next launch at no extra cost.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(Theme.Spacing.large)
        .well(radius: Theme.Radius.field)
    }
}

/// The last render stopped, or an agent's waits for the person: why, and Resume (free), Try Again or Send (with the
/// price).
private struct StoppedRender: View {
    let job: Job
    let render: Render
    @Environment(JobStore.self) private var jobs

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(job.name(of: render)).font(Theme.Typography.rowTitle)
                Pill(text: job.stageTitle(of: render), dot: render.stage.color)
                Spacer()
            }
            FullText(
                text: render.detail,
                color: [.unknown, .waiting].contains(render.stage)
                    ? Theme.warning : render.stage == .failed ? Theme.danger : Theme.muted)
            HStack {
                Button(
                    job.retryTitle(of: render), systemImage: render.stage == .waiting ? "paperplane" : "arrow.clockwise"
                ) {
                    jobs.retry(render, of: job, by: .person)
                }
                .buttonStyle(.secondaryAction)
                .help(job.retryHelp(of: render))
                Button("Dismiss") { jobs.remove(render, of: job) }
                    .buttonStyle(.secondaryAction)
                    .disabled(!render.canDismiss)
                    .help(job.dismissHelp(of: render))
            }
        }
        .padding(Theme.Spacing.large)
        .well(radius: Theme.Radius.field)
    }
}

/// A line with an icon and an optional button, for what blocks rendering.
struct Notice: View {
    let systemImage: String
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: systemImage).foregroundStyle(Theme.warning)
            Text(text).font(Theme.Typography.note).foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.secondaryAction)
            }
        }
        .padding(Theme.Spacing.medium)
        .well(radius: Theme.Radius.field)
    }
}
