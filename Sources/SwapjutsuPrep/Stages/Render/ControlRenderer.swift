import AppKit
import CoreImage

/// Builds the frames Seedance gets as `@Video1`: the target people painted with coloured depth over the untouched
/// original background (the recipe of the reference Genjutsu open-source workflow), optionally with face landmark
/// lines as lip-sync guidance. With the background replaced, everything else is painted with grey depth instead of
/// the original pixels.
struct ControlRenderer {
    let tuning: Tuning
    let context: CIContext
    private let palette: CIImage
    private let greys: CIImage

    init(tuning: Tuning, context: CIContext) {
        self.tuning = tuning
        self.context = context
        palette = Self.inferno()
        // Mid greys only: inferno runs to near black and pale yellow at its ends, and a grey that reached them could
        // read as the target's far or near end. Between, inferno is saturated and grey is not.
        greys = Self.gradient([[0.12, 0.12, 0.12], [0.88, 0.88, 0.88]])
    }

    /// Placed depth → normalised 0…1 by `range` → inferno colours.
    func colouredDepth(_ depth: CIImage, range: ShotDepthRange) -> CIImage {
        mapped(depth, range: range, gradient: palette)
    }

    /// Placed depth → normalised 0…1 by `range` → a grey ramp, far dark and near light like inferno.
    func greyDepth(_ depth: CIImage, range: ShotDepthRange) -> CIImage {
        mapped(depth, range: range, gradient: greys)
    }

