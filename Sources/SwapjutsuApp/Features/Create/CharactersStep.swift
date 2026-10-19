import SwapjutsuPrep
import SwiftUI
import UniformTypeIdentifiers

/// The clip's characters: for every person prep replaces, the image that replaces them (any of the clip's images)
/// and more views of the same character, with a slot per angle to add or draw one (`CharacterViewsRow`); with the
/// background replaced, the image of the new place; then the images that replace no one, and the cutout toggle.
/// Numbers are the render's (`Job.layout`); face close-ups the upload adds (`JobFiles.faceCloseUp(of:)`) come
/// after them. Images move between people, views and extras by drag (`JobStore.assign`); a file dropped from
/// Finder is added where it lands. Before prep is done they are a plain list, given to the people in order.
struct CharactersStep: View {
    let job: Job
    @Environment(JobStore.self) private var jobs
    @State private var pickFor: Pick?
    @State private var isPicking = false
    @State private var failure: String?
    /// `ReferenceFit` warnings by person, measured off the main actor.
    @State private var fits: [Int: String] = [:]
    /// Characters whose face close-up goes along.
    @State private var closeUps: Set<URL> = []

    /// Where picked images go: to `person`, with nil to the extras, or with `background` to the new place. Views
    /// are added on the person's angles row (`CharacterViewsRow`).
    private struct Pick {
        var person: Int?
        var background = false
    }

