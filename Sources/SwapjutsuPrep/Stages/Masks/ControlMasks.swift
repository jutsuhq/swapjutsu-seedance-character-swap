import CoreImage

// The three masks of the control video (#56): the target's own visible pixels (`subject`), where the generator may
// change pixels for the new silhouette (`edit`, painted with depth), and the pixels that stay in front of the
// character as the original frame (`protected`).

/// Extra protected pixels per frame: things in front of the target that are not people (a door, a steering wheel, a
/// microphone). `OccluderMasking` finds them automatically; a mask tracked from a point or box the user places in the
/// app (#58) can take its place. Plugged in through `PrepStages.foreground`; nil protects other people only.
public protocol ForegroundMasking {
    /// Frame-sized one-channel mask of what stays in front of the target on `frame` (white = in front), or nil.
    func protectedMask(frame: Int, size: CGSize) throws -> CIImage?
    /// As `protectedMask(frame:size:)`, with the frame, its masks and depth (`OccluderMasking` finds occluders in them).
    func protectedMask(_ frame: ForegroundFrame) throws -> CIImage?
}

/// The masks one control frame is rendered with, all frame-sized.
struct ControlMasks {
    /// The targets' visible pixels: their tracked mattes minus what is in front of them. Trusted depth samples.
    let subject: CIImage
    /// Painted with depth: the targets' mattes grown by their shot's radius, minus `protected`.
    let edit: CIImage
    /// Written to `mask.mp4`: `subject` grown by `Tuning.maskDilation`, as before #56.
    let matte: CIImage
}

/// Where another person stands relative to the target, where their masks meet.
enum Occlusion: Equatable {
    /// Nearer than the target where they meet. Their pixels inside the edit region that are nearer than `depth`,
    /// halfway between the two people's depth at the contact, stay in front, also where the target's matte claims
    /// them (a hand across the chest the tracker took for the target's).
    case front(depth: Float)
    /// No clear order (side by side, or too little contact to measure): painted over as before #56. Vision's masks
    /// reach a few pixels into a touching neighbour, so keeping them would show the target's own edge.
    case beside
    /// Farther than the target: the new silhouette may cover them.
    case behind

    var label: String {
        switch self {
        case .front: "front"
        case .beside: "beside"
        case .behind: "behind"
        }
    }

    /// The order of `other` against `target` on the occupancy grid, or nil when `other` does not come within
    /// `reach` cells of the target, is the target itself under another identity (covers over `occlusionMaxShare` of
    /// it), or is a fragment smaller than `occlusionMinArea` of it (a hand Vision split off the target, a headrest
    /// Vision took for a person).
    ///
    /// The rule: take the cells of each mask within `band` cells of the other (the contact band; the other
    /// person's side includes the cells both masks claim) and compare the median depth there, larger = nearer,
    /// as a share of the shot's depth `span`. Over `tolerance` nearer is `front`, over `tolerance` farther is
    /// `behind`, anything else or fewer than `minCells` cells on a side is `beside`. Depth only orders two masks
    /// that meet; it never makes a mask.
    static func order(
        target: MaskGrid, other: MaskGrid, reach: Int, depth: () -> [Float], span: Float, tuning: Tuning
    ) -> Occlusion? {
        order(Contact(target: target, reach: reach, tuning: tuning), other: other, depth: depth, span: span)
    }

    /// The target's grid with its neighbourhoods, made once per frame for all the other people.
    struct Contact {
        let target: MaskGrid
        let tuning: Tuning
        /// Within reach of the edit region and the contact band.
        let near: MaskGrid
        /// Within the contact band.
        let band: MaskGrid

        init(target: MaskGrid, reach: Int, tuning: Tuning) {
            self.target = target
            self.tuning = tuning
            band = target.dilated(by: tuning.occlusionBand)
            near = reach > 0 ? band.dilated(by: reach) : band
        }
    }

