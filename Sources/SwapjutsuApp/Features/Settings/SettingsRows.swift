import SwiftUI

/// Jutsu Studio's settings card: a title, a card of rows, an optional note under it.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let title { SectionLabel(title: title) }
            VStack(spacing: 0) { content() }
                .padding(.horizontal, Theme.Spacing.large)
                .card(radius: 14)
            if let footer {
                Text(footer)
                    .font(Theme.Typography.note)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.xSmall)
            }
        }
    }
}

/// A label, and a detail under it, on the left; the control or value on the right; a hairline above unless first.
struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    var isFirst = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.Typography.label).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(detail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 50)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(Theme.stroke).frame(height: 1) }
        }
    }
}

extension SettingsRow where Control == Text {
    /// A read-only value.
    init(label: String, value: String, isFirst: Bool = false) {
        self.init(label: label, isFirst: isFirst) {
            Text(value).font(Theme.Typography.body).monospacedDigit().foregroundStyle(Theme.muted)
        }
    }
}

extension View {
    /// A switch the size of Jutsu Studio's settings toggles, without its own label.
    func settingsSwitch() -> some View {
        toggleStyle(.switch).controlSize(.small).labelsHidden()
    }
}
