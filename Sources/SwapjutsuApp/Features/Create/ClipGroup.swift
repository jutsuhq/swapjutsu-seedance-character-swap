import Foundation

/// The rail's sections, in the order the person deals with them: what can be rendered, what still needs its
/// images, drafts to judge, what's on its way, what stopped, what's done.
enum ClipGroup: Int, CaseIterable, Identifiable {
    case ready, needsCharacters, drafts, rendering, preparing, stopped, finished

    var id: Self { self }

    var title: String {
        switch self {
        case .ready: "Ready to render"
        case .needsCharacters: "Needs characters"
        case .drafts: "Drafts to finalize"
        case .rendering: "Rendering"
        case .preparing: "Preparing"
        case .stopped: "Stopped"
        case .finished: "Finished"
        }
    }

    @MainActor
    static func of(_ job: Job) -> ClipGroup {
        if job.stage.isActive { return .preparing }
        if job.stage != .prepared { return .stopped }
        if job.isRendering { return .rendering }
        if job.renders.isEmpty { return job.isReady ? .ready : .needsCharacters }
        if job.renders.last?.stage.isStopped == true { return .stopped }
        if job.renders.contains(where: { $0.canFinalize() && job.final(of: $0) == nil }),
            !job.renders.contains(where: { !$0.quality.isDraft && $0.stage == .done })
        {
            return .drafts
        }
        return .finished
    }

    /// Non-empty groups with their clips, newest first inside each.
    @MainActor
    static func ordered(_ jobs: [Job]) -> [(group: ClipGroup, jobs: [Job])] {
        let grouped = Dictionary(grouping: jobs, by: of)
        return allCases.compactMap { group in grouped[group].map { (group, $0) } }
    }
}
