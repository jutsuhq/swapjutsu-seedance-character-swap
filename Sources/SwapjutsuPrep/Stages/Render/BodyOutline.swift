import CoreImage
import Vision

/// The performer's painted silhouette drawn from their skeleton and box, not from their matte. The matte's outline
/// is the outline of the clothes they wear, and Seedance follows it over the prompt: a robe asked for over a narrow
/// sweater was left out, a sleeve kept the sweater's knit. Pose-driven character replacement drives the body with a
/// skeleton for this reason (Wan-Animate: a rendered body "contains the character's shape information"), and video
/// try-on masks the person with "the human bounding box together with the dilated pose skeleton", since a mask
/// from the old garment leaks its style (DreamVVT). Here the limbs are capsules round the bones and the torso a
/// widened trapezoid, wide enough for a coat or a robe, kept inside the person's box grown by a share of its size.
/// The matte stays whole inside it: Vision's body pose misses limbs (an arm held out to the camera, cut by the
/// frame) and puts skeletons off the person, and a silhouette short of the matte loses the arm. A skeleton most of
/// whose joints are off the matte (`fits`) is not used. Each eye is painted with a lens's reach round it (`eye`):
/// the rim of glasses stands out of a head seen side on or turned away, and left as footage Seedance completes it
/// into glasses on a character whose image has none. A limb ends flat at the wrist and the ankle: a round end
/// reaches a limb's width past the hand, a shape the size of a hand where there is none, and Seedance drew one there
/// (a stray "V" beside a dancer's arm).
struct BodyOutline: Equatable {
    /// Joints in frame pixels, origin bottom-left as Core Image has it.
    var joints: [VNHumanBodyPoseObservation.JointName: CGPoint]

    /// Widths as shares of the shoulders' span (`unit`): a limb's radius, how far the torso reaches past the
    /// shoulders and hips each side.
    static let limb: CGFloat = 0.32
    static let torso: CGFloat = 0.4
    /// The share of the skeleton's joints that must lie on the person's grid, a cell's slack allowed.
    static let fit: Double = 0.75
    /// How far past the person's box, as a share of its size, the outline may reach.
    static let box: CGFloat = 0.12
    /// The disc round each eye, as a share of the unit: a head is about half the shoulders' span, a lens and its
    /// rim a fifth of the head round the eye.
    static let eye: CGFloat = 0.2

