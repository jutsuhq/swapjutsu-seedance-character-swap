import SwiftUI

/// A dashed drop target with an icon, a title and a line of help.
struct DropTile: View {
    let systemImage: String
    let title: String
    let message: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.glass, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Typography.strong).foregroundStyle(Theme.text)
                    Text(message).font(Theme.Typography.meta).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.medium)
            .background(isHovered ? Theme.card : Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field)
                    .strokeBorder(
                        isHovered ? Theme.accent : Theme.glassStroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
    }
}

extension View {
    /// Files dropped here go to the draft, which sorts videos from images, so every Create control drops the same.
    func acceptsMedia(into draft: Draft) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            draft.add(urls)
            return true
        }
    }
}
