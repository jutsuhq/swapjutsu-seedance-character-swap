import Foundation

extension Pipeline {
    func makeManifest(
        source: VideoSource, decision: Decision, targets masks: TargetMasks, depthMeans: [Int: Float],
        residual: DepthResidual?, guided: Int = 0
    ) -> Manifest {
        let tracklets = decision.tracklets, targets = decision.targets
        let bounds = [0] + decision.cuts + [source.frameCount]
        let shots = (0..<(bounds.count - 1)).map {
            Manifest.Shot(
                index: $0, start: bounds[$0], end: bounds[$0 + 1] - 1, orientation: decision.uprights[$0].degrees)
        }
        let totalArea = Double(max(1, tracklets.reduce(0) { $0 + $1.screenArea }))
        let identities = (1...max(1, decision.result.count)).map { id -> Manifest.Identity in
            let own = tracklets.filter { $0.identity == id }
            return Manifest.Identity(
                id: id, frames: Set(own.flatMap(\.frames)).count, shots: Set(own.map(\.shot)).sorted(),
                screenShare: Double(own.reduce(0) { $0 + $1.screenArea }) / totalArea,
                thumbnail: decision.bestShot[id] == nil ? nil : "identities/\(id).jpg", isTarget: targets.contains(id))
        }
        let brief = servicePrompt(
            people: targets.count, hasAudio: source.hasAudio,
            across: targets.sorted().map { across(of: $0, in: decision, width: source.size.width) },
            guided: guided > 0, shots: shots.count, seconds: source.duration,
            during: Self.windows(of: identities, in: shots, fps: Double(source.fps), seconds: source.duration))
        let quality = measure(
            source: source, decision: decision, targets: masks, depthMeans: depthMeans, residual: residual)
        return Manifest(
            source: source.url.lastPathComponent, width: Int(source.size.width), height: Int(source.size.height),
            fps: Int(source.fps), frames: source.frameCount, shots: shots,
            timeline: decision.perFrame.map { $0.map { decision.identityOf[$0.key] ?? 0 } },
            identities: identities, targets: targets.sorted(), quality: quality,
            warnings: warnings(source: source, decision: decision, quality: quality)
                + Self.unreplaced(identities, in: shots, fps: Double(source.fps)),
            seedance: .init(video: "control.mp4", prompt: brief.text(), durationSeconds: source.duration, brief: brief),
            timings: timings, tracking: masks.tracking, background: options.background,
            faceGuide: options.faceGuide
                ? .init(frames: guided, minFaceHeight: Double(options.tuning.faceGuideMinHeight)) : nil)
    }

    /// Presence and stability from the target masks the render used (tracked or Vision's); face coverage from
    /// Vision's detections, where the faces come from.
    private func measure(
        source: VideoSource, decision: Decision, targets: TargetMasks, depthMeans: [Int: Float],
        residual: DepthResidual?
    ) -> Manifest.Quality {
        let targetTracklets = decision.tracklets.filter { decision.targets.contains($0.identity) }
        var ious: [Double] = []
        for n in targets.perFrame.indices.dropFirst() where decision.shot(of: n) == decision.shot(of: n - 1) {
            for b in targets.perFrame[n] {
                if let a = targets.perFrame[n - 1].first(where: { $0.identity == b.identity }) {
                    ious.append(a.grid.iou(b.grid))
                }
            }
        }
        let targetDetections = targetTracklets.flatMap(\.detections)
        var flicker: [Double] = []
        let cutSet = Set(decision.cuts)
        for n in 1..<max(1, source.frameCount) where !cutSet.contains(n) {
            if let a = depthMeans[n - 1], let b = depthMeans[n] { flicker.append(Double(abs(a - b))) }
        }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        let faces = targetDetections.compactMap(\.face?.height).sorted()
        return Manifest.Quality(
            targetPresence: Double(targets.perFrame.filter { !$0.isEmpty }.count) / Double(source.frameCount),
            maskStability: mean(ious),
            faceCoverage: targetDetections.isEmpty
                ? 0 : Double(targetDetections.filter { $0.face != nil }.count) / Double(targetDetections.count),
            depthFlicker: mean(flicker), depthResidual: residual?.smoothed, depthResidualRaw: residual?.raw,
            closestIdentityDistance: decision.result.closestSeparate.map { Double($0.2) },
            mergeDistance: Double(options.tuning.mergeDistance),
            faceHeight: faces.isEmpty ? nil : Double(faces[faces.count / 2] / source.size.height))
    }

    private func warnings(source: VideoSource, decision: Decision, quality: Manifest.Quality) -> [String] {
        let tuning = options.tuning
        var warnings: [String] = []
        if let (a, b, d) = decision.result.closestSeparate, d < tuning.mergeDistance + tuning.ambiguityMargin {
            warnings.append(
                String(
                    format: "People %d and %d look alike (distance %.2f, merge below %.2f); check review.mp4", a, b, d,
                    tuning.mergeDistance))
        }
        if quality.faceCoverage < 0.5 {
            warnings.append("The target's face is visible in under half of their frames; lip sync may drift")
        }
        if quality.maskStability < 0.75 { warnings.append("The target mask changes a lot between frames") }
        if quality.targetPresence < 0.5 { warnings.append("The target is on screen in under half of the clip") }
        if source.sourceDuration > tuning.maxSeconds { warnings.append("Trimmed to \(Int(tuning.maxSeconds)) s") }
        if source.upscaled {
            warnings.append(
                "Upscaled to \(Int(source.size.width))×\(Int(source.size.height)) to meet Seedance's minimum frame size;"
                    + " fine detail will be soft")
        }
        return warnings
    }

