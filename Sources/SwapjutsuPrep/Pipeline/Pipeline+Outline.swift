import CoreImage

/// One frame's targets, their mattes and outlines, and its depth.
struct FrameTargets {
    var n: Int
    var shot: Int
    var chosen: [(target: TargetMask, mask: CIImage)]
    var outlines: [(mask: CIImage, unit: CGFloat?)]
    var raw: CIImage?
    var range: ShotDepthRange?
    var extent: CGRect
}

/// The painted silhouettes of `BodyOutline`, and the depth and detail that go with them.
extension Pipeline {
    /// The targets' skeletons, from a pass over the frames before the render, so a frame Vision finds none on
    /// takes the ones before and after it.
    func skeletons(
        _ source: VideoSource, _ targets: TargetMasks, _ decision: Decision
    ) async throws
        -> BodyOutline.Track
    {
        var bodies = BodyOutline.Track()
        try await source.forEachFrame { n, frame in
            for m in targets.perFrame[n] {
                let size = frame.extent.size
                guard let found = try BodyOutline.find(in: frame, box: Self.box(of: m, in: size)),
                    found.fits(m.grid, size: size), let anchor = BodyOutline.Track.anchor(of: m.grid, size: size)
                else { continue }
                bodies.add(found, identity: m.identity, shot: decision.shot(of: n), frame: n, anchor: anchor)
            }
        }
        return bodies
    }

    /// The silhouette painted for each target, from its skeleton and box, and the skeleton's unit; the matte and
    /// no unit for one without a skeleton in the shot. The edit region's band past the matte (`radius`) is drawn
    /// inside the silhouette, not round it: grown past the silhouette it would paint the scene's far depth round
    /// the person, a dark rim. Nil for nil `chosen`, the mattes to be used.
    static func silhouettes(
        _ chosen: [(target: TargetMask, mask: CIImage)]?, frame n: Int, shot: Int, extent: CGRect,
        bodies: inout BodyOutline.Track, radius: (Int) -> CGFloat
    ) -> [(mask: CIImage, unit: CGFloat?)]? {
        chosen?.map { c in
            guard let anchor = BodyOutline.Track.anchor(of: c.target.grid, size: extent.size),
                let outline = bodies.outline(identity: c.target.identity, shot: shot, frame: n, anchor: anchor),
                let silhouette = outline.silhouette(matte: c.mask, box: box(of: c.target, in: extent.size))
            else { return (c.mask, nil) }
            let band = c.mask.applyingFilter(
                "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius(c.target.identity)])
            return (
                silhouette.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: band])
                    .cropped(to: extent), outline.unit
            )
        }
    }

    /// The person's own depth carried out of their `mattes` into the silhouettes, and no farther, past the
    /// silhouettes' soft edge, which would mix in the scene's depth; `raw` without a silhouette.
    static func painted(
        _ raw: CIImage, _ mattes: [CIImage], _ outlines: [(mask: CIImage, unit: CGFloat?)], range: ShotDepthRange,
        renderer: ControlRenderer
    ) -> CIImage {
        guard let unit = outlines.compactMap(\.unit).max(), let silhouettes = union(outlines.map(\.mask)),
            let matte = union(mattes)
        else { return raw }
        return renderer.filled(raw, matte: matte, range: range, sigma: unit * 0.6).applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: raw,
                kCIInputMaskImageKey: silhouettes.applyingFilter(
                    "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: unit * 0.15]),
            ])
    }

    /// Each target's matte and mean depth, for the folds of `ControlRenderer.detailed`.
    func details(
        _ chosen: [(target: TargetMask, mask: CIImage)], _ raw: CIImage, _ range: ShotDepthRange
    )
        -> [DetailTarget]
    {
        chosen.map { c in
            DetailTarget(core: c.mask, mean: range.meanInside(raw, mask: c.target.grid, context: context))
        }
    }
}
