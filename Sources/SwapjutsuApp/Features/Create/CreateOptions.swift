import SwiftUI

/// Prep's options, who gets replaced, the lip-sync guide and the background, as compact rows in one well.
struct CreateOptions: View {
    @Binding var target: Draft.Target
    @Binding var faceGuide: Bool
    @Binding var replaceBackground: Bool
    /// The people a prepared clip found; with them, who is replaced can also be picked person by person.
    var people: PeoplePick?

    var body: some View {
        VStack(spacing: 0) {
            row("Replace") {
                if let people {
                    SegmentedControl(selection: people.preset, options: Self.presets, isCompact: true)
                        .frame(width: 150)
                } else {
                    SegmentedControl(selection: $target, options: [(.main, "Main"), (.all, "Everyone")], isCompact: true)
                        .frame(width: 150)
                }
            }
            if let people {
                PeopleRow(people: people)
            }
            Divider().overlay(Theme.stroke)
            row("Lip-sync guide") {
                Toggle("Lip-sync guide", isOn: $faceGuide).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .help("Draw face landmarks over the depth, to guide the lips")
            Divider().overlay(Theme.stroke)
            row("Replace background") {
                Toggle("Replace background", isOn: $replaceBackground)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .help("Paint everything but the replaced people with grey depth, for a new place from an image")
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .well()
    }

    private static let presets: [(value: Draft.Target?, title: String)] = [(.main, "Main"), (.all, "Everyone")]

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title).font(Theme.Typography.label).foregroundStyle(Theme.text)
            Spacer(minLength: Theme.Spacing.small)
            control()
        }
        .frame(height: 40)
    }
}

/// The people prep found, by their face crops (`identities/<id>.jpg`), and who of them is replaced.
struct PeoplePick {
    struct Person: Identifiable {
        let id: Int
        let face: URL?
    }

    let found: [Person]
    @Binding var choice: ReplaceChoice

    private var ids: [Int] { found.map(\.id) }

    /// Main or Everyone, or neither when people were picked one by one.
    var preset: Binding<Draft.Target?> {
        Binding(get: { choice.preset }, set: { if let target = $0 { choice = .preset(target) } })
    }

    func isReplaced(_ id: Int) -> Bool { choice.ids(of: ids).contains(id) }

    func toggle(_ id: Int) { choice = choice.toggling(id, of: ids) }
}

/// One tile per person found: the face with its number, lit when the person is replaced.
private struct PeopleRow: View {
    let people: PeoplePick

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(people.found) { person in
                    let isReplaced = people.isReplaced(person.id)
                    Button {
                        people.toggle(person.id)
                    } label: {
                        Thumbnail(url: person.face)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                            .opacity(isReplaced ? 1 : 0.45)
                            .overlay(alignment: .bottomLeading) { MediaTag(text: "\(person.id)").padding(2) }
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                    .strokeBorder(isReplaced ? Theme.accent : Theme.stroke, lineWidth: isReplaced ? 2 : 1)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isReplaced ? "Person \(person.id) is replaced; click to keep them" : "Replace person \(person.id)")
                    .accessibilityLabel("Person \(person.id)")
                    .accessibilityAddTraits(isReplaced ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.bottom, Theme.Spacing.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
