import SwiftUI

/// The new clip's video, playing with sound and controls, with the trim strip under it.
struct SourceStage: View {
    let source: URL
    @Environment(Draft.self) private var draft
    @State private var scrub: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            PlayerView(url: source, seek: scrub)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
            if draft.duration != nil, !draft.ranges.isEmpty {
                TrimStrip(source: source) { scrub = $0 }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
