import SwiftUI

enum StepState { case done, now, later }

/// One step of making a clip, numbered in the order the person goes through them: a ring that fills once the step is
/// done, the title, a detail on the right, and the step's controls under it.
struct Step<Content: View>: View {
    let number: Int
    let title: String
    var detail: String?
    var state = StepState.now
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                ZStack {
                    Circle()
                        .strokeBorder(state == .later ? Theme.stroke : Theme.accent, lineWidth: 1.5)
                        .background(Circle().fill(state == .done ? Theme.accent : .clear))
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(state == .later ? Theme.faint : Theme.accent)
                    }
                }
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
                SectionLabel(title: title, detail: detail)
            }
            content
                .opacity(state == .later ? 0.55 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title)")
    }
}

/// The player beside a column of steps while both keep a useful size (a 320 pt player and a 330 pt column, from a
/// 1280 pt window with the sidebar shown); stacked in a narrower window, as Library's result page does.
struct StageAndSide<Stage: View, Side: View>: View {
    /// The stage's video, width over height, when it is known: the side takes what the video leaves at full height.
    var aspect: CGFloat?
    @ViewBuilder let stage: Stage
    @ViewBuilder let side: Side

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.twoColumns {
                HStack(alignment: .top, spacing: Theme.Spacing.large) {
                    stage
                    ScrollViewReader { reader in
                        ScrollView { side.padding(.bottom, Theme.Spacing.large) }
                            .environment(\.revealInSide, Self.reveal(reader))
                    }
                    .frame(width: sideWidth(proxy.size))
                }
            } else {
                // The stage keeps to about half the height, so the first steps show without scrolling.
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                            stage.frame(maxHeight: max(320, proxy.size.height * 0.55))
                            side.environment(\.revealInSide, Self.reveal(reader))
                        }
                    }
                }
            }
        }
    }

    static var twoColumns: CGFloat { 660 }

    /// 330 pt beside a wide video; beside a tall one, the room the video doesn't use at the stage's height (less its
    /// tabs and caption), up to a column that still reads well.
    private func sideWidth(_ size: CGSize) -> CGFloat {
        guard let aspect else { return 330 }
        let stage = max(320, (size.height - 110) * aspect)
        return min(760, max(330, size.width - Theme.Spacing.large - stage))
    }

    private static func reveal(_ reader: ScrollViewProxy) -> (AnyHashable) -> Void {
        { id in withAnimation { reader.scrollTo(id, anchor: .top) } }
    }
}

extension EnvironmentValues {
    /// Scrolls the column of steps to the view with this id, so a panel that opens below the fold shows.
    @Entry var revealInSide: (AnyHashable) -> Void = { _ in }
}
