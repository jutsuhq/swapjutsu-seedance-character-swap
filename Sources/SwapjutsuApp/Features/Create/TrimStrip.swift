import SwiftUI

/// Jutsu Studio's trim strip: thumbnails of the whole clip with two handles on the range being edited, the other
/// ranges outlined, the uncovered parts dimmed, and the list of ranges. `Draft` clamps every move to 4–30 s and
/// keeps ranges apart; the handles also move with the arrow keys once focused, and with VoiceOver.
struct TrimStrip: View {
    let source: URL
    /// Called with the time under the handle being dragged, so the player shows that frame.
    let onScrub: (Double) -> Void
    @Environment(Draft.self) private var draft
    @State private var thumbnails: [CGImage] = []
    @State private var dragOrigin: ClipRange?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                SectionLabel(title: "Trim").fixedSize()
                Text(draft.range?.text ?? "")
                    .font(Theme.Typography.strong)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Theme.Spacing.small)
                Text(summary)
                    .font(Theme.Typography.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            GeometryReader { proxy in strip(width: proxy.size.width) }
                .frame(height: 56)
            rangeList
            Text("Drag the handles or the range; ← → nudge a frame. Each range becomes its own clip.")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.large)
        .well(radius: Theme.Radius.field)
        .task(id: source) { thumbnails = await VideoFrames.images(for: source, count: 12) }
    }

    /// "2 ranges · 30.0 s → 2 clips".
    private var summary: String {
        let count = draft.ranges.count
        return "\(count) range\(count == 1 ? "" : "s") · \(draft.rangeSeconds) → \(count) clip\(count == 1 ? "" : "s")"
    }

    private func strip(width: CGFloat) -> some View {
        let total = max(draft.duration ?? 0, 0.001)
        let x = { (time: Double) in width * CGFloat(time / total) }
        let range = draft.range ?? ClipRange(start: 0, end: 0)
        return ZStack(alignment: .leading) {
            frames
            ForEach(draft.uncoveredRanges, id: \.start) { gap in
                Theme.scrim
                    .frame(width: max(0, x(gap.end) - x(gap.start)))
                    .offset(x: x(gap.start))
                    .allowsHitTesting(false)
            }
            ForEach(draft.ranges.indices, id: \.self) { index in
                if index != draft.selectedRange {
                    let other = draft.ranges[index]
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
                        .contentShape(Rectangle())
                        .frame(width: max(0, x(other.end) - x(other.start)))
                        .offset(x: x(other.start))
                        .onTapGesture { select(index) }
                        .pointerCursor()
                }
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: max(0, x(range.end) - x(range.start)))
                .modifier(TrimKeys(part: .selection, onScrub: onScrub))
                .offset(x: x(range.start))
                .gesture(drag(.selection, width: width, total: total))
            handle
                .modifier(TrimKeys(part: .start, onScrub: onScrub))
                .offset(x: x(range.start) - 5)
                .gesture(drag(.start, width: width, total: total))
            handle
                .modifier(TrimKeys(part: .end, onScrub: onScrub))
                .offset(x: x(range.end) - 5)
                .gesture(drag(.end, width: width, total: total))
        }
        .frame(width: width)
    }

    private var frames: some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Color.clear
                    .overlay { Image(decorative: thumbnails[index], scale: 1).resizable().scaledToFill() }
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent)
            .frame(width: 10)
            .overlay { Capsule().fill(Theme.ink).frame(width: 2, height: 16) }
            .pointerCursor()
    }

    /// "+ Add range", and once there are several, one chip per range to edit or remove it.
    private var rangeList: some View {
        HStack(spacing: Theme.Spacing.small) {
            if draft.ranges.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(draft.ranges.indices, id: \.self) { index in
                            RangeChip(
                                text: draft.ranges[index].text, isSelected: index == draft.selectedRange,
                                onSelect: { select(index) }, onRemove: { draft.removeRange(at: index) })
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                draft.addRange()
                if let range = draft.range { onScrub(range.start) }
            } label: {
                Label("Add range", systemImage: "plus").font(Theme.Typography.strongNote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(draft.canAddRange ? Theme.accent : Theme.faint)
            .pointerCursor()
            .disabled(!draft.canAddRange)
            .help(draft.canAddRange ? "Add a 4–30 s range" : "No 4 s gap left in the video for another range")
            .fixedSize()
        }
    }

    private func select(_ index: Int) {
        draft.selectRange(at: index)
        if let range = draft.range { onScrub(range.start) }
    }

    /// Moves relative to where the drag started, so the handle follows the pointer exactly.
    private func drag(_ part: TrimPart, width: CGFloat, total: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let current = draft.range else { return }
                let origin = dragOrigin ?? current
                if dragOrigin == nil { dragOrigin = origin }
                let shift = Double(value.translation.width / max(width, 1)) * total
                switch part {
                case .start: draft.setStart(origin.start + shift)
                case .end: draft.setEnd(origin.end + shift)
                case .selection: draft.moveRange(toStart: origin.start + shift)
                }
                if let range = draft.range { onScrub(part == .end ? range.end : range.start) }
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

enum TrimPart {
    case start, end, selection

    var label: String {
        switch self {
        case .start: "Range start"
        case .end: "Range end"
        case .selection: "Range"
        }
    }
}

/// One range in the list: click to edit it on the strip, × to remove it.
private struct RangeChip: View {
    let text: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(text)
                    .font(Theme.Typography.meta)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.text : Theme.muted)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove range")
            .accessibilityLabel("Remove range \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay { Capsule().strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: 1) }
    }
}

/// Arrow keys and VoiceOver move one part of the trim by a frame (1/24 s), as a drag does.
private struct TrimKeys: ViewModifier {
    let part: TrimPart
    let onScrub: (Double) -> Void
    @Environment(Draft.self) private var draft

    func body(content: Content) -> some View {
        content
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .left: nudge(by: -1)
                case .right: nudge(by: 1)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel(part.label)
            .accessibilityValue(draft.range?.text ?? "")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(by: 1)
                case .decrement: nudge(by: -1)
                @unknown default: break
                }
            }
    }

    private func nudge(by frames: Int) {
        guard let range = draft.range else { return }
        let step = Double(frames) / 24
        switch part {
        case .start: draft.setStart(range.start + step)
        case .end: draft.setEnd(range.end + step)
        case .selection: draft.moveRange(toStart: range.start + step)
        }
        if let range = draft.range { onScrub(part == .end ? range.end : range.start) }
    }
}
