import SwiftUI

/// The yellow call to action: one per screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButton(configuration: configuration)
    }
}

/// Everything else clickable. A destructive role turns the label red.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButton(configuration: configuration)
    }
}

/// A round glass button holding one symbol.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primaryAction: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondaryAction: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var iconAction: IconButtonStyle { IconButtonStyle() }
}

/// Yellow with a glow; brightens on hover. Disabled it drops to a flat glass capsule with faint text.
private struct PrimaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .heavy))
            .lineLimit(1)
            .foregroundStyle(isEnabled ? Theme.ink : Theme.faint)
            .padding(.horizontal, 18)
            .frame(minHeight: 42)
            .background {
                Capsule()
                    .fill(isEnabled ? Theme.accent : Theme.glass)
                    .brightness(isEnabled && isHovered && !configuration.isPressed ? 0.05 : 0)
            }
            .overlay { if !isEnabled { Capsule().strokeBorder(Theme.stroke, lineWidth: 1) } }
            .shadow(color: isEnabled ? Theme.accentGlow : .clear, radius: isHovered ? 18 : 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
            .pointerCursor()
            .onHover { isHovered = $0 }
            .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct SecondaryButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(Theme.Typography.strong)
            .lineLimit(1)
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(isHovered && isEnabled ? Theme.glassStroke : Theme.stroke, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .pointerCursor()
            .onHover { isHovered = $0 }
            .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var fill: Color {
        guard isEnabled else { return Theme.well }
        if configuration.isPressed { return Theme.glassPressed }
        return isHovered ? Theme.glassHover : Theme.glass
    }
}

private struct IconButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(Theme.Typography.strongNote)
            .foregroundStyle(configuration.role == .destructive ? Theme.danger : Theme.text)
            .frame(width: 30, height: 30)
            .background(isHovered && isEnabled ? Theme.glassHover : Theme.glass, in: Circle())
            .overlay { Circle().strokeBorder(Theme.stroke, lineWidth: 1) }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
            .pointerCursor()
            .onHover { isHovered = $0 }
    }
}

/// A raised surface: panels, job rows.
struct CardModifier: ViewModifier {
    var radius = Theme.Radius.card
    var isHighlighted = false

    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isHighlighted ? Theme.accent : Theme.stroke, lineWidth: isHighlighted ? 2 : 1)
            }
    }
}

/// An inset area: drop zones, empty states.
struct WellModifier: ViewModifier {
    var radius = Theme.Radius.field

    func body(content: Content) -> some View {
        content
            .background(Theme.well, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func card(radius: CGFloat = Theme.Radius.card, isHighlighted: Bool = false) -> some View {
        modifier(CardModifier(radius: radius, isHighlighted: isHighlighted))
    }

    func well(radius: CGFloat = Theme.Radius.field) -> some View {
        modifier(WellModifier(radius: radius))
    }

    /// Page padding: `page` on the sides and bottom, `pageTop` above the header.
    func pagePadding() -> some View {
        padding(.horizontal, Theme.Spacing.page)
            .padding(.top, Theme.Spacing.pageTop)
            .padding(.bottom, Theme.Spacing.page)
    }

    /// The pointing hand over anything clickable while it is enabled.
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }

    /// A text field drawn as a well with a yellow border while focused.
    func themedField(isFocused: Bool) -> some View {
        textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: 38)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent : Theme.stroke, lineWidth: isFocused ? 1.5 : 1)
            }
            .focusEffectDisabled()
    }

    /// `.animation(_:value:)` that changes without animating while Reduce Motion is on.
    func motionAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

private struct PointerCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : nil)
    }
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
