import AppKit
import SwapjutsuPrep
import SwiftUI

/// One clip: its versions in one player on the left; on the right what its renders are doing, then the steps from
/// prep to a render; under both, always in sight, the render bar with the price and Generate.
struct ClipWorkspace: View {
    let job: Job
    @Environment(JobStore.self) private var jobs
    @Environment(Navigation.self) private var navigation
    @State private var version: ClipVersion?
    @State private var isConfirmingRemove = false
    /// Step 5's pick, which the bar under the steps renders.
    @State private var quality = RenderQuality.draft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
            StageAndSide(aspect: job.manifest.flatMap { $0.height > 0 ? CGFloat($0.width) / CGFloat($0.height) : nil }) {
                VersionStage(job: job, version: current, select: { version = $0 })
            } side: {
                side
            }
            Divider().overlay(Theme.stroke)
            RenderBar(job: job, version: current, quality: quality) { version = $0 }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        // Library sends the person here with the result they were looking at.
        .onAppear {
            if let id = navigation.render, job.render(id) != nil { version = .render(id) }
            navigation.render = nil
        }
        // A render that just finished is what the person wants to see.
        .onChange(of: job.finished.last?.id) { _, id in if let id { version = .render(id) } }
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            RenderStatus(job: job, version: current) { version = $0 }
            Step(number: 1, title: "Video", detail: job.duration.map(Self.seconds), state: .done) {
                if let range = job.spec.range {
                    Text("\(range.text) of the source").font(Theme.Typography.note).foregroundStyle(Theme.muted)
                }
            }
            Step(number: 2, title: "Prep", detail: job.stage.title, state: job.stage == .prepared ? .done : .now) {
                PrepStep(job: job, show: { version = $0 })
            }
            Step(
                number: 3, title: "Characters", detail: characters,
                state: job.manifest == nil || job.missingCharacters > 0 || job.missingBackground ? .now : .done
            ) {
                CharactersStep(job: job)
            }
            Step(number: 4, title: "Prompt", detail: "Optional") {
                PromptEditor(text: Binding(get: { job.spec.prompt }, set: { jobs.setPrompt($0, of: job) }))
                DescriptionEditor(job: job)
            }
            Step(
                number: 5, title: "Render", state: job.stage == .prepared && job.missingCharacters == 0 && !job.missingBackground ? .now : .later
            ) {
                NewRender(job: job, quality: $quality)
            }
        }
    }

    private static func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }

    /// "1 of 2 + 1 extra": the replaced people with an image, and the images that replace no one.
    private var characters: String {
        let count = job.spec.references.count
        guard let targets = job.manifest?.targets.count else { return count == 0 ? "" : "\(count)" }
        let cast = targets - job.missingCharacters
        let more = job.spec.extras(for: job.manifest?.targets ?? []).count
        return "\(cast) of \(targets)" + (more > 0 ? " + \(more) extra" : "")
    }

    /// The picked version while it exists, else the newest result, else the control video, else the source.
    private var current: ClipVersion {
        if let version, version.exists(in: job) { return version }
        if let done = job.finished.last { return .render(done.id) }
        return job.manifest != nil ? .control : .original
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.display(30))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.small) {
                    Text(subtitle).foregroundStyle(Theme.muted).lineLimit(2)
                    if let origin = job.origin { OriginTag(origin: origin) }
                }
            }
            Spacer(minLength: Theme.Spacing.small)
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([job.output])
            }
            .buttonStyle(.iconAction)
            .help("Show the clip's folder in Finder")
            Button("Remove", systemImage: "trash", role: .destructive) { isConfirmingRemove = true }
                .buttonStyle(.iconAction)
                .disabled(job.isActive || job.hasLiveRequest)
                .help(removeHelp)
                .confirmationDialog(
                    "Remove \(job.title)?", isPresented: $isConfirmingRemove, titleVisibility: .visible
                ) {
                    Button("Remove", role: .destructive) { jobs.remove(job) }
                } message: {
                    Text("Its drafts and finals leave Create and Library. The files stay in its folder on disk.")
                }
        }
    }

    private var removeHelp: String {
        if job.isActive { return "Stop its prep or render first" }
        if job.hasLiveRequest { return "A stopped render's request may still run; resume it until it ends first" }
        return "Remove the clip and its results from the app"
    }

    private var subtitle: String {
        guard let manifest = job.manifest else { return job.rangeText }
        let people = manifest.replaceable.count
        return
            "\(job.rangeText) · \(manifest.width)×\(manifest.height) · \(people) \(people == 1 ? "person" : "people")"
    }
}

/// What the player shows.
enum ClipVersion: Hashable {
    case original, control, review
    case render(UUID)

    @MainActor
    func exists(in job: Job) -> Bool {
        switch self {
        case .original: true
        case .control, .review: job.manifest != nil
        case .render(let id): job.render(id)?.stage == .done
        }
    }
}

