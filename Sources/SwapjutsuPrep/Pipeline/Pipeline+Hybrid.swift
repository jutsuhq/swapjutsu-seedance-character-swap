import CoreImage
import Foundation

/// Where a hybrid control (`ControlMode`) shows the footage's pixels, frame by frame: the targets' hands, tracked
/// through each shot, and their heads, which always stay colored depth.
struct HybridMasks {
    /// Frames with a hand mask in the mask cache (`key(hands:)`).
    var hands: Set<Int> = []
    /// Each frame's head zones.
    var heads: [Int: [HeadZone]] = [:]
    /// Frames where Vision found a hand, and where the tracker carried one.
    var visionFrames = 0
    var trackedFrames = 0

    static func key(hands frame: Int) -> String { "h_\(frame)" }

    /// "  hybrid: hands on 96/120 frames (Vision 46, tracked 94), heads on 120".
    func summary(of count: Int) -> String {
        "  hybrid: hands on \(hands.count)/\(count) frames (Vision \(visionFrames), tracked \(trackedFrames)), "
            + "heads on \(heads.count)"
    }
}

/// One target's head on one frame, frame pixels with the origin bottom-left as Core Image has it: the face grown
/// to an ellipse, and the box above and beside it where the hair is, which the person's mask cuts to the hair.
struct HeadZone: Equatable {
    var face: CGRect
    var hair: CGRect
    var identity: Int

    /// Vision's face box ×1.6 for the ellipse; the hair box reaches 0.9 face heights above it and a quarter of its
    /// width to each side, down to the face's middle.
    init(face box: CGRect, identity: Int) {
        let grown = box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3)
        face = grown
        hair = CGRect(
            x: grown.minX - grown.width * 0.25, y: grown.midY, width: grown.width * 1.5,
            height: grown.height / 2 + box.height * 0.9)
        self.identity = identity
    }

    /// No face: the top of the person's mask, which is the head whatever the arms do, a head's height of it (a
    /// sixth of the person, at least a cell) where its cells are; nil for an empty mask. Frame pixels of `size`.
    static func fallback(person grid: MaskGrid, size: CGSize, identity: Int) -> HeadZone? {
        let side = grid.side
        let rows = (0..<side).filter { y in (0..<side).contains { grid.cells[y * side + $0] } }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        let band = top...min(bottom, top + max(1, (bottom - top + 1) / 6) - 1)
        let xs = band.flatMap { y in (0..<side).filter { grid.cells[y * side + $0] } }
        guard let minX = xs.min(), let maxX = xs.max() else { return nil }
        let cell = CGSize(width: size.width / CGFloat(side), height: size.height / CGFloat(side))
        // Grid rows are top-down; the zone is bottom-left like the frame.
        let box = CGRect(
            x: CGFloat(minX) * cell.width, y: size.height - CGFloat(band.upperBound + 1) * cell.height,
            width: CGFloat(maxX - minX + 1) * cell.width, height: CGFloat(band.count) * cell.height)
        // The zone grows the face by 1.6: start from the box shrunk by as much, so the head is what it covers.
        return HeadZone(face: box.insetBy(dx: box.width * 0.19, dy: box.height * 0.19), identity: identity)
    }

    /// The zone as a white-on-black mask the size of `extent`: the ellipse, and the hair box inside `person`.
    func mask(person: CIImage, extent: CGRect) -> CIImage {
        let black = CIImage(color: .black).cropped(to: extent)
        // A 100 px disc stretched to the face's ellipse.
        let disc =
            CIFilter(
                name: "CIRadialGradient",
                parameters: [
                    "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": 99, "inputRadius1": 100,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.black,
                ])?.outputImage ?? black
        let oval = disc.transformed(
            by: CGAffineTransform(scaleX: face.width / 200, y: face.height / 200)
                .concatenating(CGAffineTransform(translationX: face.midX, y: face.midY)))
        let box = CIImage(color: .white).cropped(to: hair.intersection(extent)).composited(over: black)
        let hairMask = box.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: person])
        return oval.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: hairMask])
            .cropped(to: extent)
    }

    /// Every zone of a frame in one mask; nil without any.
    static func mask(_ zones: [HeadZone], person: CIImage, extent: CGRect) -> CIImage? {
        zones.map { $0.mask(person: person, extent: extent) }.reduce(nil) { all, one in
            all.map { one.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? one
        }
    }
}