    /// Where `identity` stands across the frame on average, 0 at the left edge and 1 at the right, from the centres
    /// of its detection boxes; nil when it has none.
    private func across(of identity: Int, in decision: Decision, width: CGFloat) -> Double? {
        let centres = decision.tracklets.filter { $0.identity == identity }.flatMap(\.detections).map(\.box.midX)
        guard !centres.isEmpty, width > 0 else { return nil }
        return Double(centres.reduce(0, +) / CGFloat(centres.count) / width)
    }

    /// The service prompt's brief (`ServicePrompt`). The vocals only when `@Video1` has a soundtrack.
    ///
    /// With several people, each `@Image` is tied to where its person stands (`across`, in image order). Seedance
    /// only sees depth silhouettes, so a binding by clothes or by "screen presence" gave it nothing to go on: in a
    /// two-dancer draft it took the first cat and kept the second dancer a person. When places are missing or too
    /// close to tell apart, the order of screen presence stays.
    ///
    /// With the background replaced (`BackgroundMode.replace`) nothing of the original is left to keep: the grey
    /// depth around the people is bound to the image after the characters, `@Image<count + 1>`.
    ///
    /// `guided`: the face guide drew its lines on some frame, which the prompt then explains.
    func servicePrompt(
        people count: Int, hasAudio: Bool, across: [Double?] = [], guided: Bool = false, shots: Int = 1,
        seconds: Double? = nil, during: [ServicePrompt.Window]? = nil
    ) -> ServicePrompt {
        let semitones = options.tuning.pitchSemitones
        return ServicePrompt(
            people: count, places: Self.places(across).flatMap { $0.count == count ? $0 : nil },
            background: options.background, shots: shots, seconds: seconds, during: during,
            semitones: hasAudio && semitones != 0 ? semitones : nil, guided: guided,
            control: options.control == .depth ? nil : options.control)
    }

    /// When the targets are on screen: the shots any of them is in, back-to-back shots joined, in seconds.
    static func windows(
        of identities: [Manifest.Identity], in shots: [Manifest.Shot], fps: Double, seconds: Double
    ) -> [ServicePrompt.Window] {
        let theirs = Set(identities.filter(\.isTarget).flatMap(\.shots))
        guard fps > 0 else { return [] }
        var windows: [ServicePrompt.Window] = []
        var last: Int?
        for shot in shots where theirs.contains(shot.index) {
            let start = Double(shot.start) / fps, end = min(seconds, Double(shot.end + 1) / fps)
            if let last, last == shot.index - 1, let open = windows.popLast() {
                windows.append(.init(start: open.start, end: end))
            } else {
                windows.append(.init(start: start, end: end))
            }
            last = shot.index
        }
        return windows
    }

    /// A shot with someone in it and none of the targets: they stay as filmed while the others are replaced, which
    /// the person asking to replace someone "in every shot" doesn't expect.
    static func unreplaced(_ identities: [Manifest.Identity], in shots: [Manifest.Shot], fps: Double) -> [String] {
        let theirs = Set(identities.filter(\.isTarget).flatMap(\.shots))
        guard !theirs.isEmpty, fps > 0 else { return [] }
        let others = Set(identities.filter { !$0.isTarget }.flatMap(\.shots))
        let left = shots.filter { others.contains($0.index) && !theirs.contains($0.index) }
        guard !left.isEmpty else { return [] }
        let times = left.map {
            "\(ServicePrompt.format(Double($0.start) / fps))–\(ServicePrompt.format(Double($0.end + 1) / fps)) s"
        }
        return [
            "No one is replaced in \(left.count == 1 ? "the shot" : "the shots") at \(ServicePrompt.list(times)); "
                + "who is in \(left.count == 1 ? "it stays" : "them stays") as filmed. Prepare again with them "
                + "picked too to replace them."
        ]
    }

    /// The service prompt as prep writes it, before the app adds face close-ups and extra references.
    func seedancePrompt(people count: Int, hasAudio: Bool, across: [Double?] = [], guided: Bool = false) -> String {
        servicePrompt(people: count, hasAudio: hasAudio, across: across, guided: guided).text()
    }

    /// "on the left", "in the middle", … for each position in `across`, in the same order; nil if any is missing
    /// or two stand within a tenth of the frame of each other, where left and right would be a guess.
    static func places(_ across: [Double?]) -> [String]? {
        let known = across.compactMap { $0 }
        guard known.count == across.count, known.count >= 2 else { return nil }
        let sorted = known.sorted()
        guard zip(sorted.dropFirst(), sorted).allSatisfy({ $0 - $1 >= 0.1 }) else { return nil }
        let names: [String] =
            switch known.count {
            case 2: ["on the left", "on the right"]
            case 3: ["on the left", "in the middle", "on the right"]
            default:
                (1...known.count).map { rank in
                    let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth"]
                    return "\(rank <= ordinals.count ? ordinals[rank - 1] : "number \(rank)") from the left"
                }
            }
        return known.map { x in names[sorted.firstIndex(of: x) ?? 0] }
    }
}