    private var references: [URL] { job.spec.references }
    private var targets: [Int] { job.manifest?.targets ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let manifest = job.manifest {
                VStack(spacing: 6) {
                    ForEach(job.cast, id: \.person) { binding in
                        PersonRow(
                            face: manifest.identities.first { $0.id == binding.person }?.thumbnail.map {
                                job.output.appending(path: $0)
                            },
                            person: "Person \(binding.person)",
                            character: binding.character.map { picture($0) }, views: binding.views.count,
                            closeUp: binding.character.map { closeUps.contains(references[$0]) } ?? false,
                            warning: fits[binding.person],
                            onPick: { pick(Pick(person: binding.person)) },
                            onDrop: { add($0, to: Pick(person: binding.person)) },
                            onRemove: remove
                        ) {
                            if binding.character != nil { CharacterViewsRow(job: job, person: binding.person) }
                        }
                    }
                    if job.replacesBackground {
                        // A row of its own rather than one of the extras: the prompt names its exact number.
                        PersonRow(
                            face: nil, placeholder: "photo", person: "New place",
                            character: job.spec.background.map { (number: job.layout.background ?? 0, url: $0) },
                            hint: "Click or drop the place that replaces the grey", warning: nil,
                            onPick: { pick(Pick(background: true)) }, onDrop: setBackground,
                            onRemove: { _ in jobs.removeBackground(of: job) }
                        ) {}
                    }
                }
                if manifest.replaceable.count > targets.count {
                    Text(kept(manifest))
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extras(job.spec.extras(for: targets), titled: true)
            } else {
                extras(Array(references.indices), titled: false)
                Text("Prep shows who each image goes to once it's done.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.faint)
            }
            removeBackground
        }
        .task(id: FitKey(cast: job.cast, references: references)) { await measureFits() }
        .task(id: job.cast.compactMap(\.character)) {
            let characters = job.cast.compactMap(\.character).map { references[$0] }
            closeUps = await Task.detached { Set(characters.filter { JobFiles.faceCloseUp(of: $0) != nil }) }.value
        }
        .fileImporter(
            isPresented: $isPicking, allowedContentTypes: [.image],
            allowsMultipleSelection: pickFor?.person == nil && pickFor?.background != true
        ) { result in
            guard case .success(let urls) = result else { return }
            // A sandboxed picker hands out security-scoped URLs, reachable while the images are copied into the job.
            let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
            if pickFor?.background == true { setBackground(urls) } else { add(urls, to: pickFor ?? Pick()) }
        }
        .alert("Can't use this", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    /// The images at `indices`, numbered as in the prompt, and a tile to add more. Once prep is done, an image
    /// dragged here from a person replaces no one.
    private func extras(_ indices: [Int], titled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if titled {
                Text("Extra images").font(Theme.Typography.strongMeta).foregroundStyle(Theme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 6, alignment: .leading)], spacing: 6) {
                ForEach(indices, id: \.self) { index in
                    CharacterTile(url: references[index], number: job.layout.number(of: index) ?? index + 1) {
                        jobs.removeReference(at: index, of: job)
                    }
                }
                if references.count < Draft.maxReferences { AddTile { pick(Pick()) } }
            }
            .dropDestination(for: URL.self) { urls, _ in
                add(urls, to: Pick())
                return true
            }
            if titled {
                Text(
                    "Optional: a prop, an outfit, a detail. They replace no one, so name them in the prompt by their "
                        + "number, like @Image\(job.layout.extras.first ?? job.layout.count + 1). Drag any image "
                        + "between people, angles and here.")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var removeBackground: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cut out characters").font(Theme.Typography.label).foregroundStyle(Theme.text)
                Text("Each goes to Seedance on plain grey, so its own background stays out of the video")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: Theme.Spacing.small)
            Toggle(
                "Cut out characters",
                isOn: Binding(get: { job.spec.removeBackground }, set: { jobs.setRemoveBackground($0, of: job) })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .well()
    }

    /// "Kept as they are: Person 3, Person 4. …".
    private func kept(_ manifest: Manifest) -> String {
        let kept = manifest.replaceable.filter { !targets.contains($0.id) }
        return "Kept as they are: " + kept.map { "Person \($0.id)" }.joined(separator: ", ")
            + ". Pick them in Prep › Prepare Again to replace them too."
    }

    private func pick(_ target: Pick) {
        pickFor = target
        isPicking = true
    }

    /// `references[index]` with its number in the render.
    private func picture(_ index: Int) -> PersonRow.Picture {
        (number: job.layout.number(of: index) ?? index + 1, url: references[index])
    }

    private func remove(_ url: URL) {
        if let index = references.firstIndex(of: url) { jobs.removeReference(at: index, of: job) }
    }

    private func setBackground(_ urls: [URL]) {
        guard let image = urls.first(where: \.isImageFile) else {
            failure = urls.first.map { "\($0.lastPathComponent) is not an image." }
            return
        }
        failure = jobs.setBackground(image, of: job)
    }

    private func add(_ urls: [URL], to target: Pick) {
        let images = urls.filter(\.isImageFile)
        guard !images.isEmpty else {
            failure = urls.first.map { "\($0.lastPathComponent) is not an image." }
            return
        }
        failure = jobs.addReferences(
            target.person == nil ? images : Array(images.prefix(1)), to: job, person: target.person)
    }

    /// What the fit warnings depend on.
    private struct FitKey: Equatable {
        var cast: [CharacterBinding]
        var references: [URL]
    }

    private func measureFits() async {
        let (cast, references) = (job.cast, references)
        let thumbnails = (job.manifest?.identities ?? []).reduce(into: [Int: URL]()) { result, identity in
            if let thumbnail = identity.thumbnail { result[identity.id] = job.output.appending(path: thumbnail) }
        }
        fits = await Task.detached {
            Job.fitWarnings(cast: cast, references: references, thumbnails: thumbnails)
        }.value
    }
}

/// One replaced person in a card: the face prep found, an arrow to the character that replaces them (or a slot to
/// add one), what the prompt calls it, and `below` it the person's other views (`CharacterViewsRow`). The character
/// drags to another person, an angle or the extras. The background's card is the same, with a symbol for the face.
private struct PersonRow<Below: View>: View {
    typealias Picture = (number: Int, url: URL)

    let face: URL?
    var placeholder: String?
    let person: String
    let character: Picture?
    /// What to do while there is no image.
    var hint = "Click or drop the image they become"
    /// How many views go along, for the line under the name.
    var views = 0
    /// A close-up of the character's face goes along (`JobFiles.faceCloseUp(of:)`).
    var closeUp = false
    let warning: String?
    let onPick: () -> Void
    let onDrop: ([URL]) -> Void
    /// The image taken off.
    let onRemove: (URL) -> Void
    @ViewBuilder let below: Below
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Thumbnail(url: face)
                    .overlay {
                        if let placeholder {
                            Image(systemName: placeholder).font(.system(size: 16)).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .help(placeholder == nil ? "\(person) as prep found them" : "")
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(character == nil ? Theme.faint : Theme.accent)
                Button(action: onPick) { slotTile }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(character == nil ? "Pick the image for \(person)" : "Pick another image for \(person)")
                    .modifier(DragOut(url: character?.url))
                    .dropDestination(for: URL.self) { urls, _ in
                        onDrop(urls)
                        return true
                    } isTargeted: {
                        isTargeted = $0
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(person).font(Theme.Typography.strong).foregroundStyle(Theme.text)
                    Text(detail)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(character != nil ? Theme.muted : Theme.warning)
                    if let warning {
                        Label("Portrait for a full-body person", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.warning)
                            .help(warning)
                    }
                }
                Spacer(minLength: 0)
                if let character {
                    Text("@Image\(character.number)")
                        .font(Theme.Typography.strongMeta)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.well, in: Capsule())
                        .fixedSize()
                        .help("Name it in the prompt as @Image\(character.number)")
                    Button("Remove", systemImage: "xmark") { onRemove(character.url) }
                        .buttonStyle(.iconAction)
                        .help("Take this image off the clip")
                }
            }
            below
        }
        .padding(Theme.Spacing.small)
        .well(radius: Theme.Radius.field)
    }

    private var slotTile: some View {
        Group {
            if let character {
                Thumbnail(url: character.url)
            } else {
                Theme.well.overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(
                    isTargeted || character == nil ? Theme.accent : Theme.stroke,
                    style: StrokeStyle(lineWidth: 1, dash: character == nil ? [4, 3] : []))
        }
        .contentShape(Rectangle())
    }

    /// "Ready · 2 more views · face close-up", or what to do.
    private var detail: String {
        guard character != nil else { return hint }
        var parts = ["Ready"]
        if views > 0 { parts.append(views == 1 ? "1 more view" : "\(views) more views") }
        if closeUp { parts.append("face close-up added") }
        return parts.joined(separator: " · ")
    }
}

/// Makes the clip's image `url` draggable onto a person, a view slot or the extras.
private struct DragOut: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.draggable(url) { Thumbnail(url: url).frame(width: 48, height: 48) }
        } else {
            content
        }
    }
}

/// An extra reference, with its number in the prompt.
private struct CharacterTile: View {
    let url: URL
    let number: Int
    let onRemove: () -> Void

    var body: some View {
        // The frame comes from the clear square alone, so a wide image can't spill into the next tile.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { Thumbnail(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(alignment: .bottomLeading) { MediaTag(text: "\(number)").padding(2) }
            .overlay(alignment: .topTrailing) {
                Button("Remove", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Theme.scrim, in: Circle())
                    .buttonStyle(.plain)
                    .padding(2)
                    .help("Remove @Image\(number)")
            }
            .help("@Image\(number) · drag it onto a person")
            .draggable(url) { Thumbnail(url: url).frame(width: 48, height: 48) }
    }
}

private struct AddTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Theme.well
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .well(radius: Theme.Radius.small)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Add images, or drop them here")
        .accessibilityLabel("Add images")
    }
}

extension URL {
    var isImageFile: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true }
}
