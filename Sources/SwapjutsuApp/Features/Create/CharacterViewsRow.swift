import SwapjutsuPrep
import SwiftUI

/// A person's other views, inside their card: a tile per angle with its image, or a slot to drop or pick one, the
/// views added without an angle and a slot for one more. Each is one of the person's views in `cast` (`JobStore.addView`,
/// `JobStore.addReferences(asView:)`). Seedance keeps a turn or a back view the same character when it has seen
/// that side.
struct CharacterViewsRow: View {
    let job: Job
    /// The replaced person (`Manifest.Identity.id`).
    let person: Int
    @Environment(JobStore.self) private var jobs
    @State private var picking: Slot?
    @State private var failure: String?

    /// Where a picked image goes: a view from `angle`, or with nil one without an angle.
    private struct Slot: Equatable { var angle: CharacterAngle? }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The label goes when the card is too narrow for it beside the tiles.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    label
                    tiles
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) { tiles }
            }
            if !hasViews {
                Text("Optional: a back or side view keeps them the same when they turn.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(
            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result, let slot = picking else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            add([url], slot.angle)
        }
        .alert("Can't use this", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private var label: some View {
        Text("Angles")
            .font(Theme.Typography.meta)
            .foregroundStyle(Theme.faint)
            .frame(width: 48, alignment: .leading)
            .help("Other views of the same character. Optional; Seedance keeps the back and the profile the same when it has seen them.")
    }

    @ViewBuilder private var tiles: some View {
        ForEach(CharacterAngle.allCases, id: \.self) { angle in
            ViewTile(
                title: angle.title, view: view(angle).map { job.spec.references[$0] },
                number: view(angle).flatMap(job.layout.number(of:)),
                onPick: { picking = Slot(angle: angle) }, onDrop: { add($0, angle) },
                onRemove: { view(angle).map { jobs.removeReference(at: $0, of: job) } })
        }
        ForEach(others, id: \.self) { index in
            ViewTile(
                title: "View", view: job.spec.references[index], number: job.layout.number(of: index),
                onPick: { picking = Slot() }, onDrop: { add($0, nil) },
                onRemove: { jobs.removeReference(at: index, of: job) })
        }
        ViewTile(
            title: "Other", view: nil, number: nil, onPick: { picking = Slot() },
            onDrop: { add($0, nil) }, onRemove: {})
    }

    private var views: ArraySlice<Int> { job.cast.first { $0.person == person }?.views ?? [] }

    private var hasViews: Bool { !views.isEmpty }

    /// The `references` index of the person's view from `angle`.
    private func view(_ angle: CharacterAngle) -> Int? { views.first { job.spec.angle(of: $0) == angle } }

    /// The person's views without an angle.
    private var others: [Int] { views.filter { job.spec.angle(of: $0) == nil } }

    private func add(_ urls: [URL], _ angle: CharacterAngle?) {
        guard let image = urls.first(where: \.isImageFile) else {
            failure = urls.first.map { "\($0.lastPathComponent) is not an image." }
            return
        }
        failure =
            angle.map { jobs.addView(image, angle: $0, person: person, to: job) }
            ?? jobs.addReferences([image], to: job, person: person, asView: true)
    }
}

/// One view: its image with its number and title, a remove button (brighter on hover), draggable to another person or the
/// extras; empty, a slot with the title to click or drop onto.
private struct ViewTile: View {
    let title: String
    let view: URL?
    let number: Int?
    let onPick: () -> Void
    let onDrop: ([URL]) -> Void
    let onRemove: () -> Void
    @State private var isTargeted = false
    @State private var isHovered = false

    var body: some View {
        Button(action: onPick) {
            Group {
                if let view {
                    Thumbnail(url: view)
                } else {
                    Theme.well.overlay {
                        Text(title).font(Theme.Typography.meta).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(
                        isTargeted ? Theme.accent : Theme.stroke,
                        style: StrokeStyle(lineWidth: 1, dash: view == nil ? [3, 2] : []))
            }
            .overlay(alignment: .bottom) {
                // A strip across the tile: a tag's capsule would cut "Side" and "Back" short at this size.
                if view != nil {
                    Text(number.map { "\(title) · \($0)" } ?? title)
                        .font(.system(size: 8, weight: .heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 1)
                        .background(Theme.scrim)
                        .foregroundStyle(Theme.text)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .overlay(alignment: .topTrailing) {
            if view != nil {
                Button("Remove View", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Theme.scrim, in: Circle())
                    .opacity(isHovered ? 1 : 0.7)
                    .buttonStyle(.plain)
                    .padding(1)
                    .help("Remove this view")
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            if view != nil { Button("Remove", role: .destructive, action: onRemove) }
        }
        .help(help)
        .modifier(Draggable(url: view))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return true
        } isTargeted: {
            isTargeted = $0
        }
    }

    private var help: String {
        guard view != nil else {
            return title == "Other" ? "Add another view: click or drop" : "Add a \(title.lowercased()) view: click or drop"
        }
        return "@Image\(number ?? 0) · drag it to another person or the extras"
    }
}

private struct Draggable: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url) { Thumbnail(url: url).frame(width: 40, height: 40) }
        } else {
            content
        }
    }
}