extension Pipeline {
    /// The hands and heads of the targets for a hybrid control, nil for colored depth. Vision's hand pose finds a
    /// hand on only some frames (a hand turned or blurred by motion is missed, often on most frames); its masks seed EdgeTAM (`CorrectedTracking`), which
    /// carries the hands through each shot both ways, so every frame between gets one too. Without a tracker the
    /// hands are Vision's alone, held for three frames. Either mask, grown by `handMargin`, keeps only the pixels
    /// of the hand's skin (`HandSkin`, sampled from the shot's Vision hands): the cuff and the pocket around a hand
    /// stay colored depth, and of that skin only the patches attached to the hand (`HandSkin.attached`). The heads
    /// are Vision's face boxes, held for two frames, else the top of the person's mask. The body shows its hands
    /// with the rest, so it tracks none.
    func hybridMasks(
        _ source: VideoSource, decision: Decision, targets: TargetMasks, work: Workspace
    ) async throws -> HybridMasks? {
        guard options.control != .depth else { return nil }
        var result = HybridMasks()
        var detected: [Int: [HandCue.Hand]] = [:]
        var samples: [Int: [HandSkin.Pixel]] = [:]
        let (width, height) = (Int(source.size.width), Int(source.size.height))
        var lastFace: [Int: (frame: Int, zone: HeadZone)] = [:]
        try await source.forEachFrame { n, frame in
            let chosen = targets.perFrame[n]
            let hands =
                options.control == .hybridHands
                ? try timed("hands") { try self.hands(in: frame, targets: chosen) } : []
            if !hands.isEmpty { detected[n] = hands }
            result.heads[n] = chosen.compactMap { target in
                if let face = target.face, let box = Self.bounds(of: face) {
                    let zone = HeadZone(face: box, identity: target.identity)
                    lastFace[target.identity] = (n, zone)
                    return zone
                }
                if let last = lastFace[target.identity], n - last.frame <= 2,
                    decision.shot(of: last.frame) == decision.shot(of: n)
                {
                    return last.zone
                }
                return HeadZone.fallback(person: target.grid, size: frame.extent.size, identity: target.identity)
            }
        }
        let extent = CGRect(origin: .zero, size: source.size)
        let found = try Self.plausible(detected, shot: decision.shot(of:)).compactMapValues { hands in
            try HandCue.mask(hands, extent: extent).map(bytes)
        }
        if !found.isEmpty {
            try await source.forEachFrame { n, frame in
                guard let drawn = found[n] else { return }
                let rgba = renderRGBA(frame, width: width, height: height, context: context)
                samples[decision.shot(of: n), default: []] += HandSkin.samples(rgba: rgba, mask: drawn)
            }
        }
        result.visionFrames = found.count
        let tracked = try await trackHands(source, decision: decision, seeds: found)
        result.trackedFrames = tracked.count
        let skins = samples.compactMapValues(HandSkin.init(samples:))
        let bounds = [0] + decision.cuts + [source.frameCount]
        var regions: [Int: [UInt8]] = [:]
        for s in 0..<(bounds.count - 1) {
            let frames = bounds[s]..<bounds[s + 1]
            for n in frames {
                // Without a tracked mask, Vision's last hands hold for three frames, as `HandCue.Hold` does.
                let vision = found[n] ?? (tracked[n] == nil ? lastVision(before: n, in: frames, found) : nil)
                regions[n] = Self.handBytes(tracked: tracked[n], vision: vision)
            }
        }
        let image = { (mask: [UInt8]) in
            CIImage(
                bitmapData: Data(mask), bytesPerRow: width, size: source.size, format: .L8, colorSpace: nil)
        }
        var kept: (frame: Int, mask: [UInt8])?
        try await source.forEachFrame { n, frame in
            guard let region = regions[n] else { return }
            let shot = decision.shot(of: n)
            let mask = try timed("skin") {
                let skin =
                    try skins[shot].map {
                        try bytes($0.mask(HandSkin.grown(image(region), by: Self.handMargin), frame: frame))
                    } ?? region
                // Anchored to Vision's hand on this frame, else to the hand kept on the one before, given room to move.
                let before = try kept.flatMap { k in
                    k.frame == n - 1 && decision.shot(of: k.frame) == shot
                        ? try bytes(HandSkin.grown(image(k.mask), by: Self.handTravel)) : nil
                }
                return HandSkin.attached(skin, width: width, anchor: found[n] ?? before)
            }
            guard mask.lazy.filter({ $0 > 127 }).count >= 12 else { return }
            kept = (n, mask)
            try work.masks.store(Data(mask), key: HybridMasks.key(hands: n))
            result.hands.insert(n)
        }
        log(result.summary(of: source.frameCount))
        return result
    }