    static let bones: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist), (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist), (.leftHip, .leftKnee), (.leftKnee, .leftAnkle), (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
    ]

    /// The shoulders' span, or half the torso's length without both shoulders; nil without either.
    var unit: CGFloat? {
        if let l = joints[.leftShoulder], let r = joints[.rightShoulder] {
            let span = hypot(l.x - r.x, l.y - r.y)
            if span > 4 { return span }
        }
        guard let neck = joints[.neck], let root = joints[.root] else { return nil }
        let length = hypot(neck.x - root.x, neck.y - root.y)
        return length > 8 ? length / 2 : nil
    }

    /// The body Vision finds in `box` of `frame` (its torso's middle in `box`, the largest such), joints at 0.3
    /// confidence or more; nil without one that has a `unit`.
    static func find(in frame: CIImage, box: CGRect) throws -> BodyOutline? {
        let region = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.1).intersection(frame.extent)
        guard region.width > 32, region.height > 32 else { return nil }
        let scale = max(1, 512 / max(region.width, region.height))
        let crop = frame.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(ciImage: crop).perform([request])
        let size = crop.extent.size
        let found = (request.results ?? []).compactMap { observation -> BodyOutline? in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            let joints = points.filter { $0.value.confidence >= 0.3 }.mapValues { p in
                CGPoint(
                    x: p.location.x * size.width / scale + region.minX,
                    y: p.location.y * size.height / scale + region.minY)
            }
            let outline = BodyOutline(joints: joints)
            guard outline.unit != nil, let middle = outline.middle, box.contains(middle) else { return nil }
            return outline
        }
        return found.max { ($0.unit ?? 0) < ($1.unit ?? 0) }
    }

    /// The torso's middle: the mean of the shoulders, hips, neck and root it has.
    var middle: CGPoint? {
        let points = [.leftShoulder, .rightShoulder, .leftHip, .rightHip, .neck, .root].compactMap { joints[$0] }
        guard !points.isEmpty else { return nil }
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// The skeleton's region, white on black the size of `extent`: the limbs, the torso and the eyes' discs, inside
    /// `box` (the person's) grown by `Self.box`. Nil without a `unit`.
    func region(box: CGRect, extent: CGRect) -> CIImage? {
        guard let unit,
            let cg = CGContext(
                data: nil, width: Int(extent.width), height: Int(extent.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: extent.size))
        cg.translateBy(x: -extent.minX, y: -extent.minY)
        let bounds = box.insetBy(dx: -box.width * Self.box, dy: -box.height * Self.box)
        cg.clip(to: bounds)
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.setLineCap(.butt)
        cg.setLineWidth(2 * Self.limb * unit)
        // Each bone round at its start (a shoulder, elbow, hip or knee, where it bends or leaves the torso), flat at
        // its end: the forearm and shin end at the wrist and ankle.
        let radius = Self.limb * unit
        for (a, b) in Self.bones {
            guard let p = joints[a], let q = joints[b] else { continue }
            cg.addLines(between: [p, q])
            cg.strokePath()
            cg.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
        }
        // The torso: shoulders to hips, each corner pushed out from the torso's middle by `torso` of the unit.
        let corners = [.leftShoulder, .rightShoulder, .rightHip, .leftHip].compactMap { joints[$0] }
        if corners.count == 4, let middle {
            let reach = Self.torso * unit
            let pushed = corners.map { c -> CGPoint in
                let (dx, dy) = (c.x - middle.x, c.y - middle.y)
                let length = max(hypot(dx, dy), 1)
                return CGPoint(x: c.x + dx / length * reach, y: c.y + dy / length * reach)
            }
            cg.addLines(between: pushed)
            cg.closePath()
            cg.fillPath()
        } else if let neck = joints[.neck], let root = joints[.root] {
            cg.setLineWidth(2 * (Self.torso + 0.5) * unit)
            cg.addLines(between: [neck, root])
            cg.strokePath()
        }
        for eye in [.leftEye, .rightEye].compactMap({ joints[$0] }) {
            let r = Self.eye * unit
            cg.fillEllipse(in: CGRect(x: eye.x - r, y: eye.y - r, width: 2 * r, height: 2 * r))
        }
        guard let image = cg.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// Whether `fit` of the joints lie on `grid` (the person's, rows top-down over a frame of `size`) or a cell
    /// beside it.
    func fits(_ grid: MaskGrid, size: CGSize) -> Bool {
        guard !joints.isEmpty else { return false }
        let near = grid.dilated(by: 1)
        let on = joints.values.filter { p in
            let x = Int(p.x / size.width * CGFloat(grid.side)), y = Int((1 - p.y / size.height) * CGFloat(grid.side))
            return (0..<grid.side).contains(x) && (0..<grid.side).contains(y) && near.cells[y * grid.side + x]
        }
        return Double(on.count) >= Self.fit * Double(joints.count)
    }

    /// The painted silhouette: the skeleton's region and the whole `matte`, the region's edge softened by a
    /// sixtieth of the unit, a few pixels. Nil without a `unit`.
    func silhouette(matte: CIImage, box: CGRect) -> CIImage? {
        let extent = matte.extent
        guard let unit, let body = region(box: box, extent: extent) else { return nil }
        let soft = body.clampedToExtent().applyingGaussianBlur(sigma: Double(unit) / 60).cropped(to: extent)
        return soft.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: matte])
            .cropped(to: extent)
    }
}

extension BodyOutline {
    /// Vision finds the body on some frames only (a third of a walk toward the camera, the arm held out), and a
    /// silhouette that came and went would flicker. The skeletons found in a first pass are kept per target and
    /// shot; a frame without one takes its nearest found frames' before and after, each moved with the person's
    /// matte (its centroid), mixed by how near each is. A found frame is averaged with the found frames beside it,
    /// as Vision's joints jitter. A guessed frame has no arms: an arm moves faster than the body, a guessed one is
    /// painted where the arm isn't beside the real one in the matte, and Seedance makes a second hand of it.
    /// note: moved, not scaled; a person walking far nearer between two found frames gets a torso of their width
    /// then, scaling by the matte's height is the upgrade.
    struct Track {
        struct Found {
            var frame: Int
            var outline: BodyOutline
            var anchor: CGPoint
        }