    private func mapped(_ depth: CIImage, range: ShotDepthRange, gradient: CIImage) -> CIImage {
        let scale = CGFloat(1 / (range.high - range.low)), bias = CGFloat(-range.low / (range.high - range.low))
        return
            depth
            .applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
                ]
            )
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIColorMap", parameters: ["inputGradientImage": gradient])
            .cropped(to: depth.extent)
    }

    /// The masks of one frame (#56). `targets` are the targets' mattes, each grown by its shot's radius
    /// (`EditRegion`) for the edit region. `inFront` are the masks of other people in front of the targets
    /// (`Occlusion.front`): their pixels nearer than `threshold` in `depth` stay, with a soft step `ramp` wide in
    /// depth units. `objects` is the extra protected mask (`ForegroundMasking`). Protected pixels leave the subject
    /// matte and the edit region, and only inside the edit region: elsewhere the frame is untouched anyway.
    func masks(
        targets: [(mask: CIImage, radius: CGFloat)], inFront: [(mask: CIImage, threshold: Float)], depth: CIImage?,
        ramp: Float, objects: CIImage?, extent: CGRect
    ) -> ControlMasks {
        let empty = CIImage(color: .black).cropped(to: extent)
        let subject = union(targets.map(\.mask)) ?? empty
        let edit =
            union(
                targets.map {
                    $0.mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: $0.radius])
                }) ?? empty
        // The occluder's mask grows by the least dilation first: its soft edge would leave a painted rim on it. The
        // depth test keeps the growth off the target, which is farther.
        let grow = EditRegion.minimum(extent.size, tuning: tuning)
        var front = inFront.compactMap { other in
            depth.map {
                multiply(
                    other.mask.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow]),
                    nearer($0, other.threshold, ramp))
            }
        }
        if let objects { front.append(objects) }
        guard !targets.isEmpty, let protected = union(front) else {
            return ControlMasks(
                subject: subject.cropped(to: extent), edit: edit.cropped(to: extent), matte: grown(subject, extent))
        }
        let keep = multiply(protected, edit).applyingFilter("CIColorInvert")
        let visible = multiply(subject, keep)
        // Grown again from what stays visible, so no ring is left around the part handed to the occluder.
        let radius = targets.map(\.radius).max() ?? 0
        let regrown = visible.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        return ControlMasks(
            subject: visible.cropped(to: extent), edit: multiply(multiply(edit, regrown), keep).cropped(to: extent),
            matte: grown(visible, extent))
    }

    /// 1 where `depth` is nearer than `threshold` by `ramp` or more, 0 where it is not nearer, linear between.
    private func nearer(_ depth: CIImage, _ threshold: Float, _ ramp: Float) -> CIImage {
        let scale = CGFloat(1 / max(ramp, 1e-6)), bias = CGFloat(-threshold) * scale
        return depth.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
            ]
        ).applyingFilter("CIColorClamp")
    }

    private func union(_ masks: [CIImage]) -> CIImage? {
        guard var union = masks.first else { return nil }
        for mask in masks.dropFirst() {
            union = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: union])
        }
        return union
    }

    private func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    private func grown(_ mask: CIImage, _ extent: CGRect) -> CIImage {
        mask.applyingFilter(
            "CIMorphologyMaximum",
            parameters: [kCIInputRadiusKey: EditRegion.minimum(extent.size, tuning: tuning)]
        ).cropped(to: extent)
    }

    /// Coloured depth of the targets over the original, inside the edit region. The model's depth smears the
    /// background into the last pixels of the silhouette; those and the grown ring around the person take the
    /// person's own depth nearby, steered by the frame's colours (`DepthEdges`), so the silhouette gets no dark halo.
    /// Protected pixels are outside both masks, so they keep `background`: the original frame, or with the background
    /// replaced its grey depth (`greyDepth`), people in front included, since they belong to the old scene too. So do
    /// painted pixels left at the far end of the range after the fill (`Tuning.depthBehindRamp`).
    /// The landmark lines of `faces` are drawn on the painted person before the blend, so they stay where the person
    /// is painted and never land on the original or grey background.
    func composite(
        original: CIImage, background: CIImage? = nil, depth: CIImage, range: ShotDepthRange, masks: ControlMasks,
        faces: [FaceLandmarks] = [], hands: CIImage? = nil, detail: [DetailTarget] = []
    ) throws -> CIImage {
        let extent = original.extent
        var refined = try DepthEdges.refine(
            depth: depth, guide: original, core: masks.subject, grown: masks.edit,
            settings: .init(width: extent.width, tuning: tuning), floor: range.low)
        if let hands { refined = lifted(refined, hands: multiply(hands, masks.subject), by: range) }
        var coloured = colouredDepth(refined, range: range)
        if !detail.isEmpty {
            coloured = detailed(coloured, original: original, depth: refined, range: range, targets: detail)
        }
        let person = drawFaces(faces, over: coloured)
        let inFront = nearer(refined, range.low, max(tuning.depthBehindRamp * (range.high - range.low), 1e-6))
        return person.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: background ?? original, kCIInputMaskImageKey: multiply(masks.edit, inFront),
            ]
        ).cropped(to: extent)
    }

    /// `depth` with the `hands` mask added, `Tuning.handLift` of the range's spread where it is 1: nearer, so a hand
    /// over the torso gets a colour and an edge of its own.
    private func lifted(_ depth: CIImage, hands: CIImage, by range: ShotDepthRange) -> CIImage {
        let lift = CGFloat(tuning.handLift * (range.high - range.low))
        let nearer = depth.applyingFilter(
            "CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: lift, y: lift, z: lift, w: 0)])
        return nearer.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: depth, kCIInputMaskImageKey: hands]
        ).cropped(to: depth.extent)
    }

    /// Face landmark polylines in white, drawn over `image`.
    private func drawFaces(_ faces: [FaceLandmarks], over image: CIImage) -> CIImage {
        guard !faces.isEmpty else { return image }
        let size = image.extent.size
        guard
            let cg = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        cg.setLineWidth(max(1, size.width / 480))
        cg.setLineJoin(.round)
        for face in faces {
            for region in face.regions where region.points.count > 1 {
                cg.addLines(between: region.points)
                if region.closed { cg.closePath() }
            }
        }
        cg.strokePath()
        guard let overlay = cg.makeImage() else { return image }
        return CIImage(cgImage: overlay).composited(over: image)
    }

    /// Everyone tinted by identity colour over a dimmed frame, for reviewing the automatic identity assignment.
    func review(original: CIImage, people: [(mask: CIImage, identity: Int, isTarget: Bool)]) -> CIImage {
        let colours = [
            CIColor(red: 0.1, green: 1, blue: 0.2), CIColor(red: 1, green: 0.25, blue: 0.85),
            CIColor(red: 0.2, green: 0.55, blue: 1), CIColor(red: 1, green: 0.85, blue: 0.1),
        ]
        var out = original.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputBrightnessKey: -0.35, kCIInputSaturationKey: 0,
            ])
        for person in people {
            let tinted = original.applyingFilter(
                "CIColorMonochrome",
                parameters: [
                    kCIInputColorKey: colours[(person.identity - 1) % colours.count],
                    kCIInputIntensityKey: person.isTarget ? 0.8 : 0.45,
                ])
            out = tinted.applyingFilter(
                "CIBlendWithMask",
                parameters: [
                    kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: person.mask,
                ])
        }
        return out.cropped(to: original.extent)
    }

    /// Matplotlib's inferno, 11 stops.
    private static func inferno() -> CIImage {
        gradient([
            [0.001, 0.000, 0.014], [0.087, 0.044, 0.225], [0.258, 0.039, 0.406], [0.416, 0.090, 0.433],
            [0.578, 0.148, 0.404], [0.735, 0.216, 0.330], [0.865, 0.317, 0.226], [0.954, 0.469, 0.098],
            [0.988, 0.645, 0.040], [0.964, 0.844, 0.273], [0.988, 0.998, 0.645],
        ])
    }

    /// Evenly spaced RGB stops as a 256 × 1 gradient for CIColorMap.
    private static func gradient(_ stops: [SIMD3<Double>]) -> CIImage {
        var bytes = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let t = Double(i) / 255 * Double(stops.count - 1)
            let k = min(stops.count - 2, Int(t)), f = t - Double(k)
            let c = (stops[k] + (stops[k + 1] - stops[k]) * f) * 255
            (bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2]) = (UInt8(c.x), UInt8(c.y), UInt8(c.z))
        }
        return CIImage(
            bitmapData: Data(bytes), bytesPerRow: 256 * 4, size: CGSize(width: 256, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

/// A target that may get the footage's folds (`ControlRenderer.detailed`): its matte, and its mean normalised
/// depth on the frame (`ShotDepthRange.meanInside`).
struct DetailTarget {
    var core: CIImage
    var mean: Float
}

extension ControlRenderer {
    /// How much nearer than the target's own mean depth, in shares of the shot's range, a part of it starts to get
    /// the footage's folds (`detailed`), and gets them in full. An arm held out to the camera sits far nearer than the
    /// torso, where the depth is a smooth ramp running into inferno's pale end with no fold or cuff in it, and
    /// Seedance draws that sleeve as one flat slab. The torso keeps plain depth: its folds are in the depth already,
    /// and its luma has the garment's hems and bare skin in it, edges of an outfit that is replaced. So does a
    /// person near the camera as a whole: measured from the shot's range alone, all of them would be "near".
    static let detailNear: ClosedRange<Float> = 0.2...0.35
    /// The share by which the folds brighten or darken the colour, at most.
    static let detailDepth: CGFloat = 0.2

    /// `coloured` brightened and darkened by the footage's luma, only where a target reaches toward the camera
    /// (`detailNear`) and inside its matte. The luma is a band: blurred by a 50th of the width (19 px at 960), less its blur by a 15th (64 px),
    /// which keeps the sleeve's large folds as shading and drops its texture: a knit's ribs (a few dozen pixels apart
    /// near the camera) still show at a 100th, and Seedance draws the old garment's texture onto the new one. Also
    /// drops the lighting across the arm. Both blurs are of the person alone, each divided
    /// by the blurred mask, so the background beside the silhouette never brightens or darkens its edge. The
    /// colour's hue, and so the depth it encodes, stays.
    func detailed(
        _ coloured: CIImage, original: CIImage, depth: CIImage, range: ShotDepthRange, targets: [DetailTarget]
    ) -> CIImage {
        let extent = original.extent
        guard let core = union(targets.map(\.core)) else { return coloured }
        let shade = shade(original, core: core)
        let spread = range.high - range.low
        let ramp = (Self.detailNear.upperBound - Self.detailNear.lowerBound) * spread
        let reaching = targets.map { target in
            multiply(nearer(depth, range.low + (target.mean + Self.detailNear.lowerBound) * spread, ramp), target.core)
        }
        let near = union(reaching) ?? core
        // A little inside the silhouette, past the mask's own soft edge.
        let edge = max(1, extent.width / 200)
        let inside = core.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: edge])
            .applyingGaussianBlur(sigma: Double(edge) / 2)
        let weight = multiply(near, inside).cropped(to: extent)
        let white = CIImage(color: .white).cropped(to: extent)
        let applied = shade.applyingFilter(
            "CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: white, kCIInputMaskImageKey: weight])
        return coloured.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: applied])
            .cropped(to: extent)
    }

    /// 1 + gain × the luma's band (`detailed`), clamped to ± `detailDepth`: the footage's folds as a brightness.
    private func shade(_ original: CIImage, core: CIImage) -> CIImage {
        let extent = original.extent
        let (fine, coarse) = (extent.width / 50, extent.width / 15)
        let luma = original.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
                "inputGVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
                "inputBVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            ]
        )
        // The fine blur in red, the coarse in green (their maximum, black elsewhere, joins them without the clamping
        // or alpha a sum of two images gets), then 1 + gain × (fine − coarse), clamped to ± `detailDepth`.
        let channel = { (image: CIImage, red: CGFloat, green: CGFloat) in
            image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: green, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
        }
        let band = channel(blurred(luma, inside: core, sigma: fine), 1, 0).applyingFilter(
            "CIMaximumCompositing",
            parameters: [kCIInputBackgroundImageKey: channel(blurred(luma, inside: core, sigma: coarse), 0, 1)])
        let gain: CGFloat = 3
        let difference = CIVector(x: gain, y: -gain, z: 0, w: 0)
        let shade = band.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": difference, "inputGVector": difference, "inputBVector": difference,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
            ]
        ).applyingFilter(
            "CIColorClamp",
            parameters: [
                "inputMinComponents": CIVector(
                    x: 1 - Self.detailDepth, y: 1 - Self.detailDepth, z: 1 - Self.detailDepth, w: 1),
                "inputMaxComponents": CIVector(
                    x: 1 + Self.detailDepth, y: 1 + Self.detailDepth, z: 1 + Self.detailDepth, w: 1),
            ])
        return shade.cropped(to: extent)
    }

    /// The person's luma or colour blurred by `sigma` inside `mask` alone: each blur divided by the blurred mask, so
    /// nothing outside it (the background beside a silhouette, the person beside the background) mixes in.
    fileprivate func blurred(_ image: CIImage, inside mask: CIImage, sigma: CGFloat) -> CIImage {
        let masked = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            .clampedToExtent()
        return mask.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).applyingFilter(
            "CIDivideBlendMode",
            parameters: [kCIInputBackgroundImageKey: masked.applyingGaussianBlur(sigma: Double(sigma))])
    }

    /// `depth` with the person's own depth carried into the silhouette past `matte` (`BodyOutline`): the
    /// background's depth is there, which would paint the widened body near-black. Blurred by `sigma` inside the
    /// matte alone, in the shot's normalised range so the blur's division stays in 0…1; the matte keeps its depth.
    func filled(_ depth: CIImage, matte: CIImage, range: ShotDepthRange, sigma: CGFloat) -> CIImage {
        let extent = depth.extent
        let spread = CGFloat(range.high - range.low), low = CGFloat(range.low)
        let matrix = { (image: CIImage, scale: CGFloat, bias: CGFloat) in
            image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
                ])
        }
        let normalised = matrix(depth, 1 / spread, -low / spread).applyingFilter("CIColorClamp")
        let carried = normalised.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: blurred(normalised, inside: matte, sigma: sigma),
                kCIInputMaskImageKey: matte,
            ])
        // Everywhere past the matte: only the painted silhouette shows it.
        return matrix(carried, spread, low).cropped(to: extent)
    }

    /// How far the replaced background's grey depth is blurred, as a share of the width: only the old place's coarse
    /// layout stays (the floor's slope, a wall's side, where it is near or far), which moves with the camera and so
    /// carries its motion; its things (a bicycle, a door, a window frame, a facade's relief) go.
    static let settledBlur: CGFloat = 1.0 / 16
    /// The farthest the replaced background reads, as a share of the shot's range: the sky over an old street, at
    /// the far end, would read as the outdoors.
    static let settledFar: CGFloat = 0.25

    /// Grey depth of a replaced background (`greyDepth`) that keeps only the camera's motion and the old place's
    /// coarse layout: blurred by `settledBlur` of the width outside `people` (painted over anyway, and their depth
    /// would bleed into it), and nowhere farther than `settledFar`. Seedance draws what the grey depth shapes: with
    /// the full depth, the old street's bicycles, facades and sky came back where the camera turned past the new
    /// place's image. A control keeps what it shows; the new place can only come from what it leaves out.
    func settledGrey(_ depth: CIImage, range: ShotDepthRange, people: CIImage?) -> CIImage {
        let extent = depth.extent
        let scale = CGFloat(1 / (range.high - range.low)), bias = CGFloat(-range.low / (range.high - range.low))
        let normalised = depth.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
            ]
        ).applyingFilter("CIColorClamp")
        let outside =
            people?.applyingFilter("CIColorInvert") ?? CIImage(color: .white).cropped(to: extent)
        let far = Self.settledFar
        return blurred(normalised, inside: outside, sigma: extent.width * Self.settledBlur)
            .applyingFilter(
                "CIColorClamp",
                parameters: [
                    "inputMinComponents": CIVector(x: far, y: far, z: far, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ]
            )
            .applyingFilter("CIColorMap", parameters: ["inputGradientImage": greys])
            .cropped(to: extent)
    }
}