    /// The hands of `detected` (frame → Vision's hands) whose size is at most twice the median of their shot's (a
    /// hand turned or in a pocket measures less, never more): Vision sometimes puts a hand's wrist far off on the
    /// body (several hand lengths from the knuckles), and the palm drawn to it
    /// covers the belly, which then passes for the hand's skin.
    static func plausible(
        _ detected: [Int: [HandCue.Hand]], shot: (Int) -> Int
    ) -> [Int: [HandCue.Hand]] {
        let sizes = Dictionary(grouping: detected.flatMap { n, hands in hands.map { (shot(n), $0.size) } }) { $0.0 }
            .mapValues { $0.map(\.1).sorted() }
        return detected.reduce(into: [:]) { out, entry in
            let (n, hands) = entry
            guard let shotSizes = sizes[shot(n)], shotSizes.count >= 3 else {
                out[n] = hands
                return
            }
            let median = shotSizes[shotSizes.count / 2]
            let kept = hands.filter { $0.size <= median * 2 }
            if !kept.isEmpty { out[n] = kept }
        }
    }

    /// The tracked hands with Vision's drawn over them, so a frame where Vision found a hand always has it; nil when
    /// neither has a pixel.
    static func handBytes(tracked: [UInt8]?, vision: [UInt8]?) -> [UInt8]? {
        let merged: [UInt8]? =
            switch (tracked, vision) {
            case (let t?, let v?) where t.count == v.count: zip(t, v).map { max($0, $1) }
            case (let t?, _): t
            case (nil, let v?): v
            case (nil, nil): nil
            }
        guard let merged, merged.contains(where: { $0 > 127 }) else { return nil }
        return merged
    }

    private func lastVision(before n: Int, in frames: Range<Int>, _ found: [Int: [UInt8]]) -> [UInt8]? {
        stride(from: n - 1, through: max(frames.lowerBound, n - 3), by: -1).lazy.compactMap { found[$0] }.first
    }

    /// Vision's hands as seeds and pinned corrections of one tracker object per shot, tracked both ways from the
    /// first. Seeds closer than four frames to the one before are skipped: neighbours add nothing but conditioning
    /// slots. Frame → mask bytes, rows top-down.
    private func trackHands(
        _ source: VideoSource, decision: Decision, seeds: [Int: [UInt8]]
    ) async throws -> [Int: [UInt8]] {
        guard !seeds.isEmpty, let load = stages.tracking else { return [:] }
        var tracker: any MaskTracking
        do { tracker = try await load() } catch {
            if error is CancellationError { throw error }
            log("Hand tracking unavailable, keeping Vision's hands: \(error)")
            return [:]
        }
        if decision.uprights.contains(where: \.isTurned) { tracker = UprightTracking(tracker) }
        let bounds = [0] + decision.cuts + [source.frameCount]
        var out: [Int: [UInt8]] = [:]
        let start = Date()
        for s in 0..<(bounds.count - 1) {
            var corrections: [CorrectedTracking.Correction] = []
            for n in seeds.keys.sorted() where bounds[s] <= n && n < bounds[s + 1] {
                guard let mask = seeds[n] else { continue }
                if let last = corrections.last, n - last.frame < 4 { continue }
                corrections.append(.init(frame: n, prompt: .mask(mask)))
            }
            guard !corrections.isEmpty else { continue }
            let driver = CorrectedTracking(
                tracker: tracker, context: context, read: { try await source.forEachFrame(in: $0, $1) })
            let shot = CorrectedTracking.Shot(
                index: s, start: bounds[s], end: bounds[s + 1], object: 1, crop: nil, corrections: corrections,
                upright: decision.uprights[s])
            do {
                try await driver.run(shot) { n, result in
                    if let mask = result.mask, result.score > 0 { out[n] = mask }
                }
            } catch {
                if error is CancellationError { throw error }
                log("Hand tracking failed on shot \(s), keeping Vision's hands there: \(error)")
            }
        }
        timings["hand tracking"] = Date().timeIntervalSince(start)
        return out
    }

