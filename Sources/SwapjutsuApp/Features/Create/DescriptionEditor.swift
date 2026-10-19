import SwapjutsuPrep
import SwiftUI

/// What the prompt writer said each character, the place and the moves are, as editable fields: it fills the
/// entity, appearance and beat parts of the prompt, and the wishes above win over it. With several performers each
/// has their own moves and gaze. An edit marks it "Edited".
struct DescriptionEditor: View {
    let job: Job
    @Environment(JobStore.self) private var jobs

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Text(summary).font(Theme.Typography.note).foregroundStyle(Theme.muted)
                Spacer()
                if job.isDescribing {
                    ProgressView().controlSize(.small)
                } else if jobs.describer() != nil {
                    Button(job.spec.description?.isDescribed == true ? "Describe again" : "Describe") {
                        jobs.describe(job)
                    }
                    .buttonStyle(.secondaryAction)
                }
                if job.spec.description != nil, !job.isDescribing {
                    Button("Clear") { jobs.setDescription(nil, of: job) }.buttonStyle(.secondaryAction)
                }
            }
            if let description = job.spec.description {
                ForEach(description.characters.indices, id: \.self) { index in
                    group("Character \(index + 1)") {
                        field("Noun", \.characters[index].noun)
                        field("Looks", \.characters[index].appearance)
                        field("Wears", \.characters[index].wardrobe)
                        field("Traits", \.characters[index].traits)
                        field("Moves with it", \.characters[index].moving)
                    }
                }
                if description.location != nil {
                    group("Place") {
                        field("Noun", \.location!.noun)
                        field("Looks", \.location!.description)
                        field("Floor", \.location!.floor)
                        field("Light", \.location!.light)
                    }
                }
                if let motion = description.motion {
                    group("Moves") {
                        field("Camera", \.motion!.camera)
                        // With several performers, each one's own moves and gaze go to the prompt, not these.
                        if motion.performers.isEmpty {
                            field("Beats", \.motion!.beats)
                            field("Gaze", \.motion!.gaze)
                        }
                        field("Shot", \.motion!.shot)
                        field("Stays", \.motion!.scene)
                        field("Uses", \.motion!.props)
                        field("Text", \.motion!.text)
                    }
                    ForEach(motion.performers.indices, id: \.self) { index in
                        group("Performer \(index + 1)") {
                            field("Beats", \.motion!.performers[index].beats)
                            field("Gaze", \.motion!.performers[index].gaze)
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        if job.isDescribing { return "Describing…" }
        guard let description = job.spec.description else {
            return jobs.describer() == nil ? "Prompt writer off in Settings › Prompt" : "Not described yet"
        }
        return "By \(description.source)"
    }

    private func group(_ title: String, @ViewBuilder fields: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Typography.meta).foregroundStyle(Theme.faint)
            fields()
        }
    }

    private func field(_ label: String, _ path: WritableKeyPath<SceneDescription, String>) -> some View {
        DescriptionField(
            label: label,
            text: Binding(
                get: { job.spec.description?[keyPath: path] ?? "" },
                set: { value in
                    guard var description = job.spec.description, description[keyPath: path] != value else { return }
                    description[keyPath: path] = value
                    description.source = "Edited"
                    jobs.setDescription(description, of: job)
                }))
    }
}

private struct DescriptionField: View {
    let label: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(label).font(Theme.Typography.note).foregroundStyle(Theme.muted).frame(width: 84, alignment: .leading)
            TextField(label, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($isFocused)
                .themedField(isFocused: isFocused)
        }
    }
}
