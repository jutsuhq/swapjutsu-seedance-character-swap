import SwiftUI

/// The optional prompt, with a placeholder that explains what an empty one means.
struct PromptEditor: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(Theme.Typography.body)
            .scrollContentBackground(.hidden)
            .focused($isFocused)
            .padding(8)
            .frame(height: 96)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Empty: prep writes one for the people it finds (@Video1, @Image1…).")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent : Theme.stroke, lineWidth: isFocused ? 1.5 : 1)
            }
    }
}
