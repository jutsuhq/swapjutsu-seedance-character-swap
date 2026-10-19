import AppKit
import SwiftUI

/// Prep's warnings as a sentence for the person, with prep's own wording kept as the detail: the numbers and file
/// names it gives help someone tuning prep, not someone making a clip.
struct PrepWarning: Equatable {
    let sentence: String
    /// Prep's wording, when the sentence leaves something out.
    let detail: String?

    init(_ text: String) {
        let lookAlike = #/People (\d+) and (\d+) look alike/#
        if let match = text.firstMatch(of: lookAlike) {
            sentence = "People \(match.1) and \(match.2) look alike — check Review."
            detail = text
        } else {
            sentence = text
            detail = nil
        }
    }
}

/// A warning line with a Details disclosure for prep's own wording.
struct PrepWarningLine: View {
    let warning: PrepWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(warning.sentence)
                .font(Theme.Typography.note)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = warning.detail {
                DisclosureGroup("Details") {
                    FullText(text: detail, color: Theme.faint)
                }
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.faint)
            }
        }
    }
}

/// An error or a long line shown whole, selectable, with Copy in its context menu, so a path or a request id in it
/// can be read and pasted.
struct FullText: View {
    let text: String
    let color: Color
    var font = Theme.Typography.note

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
    }
}
