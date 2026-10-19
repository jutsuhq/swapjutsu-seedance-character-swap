import AppKit
import SwiftUI

/// Where results go and what the app keeps on disk.
struct StorageSettings: View {
    @Environment(JobStore.self) private var jobs
    @Environment(Draft.self) private var draft
    @State private var resultsSize: Int64?
    @State private var samplesSize: Int64?
    @State private var isConfirmingClear = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SettingsSection(
                title: "Clips and results",
                footer: "Every clip has its own folder: its inputs, the control video, and every draft and final. "
                    + "Removing a clip in the app leaves its folder on disk."
            ) {
                SettingsRow(label: "Folder", detail: AppPaths.jobs.path(percentEncoded: false), isFirst: true) {
                    Button("Show in Finder") { reveal(AppPaths.jobs) }.buttonStyle(.secondaryAction)
                }
                SettingsRow(label: "Clips", value: "\(jobs.jobs.count) · \(text(resultsSize))")
            }
            SettingsSection(
                title: "Examples",
                footer: "Downloaded example clips and characters, reused when picked again. Clearing is safe: a clip "
                    + "keeps its own copies once prep has copied them."
            ) {
                SettingsRow(label: "Cache", detail: AppPaths.samples.path(percentEncoded: false), isFirst: true) {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(text(samplesSize)).font(Theme.Typography.body).monospacedDigit()
                            .foregroundStyle(Theme.muted)
                        Button("Clear…") { isConfirmingClear = true }
                            .buttonStyle(.secondaryAction)
                            .disabled((samplesSize ?? 0) == 0 || isExampleInUse)
                            .help(clearHelp)
                    }
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.danger)
            }
        }
        .task { await measure() }
        .confirmationDialog("Clear the examples cache?", isPresented: $isConfirmingClear) {
            Button("Clear Cache", role: .destructive) { Task { await clear() } }
        } message: {
            Text("Examples download again when you pick them. Your clips and results stay.")
        }
    }

    private var clearHelp: String {
        if draft.loadingSampleID != nil { return "An example is downloading into the cache; wait for it first" }
        if isExampleInUse { return "A clip uses an example until its prep has copied it; wait or drop it first" }
        if (samplesSize ?? 0) == 0 { return "Nothing to clear" }
        return "Delete the downloaded examples"
    }

    /// The new clip plays an example straight from the cache, an example being picked is downloading into it, and a
    /// queued clip reads it from there until its prep has copied it into the clip's folder.
    private var isExampleInUse: Bool { Self.reads(AppPaths.samples, draft: draft, specs: jobs.jobs.map(\.spec)) }

    /// Some input of the new clip or of `specs` is inside `folder`, by path components, or an example is still
    /// downloading: the files it has so far are in the cache, but not yet in the new clip.
    static func reads(_ folder: URL, draft: Draft, specs: [JobSpec]) -> Bool {
        if draft.loadingSampleID != nil { return true }
        let inputs = [draft.source].compactMap(\.self) + draft.references
            + specs.flatMap { [$0.source] + $0.references + [$0.background].compactMap(\.self) }
        let folder = folder.standardizedFileURL.pathComponents
        return inputs.contains { $0.standardizedFileURL.pathComponents.starts(with: folder) }
    }

    private func text(_ bytes: Int64?) -> String {
        guard let bytes else { return "Measuring…" }
        return bytes == 0 ? "Empty" : bytes.formatted(.byteCount(style: .file))
    }

    private func measure() async {
        let (jobs, samples) = (AppPaths.jobs, AppPaths.samples)
        (resultsSize, samplesSize) = await Task.detached { (AppPaths.size(of: jobs), AppPaths.size(of: samples)) }.value
    }

    private func clear() async {
        // A clip may have been queued while the dialog was up.
        guard !isExampleInUse else {
            failure = "Can't clear the cache: \(clearHelp)."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: AppPaths.samples.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: AppPaths.samples)
            }
            failure = nil
        } catch {
            failure = "Can't clear the cache: \(error.localizedDescription)"
        }
        await measure()
    }

    private func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
