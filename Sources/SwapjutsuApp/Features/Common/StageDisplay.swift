import SwiftUI

/// How prep and render stages read in Create, Jobs and Library; the model keeps only what a stage means.
extension Job.Stage {
    var title: String {
        switch self {
        case .waiting: "Waiting for prep"
        case .preparing: "Preparing on Mac"
        case .prepared: "Ready"
        case .failed: "Prep failed"
        case .canceled: "Prep canceled"
        }
    }

    var color: Color {
        switch self {
        case .prepared: Theme.accent
        case .failed: Theme.danger
        case .waiting, .canceled: Theme.faint
        case .preparing: Theme.info
        }
    }
}

extension Render.Stage {
    var title: String {
        switch self {
        case .waiting: "Waiting for you"
        case .uploading: "Uploading"
        case .generating: "Seedance rendering"
        case .downloading: "Downloading"
        case .exporting: "Adding the soundtrack"
        case .done: "Done"
        case .failed: "Failed"
        case .canceled: "Canceled"
        case .unknown: "Check Comfy"
        }
    }

    var color: Color {
        switch self {
        case .done: Theme.accent
        case .failed: Theme.danger
        case .unknown, .waiting: Theme.warning
        case .canceled: Theme.faint
        case .uploading, .generating, .downloading, .exporting: Theme.info
        }
    }
}

extension Job {
    /// The render's stage, named after its generator: "Seedance rendering", "Wan rendering".
    func stageTitle(of render: Render) -> String {
        let model = model(of: render)
        switch render.stage {
        case .generating: return model == .seedance25 ? "Seedance rendering" : "Wan rendering"
        case .unknown: return model == .wan22Animate ? "Check your ComfyUI" : "Check Comfy"
        default: return render.stage.title
        }
    }
}

extension Render {
    /// What the stopped render's main button does: a request that exists resumes for free, anything else submits
    /// again (and pays again).
    var retryTitle: String {
        if providerJobID != nil { return "Resume" }
        if stage == .waiting { return "Send" }
        return stage == .unknown ? "Render Anyway" : "Try Again"
    }

}

extension Job {
    /// The Cancel button's help: the direct route can't cancel a started Seedance task.
    func cancelHelp(of render: Render) -> String {
        guard render.stage == .generating else { return "Cancel" }
        if model(of: render) == .wan22Animate { return "Stop the render on your ComfyUI" }
        if let id = render.providerJobID, PartnerSeedance.owns(id) {
            return "Stop waiting; Seedance can't cancel a started task, so it may still finish and be charged"
        }
        if model(of: render) == .wan30 {
            return "Stop waiting; Wan can't cancel a started task, so it may still finish and be charged"
        }
        return "Stop waiting and cancel the render on Comfy"
    }

    func retryHelp(of render: Render) -> String {
        if model(of: render) == .wan22Animate {
            if render.providerJobID != nil { return "Pick the same request up again on your ComfyUI" }
            return render.stage == .unknown
                ? "Submit a new render; check your ComfyUI's queue first, the first one may be running"
                : "Send it to your ComfyUI; it costs nothing"
        }
        if render.providerJobID != nil { return "Pick the same request up again; no new credits" }
        if render.stage == .waiting {
            return "Send it to \(model(of: render).title) now, paid from your Comfy credits"
        }
        return render.stage == .unknown
            ? "Submit a new render; check your Comfy history first, the first one may be running" : "Submit it again"
    }

    /// Dismiss's help: why a render whose request may still run stays listed.
    func dismissHelp(of render: Render) -> String {
        guard !render.canDismiss else { return "Take it off the list" }
        let place = model(of: render) == .wan22Animate ? "your ComfyUI" : "Comfy"
        return "Its request may still be running on \(place) and be charged; Resume to follow it until it ends"
    }

    /// A stopped render's main button; a render waiting for the person shows the price it would send at.
    func retryTitle(of render: Render) -> String {
        guard render.stage == .waiting, let seconds = duration else { return render.retryTitle }
        return "Send · \(model(of: render).priceText(seconds: seconds, quality: render.quality))"
    }
}

extension Date {
    /// "2 hr. ago", "yesterday".
    var shortStamp: String { formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
}
