import SwiftUI

/// Create: the whole way from a video to a result on one page. Clips on the left, a new one first; on the right the
/// new clip (video, trim, prep options) or a clip's steps: prep, characters, prompt, then a draft or a final with
/// the price.
struct CreateView: View {
    @Environment(Draft.self) private var draft
    @Environment(Navigation.self) private var navigation
    @Environment(JobStore.self) private var jobs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: "Create",
                subtitle:
                    "Prepare a clip for free on this Mac, check it, add your characters, then render a draft or the final."
            )
            HStack(alignment: .top, spacing: Theme.Spacing.large) {
                ClipRail(selection: selection)
                    .frame(width: 240)
                if let job = jobs.job(navigation.clip) {
                    ClipWorkspace(job: job)
                        .id(job.id)
                } else {
                    NewClipWorkspace(onSubmit: submit)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .pagePadding()
        // Choose Video… in the gallery, Replace Video and File › Choose Video… (⌘O) all open this one picker.
        .fileImporter(isPresented: choosingVideo, allowedContentTypes: [.movie]) { result in
            // A sandboxed picker hands out a security-scoped URL; its access is kept until quit, as an open panel's
            // is, since prep copies the file in later.
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource()
            draft.setSource(url)
        }
        .alert("Can't use this", isPresented: failureShown) {
            Button("OK") { draft.failure = nil }
        } message: {
            Text(draft.failure ?? "")
        }
    }

    /// The clip Navigation points at; `nil` is the new clip.
    private var selection: Binding<UUID?> {
        Binding {
            jobs.job(navigation.clip)?.id
        } set: {
            navigation.open($0)
        }
    }

    /// One clip per range; the first opens, showing its prep. The new clip starts over.
    private func submit() {
        let queued = draft.specs.map { jobs.enqueue($0) }
        draft.clear()
        navigation.open(queued.first?.id)
    }

    private var choosingVideo: Binding<Bool> {
        Binding(get: { navigation.isChoosingVideo }, set: { navigation.isChoosingVideo = $0 })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { draft.failure != nil }, set: { if !$0 { draft.failure = nil } })
    }
}
