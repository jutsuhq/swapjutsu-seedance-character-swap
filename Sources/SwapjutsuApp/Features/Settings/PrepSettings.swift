import AppKit
import SwiftUI

/// What new clips start with, and the models prep runs.
struct PrepSettings: View {
    @AppStorage(PrepDefaults.targetKey) private var target = PrepTarget.main
    @AppStorage(PrepDefaults.faceGuideKey) private var faceGuide = false
    @AppStorage(PrepDefaults.removeBackgroundKey) private var removeBackground = false
    @AppStorage(PrepDefaults.replaceBackgroundKey) private var replaceBackground = false
    @AppStorage(SampleLibrary.consentKey) private var showsExamples = false
    /// A security-scoped bookmark (`DepthModel.chosenDepth`), nil for the app's own copy.
    @AppStorage(AppPaths.depthModelKey) private var depthModel: Data?
    @Environment(Draft.self) private var draft
    @Environment(DepthModel.self) private var depth
    @Environment(TrackingModel.self) private var tracking

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "New clips",
                footer: "Each clip keeps its own: change it on the clip and prepare again, for free."
            ) {
                SettingsRow(label: "Replace", detail: "The main person, or everyone prep finds", isFirst: true) {
                    SegmentedControl(
                        selection: $target, options: [(.main, "Main"), (.all, "Everyone")], isCompact: true
                    )
                    .fixedSize()
                }
                SettingsRow(label: "Lip-sync guide", detail: "Face landmarks over the depth, to guide the lips") {
                    Toggle("Lip-sync guide", isOn: $faceGuide).settingsSwitch()
                }
                SettingsRow(label: "Cut out characters", detail: "Character images go to Seedance cut out onto grey") {
                    Toggle("Cut out characters", isOn: $removeBackground).settingsSwitch()
                }
                SettingsRow(label: "Replace background", detail: "Grey depth around the people, for a new place") {
                    Toggle("Replace background", isOn: $replaceBackground).settingsSwitch()
                }
                SettingsRow(
                    label: "Higgsfield examples", detail: "Create loads Higgsfield's public gallery from its servers"
                ) {
                    Toggle("Higgsfield examples", isOn: $showsExamples).settingsSwitch()
                }
            }
            SettingsSection(
                title: "Depth model",
                footer: "Depth Anything V2 Small, Core ML, about 48 MB. The first prep puts it in Application "
                    + "Support once; every build of the app uses that copy. Core ML optimizes each new copy for this "
                    + "Mac's Neural Engine once, in the background. Choose another only to try a different model."
            ) {
                ModelStatusRow(model: depth, isChosen: depthModel != nil)
                SettingsRow(label: "Model", detail: depthModel == nil ? "The app's own copy" : "Chosen by you") {
                    HStack(spacing: Theme.Spacing.small) {
                        Button("Choose…", action: chooseModel).buttonStyle(.secondaryAction)
                        if depthModel != nil {
                            Button("Use the App's") { depthModel = nil }.buttonStyle(.secondaryAction)
                        }
                    }
                }
            }
            SettingsSection(
                title: "Tracking model",
                footer: "EdgeTAM by Meta, our Core ML conversion, Apache-2.0, about 51 MB: keeps one steady "
                    + "mask per person through a shot. Kept in Application Support and optimized once, like the "
                    + "depth model."
            ) {
                ModelStatusRow(model: tracking, isChosen: false)
            }
            ForEach([depth.failure, tracking.failure].compactMap(\.self), id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.danger)
            }
        }
        // The new clip being filled in follows the defaults until it is prepared.
        .onChange(of: target) { _, value in if draft.source == nil { draft.target = value } }
        .onChange(of: faceGuide) { _, value in if draft.source == nil { draft.faceGuide = value } }
        .onChange(of: removeBackground) { _, value in if draft.source == nil { draft.removeBackground = value } }
        .onChange(of: replaceBackground) { _, value in if draft.source == nil { draft.replaceBackground = value } }
        // A newly chosen model is optimized now, not in the next prep.
        .onChange(of: depthModel) { depth.warm() }
    }

    /// An .mlpackage is a folder, so the panel picks packages and folders.
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the depth model (.mlpackage or .mlmodelc)"
        if panel.runModal() == .OK, let url = panel.url { depthModel = try? DepthModel.depthBookmark(for: url) }
    }
}

/// Where a model is: downloading, optimizing, ready (with Show in Finder) or missing (with Download, unless the
/// person chose a model of their own).
private struct ModelStatusRow<Loaded: Sendable>: View {
    let model: LocalModel<Loaded>
    /// Also makes the row follow a new choice.
    let isChosen: Bool

    var body: some View {
        SettingsRow(label: title, detail: detail, isFirst: true) {
            HStack(spacing: Theme.Spacing.small) {
                if model.isFetching || model.isOptimizing {
                    ProgressView().controlSize(.small)
                } else if model.exists {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
                        .buttonStyle(.secondaryAction)
                } else if !isChosen {
                    Button("Download") { Task { try? await model.ensure() } }
                        .buttonStyle(.primaryAction)
                }
            }
        }
    }

    private var title: String {
        switch model.phase {
        case .missing: "Not downloaded yet"
        case .fetching: "Downloading…"
        case .optimizing: "Optimizing…"
        case .ready: "Ready"
        }
    }

    private var detail: String {
        model.isOptimizing
            ? "Optimizing the \(model.files.title) for this Mac, once" : model.url.path(percentEncoded: false)
    }
}