    /// Frame-sized bytes of `mask`, rows top-down, as the tracker takes them.
    private func bytes(_ mask: CIImage) throws -> [UInt8] {
        let w = Int(mask.extent.width), h = Int(mask.extent.height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(mask, toBitmap: base, rowBytes: w, bounds: mask.extent, format: .L8, colorSpace: nil)
        }
        return bytes
    }

    /// The box of every landmark of `face`.
    static func bounds(of face: FaceLandmarks) -> CGRect? {
        let points = face.regions.flatMap(\.points)
        guard let first = points.first else { return nil }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// Pixels the hand's region reaches past its joints and the tracked mask, for the skin test to cut back.
    static let handMargin = 3
    /// Pixels a hand may move between frames and still be the hand kept on the frame before.
    static let handTravel = 12

    /// Where the frame shows the footage: with `hands`, the hand's skin inside the edit region, its edge pulled in
    /// by half the feather so the feather blends skin, not what is beside it; otherwise the targets' edit region.
    /// Never inside the heads; edges feathered by `feather` pixels.
    static func realMask(
        mode: ControlMode, subject: CIImage, edit: CIImage, hands: CIImage?, heads: CIImage?, feather: CGFloat
    ) -> CIImage? {
        let extent = subject.extent
        let area: CIImage
        switch mode {
        case .depth: return nil
        case .hybridHands:
            guard let hands else { return nil }
            area = hands.clampedToExtent()
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: feather / 2])
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: edit])
        case .hybridBody:
            // The edit region, not the matte: the band between them would stay a colored-depth halo round the body.
            area = edit
        }
        var mask = area.cropped(to: extent)
        if let heads {
            // The head grows by the blur's reach (four sigmas) first, so no source pixel bleeds into the zone.
            let keep = heads.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: feather * 2 + 1])
                .applyingFilter("CIColorInvert")
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
        }
        // The blur reaches outward and inward by the feather; clamped so the frame's edge stays solid.
        return mask.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: extent)
    }

    /// The footage over `control` where `real` is white.
    static func hybrid(control: CIImage, original: CIImage, real: CIImage) -> CIImage {
        original.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: control, kCIInputMaskImageKey: real]
        ).cropped(to: control.extent)
    }

    /// Frame `n` of a hybrid control: the footage of the hands or body over `out`, with the heads kept as they are;
    /// `out` itself without `hybrid`.
    func hybridFrame(
        _ out: CIImage, original: CIImage, n: Int, masks: ControlMasks, hybrid: HybridMasks?, work: Workspace
    ) throws -> CIImage {
        guard let hybrid else { return out }
        let extent = original.extent
        let hands =
            !hybrid.hands.contains(n)
            ? nil : try timed("io") { try work.masks.load(key: HybridMasks.key(hands: n), size: extent.size) }
        let heads = HeadZone.mask(hybrid.heads[n] ?? [], person: masks.subject, extent: extent)
        guard
            let real = Self.realMask(
                mode: options.control, subject: masks.subject, edit: masks.edit, hands: hands, heads: heads,
                feather: Self.hybridFeather(extent, mode: options.control))
        else { return out }
        return Self.hybrid(control: out, original: original, real: real)
    }

    /// The seam between footage and depth: round the body 8 px at 720p, never under 6 or over 10; round the hands
    /// 4 px, so it stays on the skin.
    static func hybridFeather(_ extent: CGRect, mode: ControlMode) -> CGFloat {
        mode == .hybridHands ? 4 : min(10, max(6, min(extent.width, extent.height) / 90))
    }
}