        private var found: [[Int]: [Found]] = [:]
        private(set) var frames = 0

        /// The centroid of `grid` (rows top-down) over a frame of `size`, in Core Image's coordinates.
        static func anchor(of grid: MaskGrid, size: CGSize) -> CGPoint? {
            var (x, y, n) = (0.0, 0.0, 0.0)
            for (k, on) in grid.cells.enumerated() where on {
                x += Double(k % grid.side) + 0.5
                y += Double(k / grid.side) + 0.5
                n += 1
            }
            guard n > 0 else { return nil }
            let side = Double(grid.side)
            return CGPoint(x: x / n / side * size.width, y: (1 - y / n / side) * size.height)
        }

        /// Adds a skeleton found on `frame`; frames come in order.
        mutating func add(_ outline: BodyOutline, identity: Int, shot: Int, frame: Int, anchor: CGPoint) {
            found[[shot, identity], default: []].append(Found(frame: frame, outline: outline, anchor: anchor))
        }

        /// The outline of `identity` on `frame` of `shot`, its matte's centroid at `anchor`; nil when the shot has
        /// no skeleton of it.
        mutating func outline(identity: Int, shot: Int, frame: Int, anchor: CGPoint) -> BodyOutline? {
            let list = found[[shot, identity]] ?? []
            let at = { (f: Found) in f.outline.moved(by: CGVector(dx: anchor.x - f.anchor.x, dy: anchor.y - f.anchor.y))
            }
            let outline: BodyOutline?
            if let k = list.firstIndex(where: { $0.frame == frame }) {
                let beside = list[max(0, k - 1)...min(list.count - 1, k + 1)].filter { abs($0.frame - frame) <= 1 }
                outline = BodyOutline.mean(beside.map(at))
            } else {
                let before = list.last { $0.frame < frame }, after = list.first { $0.frame > frame }
                switch (before, after) {
                case (let b?, let a?):
                    let t = CGFloat(frame - b.frame) / CGFloat(a.frame - b.frame)
                    outline = at(b).mixed(with: at(a), t).armless
                case (let b?, nil): outline = at(b).armless
                case (nil, let a?): outline = at(a).armless
                case (nil, nil): outline = nil
                }
            }
            if outline != nil { frames += 1 }
            return outline
        }

        /// "  outline from the skeleton on 230/240 target-frames (found on 80)", nil when none was.
        func summary(of count: Int) -> String? {
            let seen = found.values.map(\.count).reduce(0, +)
            return frames == 0
                ? nil : "  outline from the skeleton on \(frames)/\(count) target-frames (found on \(seen))"
        }
    }

    /// The skeleton without its elbows and wrists: the torso and legs only, the arms left to the matte.
    var armless: BodyOutline {
        BodyOutline(joints: joints.filter { ![.leftElbow, .rightElbow, .leftWrist, .rightWrist].contains($0.key) })
    }

    /// The joints moved by `offset`.
    func moved(by offset: CGVector) -> BodyOutline {
        BodyOutline(joints: joints.mapValues { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) })
    }

    /// `t` of the way from this outline to `other`, joint by joint where both have the joint, and either's own
    /// joint where only one has it.
    func mixed(with other: BodyOutline, _ t: CGFloat) -> BodyOutline {
        BodyOutline(
            joints: joints.merging(other.joints) { p, q in CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
        )
    }

    /// The outlines' mean, joint by joint; nil without one.
    static func mean(_ outlines: [BodyOutline]) -> BodyOutline? {
        guard var mean = outlines.first else { return nil }
        for (k, outline) in outlines.enumerated().dropFirst() { mean = mean.mixed(with: outline, 1 / CGFloat(k + 1)) }
        return mean
    }
}