    static func order(_ contact: Contact, other: MaskGrid, depth: () -> [Float], span: Float) -> Occlusion? {
        let target = contact.target, tuning = contact.tuning
        let area = Double(max(1, target.area))
        guard Double(other.area) >= tuning.occlusionMinArea * area,
            other.cells.indices.contains(where: { other.cells[$0] && contact.near.cells[$0] })
        else { return nil }
        var shared = 0
        var otherSide: [Int] = []
        for k in other.cells.indices where other.cells[k] {
            if target.cells[k] { shared += 1 }
            if contact.band.cells[k] { otherSide.append(k) }
        }
        guard Double(shared) <= tuning.occlusionMaxShare * area else { return nil }
        let minCells = tuning.occlusionMinCells
        guard otherSide.count >= minCells, span > 0 else { return .beside }
        let otherNear = other.dilated(by: tuning.occlusionBand)
        let targetSide = target.cells.indices.filter { target.cells[$0] && otherNear.cells[$0] && !other.cells[$0] }
        guard targetSide.count >= minCells else { return .beside }
        let values = depth()
        guard values.count == target.cells.count else { return .beside }
        let theirs = median(otherSide.map { values[$0] }), ours = median(targetSide.map { values[$0] })
        let delta = (theirs - ours) / span
        if delta > tuning.occlusionDepthTolerance { return .front(depth: (theirs + ours) / 2) }
        if delta < -tuning.occlusionDepthTolerance { return .behind }
        return .beside
    }

    private static func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
}

/// The edit region's growth, one radius per target and shot, so it cannot flicker from frame to frame.
enum EditRegion {
    /// Pixels by [shot, target]: the larger of `Tuning.editExtent` of the target's median box height in the shot
    /// (a full-body figure has more costume to fit than a face) and `Tuning.editMotion` of its typical box movement
    /// between consecutive frames (75th percentile, the motion blur the matte leaves out), clamped to
    /// `Tuning.maskDilation`…`Tuning.editMaxDilation` of the frame width.
    static func radii(
        _ perFrame: [[TargetMask]], shot: (Int) -> Int, size: CGSize, tuning: Tuning
    ) -> [[Int]: CGFloat] {
        var heights: [[Int]: [CGFloat]] = [:], motions: [[Int]: [CGFloat]] = [:]
        var last: [Int: (frame: Int, box: CGRect)] = [:]
        for (n, masks) in perFrame.enumerated() {
            for m in masks {
                let unit = m.grid.unitBox
                guard unit.width > 0 else { continue }
                let box = CGRect(
                    x: unit.minX * size.width, y: unit.minY * size.height, width: unit.width * size.width,
                    height: unit.height * size.height)
                let key = [shot(n), m.identity]
                heights[key, default: []].append(box.height)
                if let previous = last[m.identity], previous.frame == n - 1, shot(previous.frame) == shot(n) {
                    let p = previous.box
                    motions[key, default: []].append(
                        max(
                            abs(box.minX - p.minX), abs(box.maxX - p.maxX), abs(box.minY - p.minY),
                            abs(box.maxY - p.maxY)))
                }
                last[m.identity] = (n, box)
            }
        }
        let floor = minimum(size, tuning: tuning), ceiling = max(floor, size.width * tuning.editMaxDilation)
        var radii: [[Int]: CGFloat] = [:]
        for (key, list) in heights {
            let height = list.sorted()[list.count / 2]
            let moves = (motions[key] ?? []).sorted()
            let motion = moves.isEmpty ? 0 : moves[moves.count * 3 / 4]
            radii[key] = min(ceiling, max(floor, tuning.editExtent * height, tuning.editMotion * motion))
        }
        return radii
    }

    /// The growth of `mask.mp4` and the least the edit region grows: `Tuning.maskDilation` of the width.
    static func minimum(_ size: CGSize, tuning: Tuning) -> CGFloat { max(1, size.width * tuning.maskDilation) }
}

extension MaskGrid {
    /// The grid grown by `cells` in every direction (a square of side 2 · cells + 1), rows and columns separately.
    func dilated(by cells: Int) -> MaskGrid {
        guard cells > 0 else { return self }
        let s = side
        var rows = [Bool](repeating: false, count: s * s)
        for y in 0..<s {
            for x in 0..<s where self.cells[y * s + x] {
                for i in max(0, x - cells)...min(s - 1, x + cells) { rows[y * s + i] = true }
            }
        }
        var out = [Bool](repeating: false, count: s * s)
        for y in 0..<s {
            for x in 0..<s where rows[y * s + x] {
                for j in max(0, y - cells)...min(s - 1, y + cells) { out[j * s + x] = true }
            }
        }
        return MaskGrid(side: s, cells: out)
    }
}