/// The player with a tab per version: the source, what Seedance reads, and every finished render.
private struct VersionStage: View {
    let job: Job
    let version: ClipVersion
    let select: (ClipVersion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ScrollView(.horizontal) {
                SegmentedControl(selection: Binding(get: { version }, set: select), options: options, isCompact: true)
                    .fixedSize()
            }
            if let url {
                PlayerView(url: url)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
                    .id(url)
            }
            Text(caption)
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var options: [(value: ClipVersion, title: String)] {
        var options: [(value: ClipVersion, title: String)] = [(.original, "Original")]
        if job.manifest != nil { options += [(.control, "Control"), (.review, "Review")] }
        options += job.finished.map { (.render($0.id), job.name(of: $0)) }
        return options
    }

    private var url: URL? {
        switch version {
        case .original: job.source
        case .control: job.control
        case .review: job.review
        case .render(let id): job.render(id).flatMap(job.resultURL)
        }
    }

    private var aspect: CGFloat {
        guard let manifest = job.manifest, manifest.height > 0 else { return 16 / 9 }
        return CGFloat(manifest.width) / CGFloat(manifest.height)
    }

    private var caption: String {
        switch version {
        case .original: return "The range as it was cut from the source, with its sound."
        case .control: return "What Seedance gets as @Video1: depth, with the people being replaced painted in color."
        case .review: return "Prep's check: who it found, who gets replaced, and the masks."
        case .render(let id):
            guard let render = job.render(id) else { return "" }
            let made = render.finished.map { " · \($0.shortStamp)" } ?? ""
            return "\(render.quality.title) by \(job.model(of: render).title), with the original soundtrack\(made)."
        }
    }
}

/// Prep: on its way, with Cancel; stopped, with Prepare Again; or done, with what it found and the way to prepare
/// again with other options.
private struct PrepStep: View {
    let job: Job
    let show: (ClipVersion) -> Void
    @Environment(JobStore.self) private var jobs
    @Environment(DepthModel.self) private var depth
    @Environment(TrackingModel.self) private var tracking
    @Environment(TargetFixes.self) private var fixes
    @Environment(\.revealInSide) private var revealInSide
    @State private var isChanging = false
    @State private var choice = ReplaceChoice.preset(.main)
    @State private var faceGuide = false
    @State private var replaceBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if job.stage.isActive {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                line(job.detail.isEmpty ? "Waiting for the clip before it" : job.detail, color: Theme.muted)
                if depth.isOptimizing {
                    line("Optimizing the depth model for this Mac, once", color: Theme.muted)
                }
                if tracking.isOptimizing {
                    line("Optimizing the tracking model for this Mac, once", color: Theme.muted)
                }
                Button("Cancel Prep", systemImage: "stop.circle") { jobs.cancel(job) }
                    .buttonStyle(.secondaryAction)
                line("Free, on this Mac. Add the characters meanwhile.", color: Theme.faint)
            } else if job.stage == .prepared, let manifest = job.manifest {
                line(found(manifest), color: Theme.muted)
                ForEach(warnings(manifest), id: \.self) { PrepWarningLine(warning: PrepWarning($0)) }
                // On one line while it fits; the narrow column puts the links under the buttons.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.small) {
                        views
                        Spacer(minLength: Theme.Spacing.small)
                        links
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        views
                        links
                    }
                }
                if fix.isOpen {
                    TargetFixPanel(fix: fix).id(TargetFixPanel.anchor)
                        .task { revealInSide(TargetFixPanel.anchor) }
                }
                if isChanging { options }
            } else {
                FullText(text: job.detail, color: job.stage == .failed ? Theme.danger : Theme.muted)
                options
            }
        }
    }

    private var fix: TargetFix { fixes.fix(for: job) }

    private var views: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Control") { show(.control) }.buttonStyle(.secondaryAction)
                .help("What Seedance gets as @Video1")
            Button("Review") { show(.review) }.buttonStyle(.secondaryAction)
                .help("Who prep found and who gets replaced")
        }
        .fixedSize()
    }

    private var links: some View {
        HStack(spacing: Theme.Spacing.medium) {
            toggle(fix.isOpen ? "Close Fix" : "Fix Target…") { fix.isOpen.toggle() }
            toggle(isChanging ? "Close" : "Prepare Again…") { isChanging.toggle() }
        }
        .fixedSize()
    }

    /// Every warning prep left, or the line the clip has since.
    private func warnings(_ manifest: Manifest) -> [String] {
        manifest.warnings.isEmpty ? [job.detail].filter { !$0.isEmpty } : manifest.warnings
    }

    private func toggle(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Theme.Typography.strongNote)
            .foregroundStyle(Theme.accent)
            .pointerCursor()
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            CreateOptions(
                target: Binding(get: { choice.preset ?? job.spec.target }, set: { choice = .preset($0) }),
                faceGuide: $faceGuide, replaceBackground: $replaceBackground, people: people)
            Button("Prepare Again", systemImage: "arrow.clockwise") {
                jobs.prepareAgain(job, replacing: choice, faceGuide: faceGuide, replaceBackground: replaceBackground)
                isChanging = false
            }
            .buttonStyle(.primaryAction)
            .disabled(job.isRendering)
            .help(job.isRendering ? "Wait for the render on its way" : "Free; renders already made stay")
        }
        .onAppear {
            choice = ReplaceChoice(job.spec)
            faceGuide = job.spec.faceGuide
            replaceBackground = job.spec.replaceBackground
        }
    }

    /// Person by person once prep found more than one, or while people picked before are kept.
    private var people: PeoplePick? {
        let found = (job.manifest?.replaceable ?? []).map {
            PeoplePick.Person(id: $0.id, face: $0.thumbnail.map { job.output.appending(path: $0) })
        }
        guard found.count > 1 || choice.preset == nil else { return nil }
        return PeoplePick(found: found, choice: $choice)
    }

    /// "2 people found · 1 replaced · presence 98%".
    private func found(_ manifest: Manifest) -> String {
        let people = manifest.replaceable.count
        let presence = manifest.quality.targetPresence.formatted(.percent.precision(.fractionLength(0)))
        return "\(people) \(people == 1 ? "person" : "people") found · \(manifest.targets.count) replaced · "
            + "on screen \(presence) of the time"
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Typography.note)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
