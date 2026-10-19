import AVFoundation
import SwiftUI

/// The big uppercase title and a muted line under it.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(title)
                    .font(.display(40))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.text)
                Text(subtitle ?? " ")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, Theme.Spacing.xLarge)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A small uppercase caption above a group, with an optional detail on the right.
struct SectionLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.8)
                .textCase(.uppercase)
            Spacer(minLength: Theme.Spacing.small)
            if let detail {
                Text(detail)
                    .font(Theme.Typography.strongMeta)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.faint)
    }
}

/// A status capsule with an optional colored dot.
struct Pill: View {
    let text: String
    var dot: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(text).monospacedDigit().lineLimit(1)
        }
        .font(Theme.Typography.strongMeta)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.glass, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.glassStroke, lineWidth: 0.5) }
    }
}

/// "Claude Code · 17 Oct, 14:02" after a terminal glyph: a clip or render an agent started, small next to its title.
/// A render adds the most the agent let it cost.
struct OriginTag: View {
    let label: String
    let help: String

    init(origin: JobOrigin) {
        label = origin.label
        help = "Started by \(origin.client) through swapjutsu, request \(origin.requestID)"
    }

    init(origin: RenderOrigin) {
        label = origin.label
        help =
            "Asked for by \(origin.client) through swapjutsu, request \(origin.requestID), allowed to cost up to "
            + SeedancePrice.dollars(origin.maxCost)
    }

    var body: some View {
        Label(label, systemImage: "terminal")
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .fixedSize()
            .help(help)
    }
}

/// A tag drawn on a video frame, e.g. the mode or the duration.
struct MediaTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Theme.scrim, in: Capsule())
    }
}

/// One sidebar destination: muted until active, then a light fill and a yellow icon.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var badge = 0
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                    .frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .font(Theme.Typography.label)
            .foregroundStyle(isSelected || isHovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                isSelected ? Theme.selection : (isHovered ? Theme.card : .clear),
                in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The app icon and name at the top of the sidebar.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text("Swapjutsu")
                .font(.display(19))
                .kerning(0.3)
                .textCase(.uppercase)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Capsule tabs with a sliding yellow pill.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    /// Smaller type and height, for a control inside a row.
    var isCompact = false
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: isCompact ? 11.5 : 12.5, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, isCompact ? 8 : 10)
                        .frame(maxWidth: .infinity, minHeight: isCompact ? 22 : 28)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(isCompact ? 2 : 3)
        .background(Theme.well, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.stroke, lineWidth: 1) }
    }
}

/// An icon, a title and a line of help in a well: empty pages and drop zones.
struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    /// The way out of the empty page, when there is one.
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.glass, in: Circle())
            Text(title)
                .font(Theme.Typography.strong)
                .foregroundStyle(Theme.text)
            Text(message)
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.faint)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.primaryAction)
                    .padding(.top, Theme.Spacing.small)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .well(radius: Theme.Radius.card)
    }
}

/// A remote or local picture filling its frame.
struct Thumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Theme.well
            }
        }
    }
}

/// A muted video that loops while shown, filling its frame. It never takes the mouse, so the tile under it keeps
/// its clicks and hover.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> PassiveVideoView {
        let view = PassiveVideoView()
        view.playerLayer.videoGravity = gravity
        context.coordinator.play(url, in: view)
        return view
    }

    func updateNSView(_ view: PassiveVideoView, context: Context) {
        view.playerLayer.videoGravity = gravity
        context.coordinator.play(url, in: view)
    }

    static func dismantleNSView(_ view: PassiveVideoView, coordinator: Coordinator) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
        coordinator.looper = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var looper: AVPlayerLooper?
        private var url: URL?

        func play(_ url: URL, in view: PassiveVideoView) {
            guard url != self.url else { return }
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            view.playerLayer.player = player
            player.play()
        }
    }

    final class PassiveVideoView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
