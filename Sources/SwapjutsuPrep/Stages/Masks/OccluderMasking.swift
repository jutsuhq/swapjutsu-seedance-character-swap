import Accelerate
import CoreImage

// Object occluders found automatically (#56): a steering wheel, a microphone, a press camera, a seat in front of
// the target. People in front are handled by `Occlusion`; this covers everything that is not a person.

/// One frame as the control render sees it, for a `ForegroundMasking` that finds occluders itself. All masks are
/// frame-sized, white = inside.
public struct ForegroundFrame {
    public let index: Int
    /// The targets' tracked mattes.
    public let targets: [CIImage]
    /// Vision's mask of every person on the frame, the targets' own detections included.
    public let people: [CIImage]
    /// Depth placed on the frame, larger = nearer; its extent is the frame's.
    public let depth: CIImage
    /// The widest edit-region growth of the targets on this frame, in pixels.
    public let editRadius: CGFloat
    /// Same shot as the frame before: what was in front there may carry over.
    public let continues: Bool

    public init(
        index: Int, targets: [CIImage], people: [CIImage], depth: CIImage, editRadius: CGFloat, continues: Bool
    ) {
        self.index = index
        self.targets = targets
        self.people = people
        self.depth = depth
        self.editRadius = editRadius
        self.continues = continues
    }
}

extension ForegroundMasking {
    /// A mask that needs only the frame number (a prompted one, #58) ignores the rest.
    public func protectedMask(_ frame: ForegroundFrame) throws -> CIImage? {
        try protectedMask(frame: frame.index, size: frame.depth.extent.size)
    }
}

/// Settings of `OccluderMasking`.
public struct OccluderTuning: Sendable {
    /// Off keeps the control video as before: only other people are protected.
    public var enabled = true
    /// The analysis grid's longest side, in cells (4 px on a 960 px frame).
    public var gridSide = 240
    /// A candidate smaller than this share of the target's own cells is a speck at the matte edge.
    public var minArea = 0.004
    /// An occluder's median depth is nearer than the target's body around it by this share of the target's depth
    /// spread (2nd–98th percentile on the frame).
    public var depthTolerance: Float = 0.15
    /// The body around a candidate: the target's cells within this many grid cells of it, at least `minBandCells`.
    public var band = 4
    public var minBandCells = 12
    /// A candidate is protected from the second frame in a row it shows up on: this share of its cells must have
    /// been a candidate on the frame before, so a one-frame call cannot flash.
    public var persistence = 0.3
    /// Soft step of the full-resolution depth test, as a share of the target's depth spread.
    public var ramp: Float = 0.05

    public init() {}
}

/// Finds the objects in front of the target without a click: pixels inside the target's edit region that Vision
/// does not count as any person, and that are nearer than the target's body next to them. The tracker often takes
/// such an object for part of the person (a steering wheel between the hands, a camera in front of the chest, a seat
/// back), and the edit region's growth fills holes the object cuts into the silhouette (an arm behind a mic stand);
/// both would be painted with depth and replaced. Kept pixels keep the background, as people in front do: the
/// original frame, or its grey depth when the background is replaced (#89), since the object belongs to the old scene.
///
/// The work is on a coarse grid (`OccluderTuning.gridSide`): candidates are opened by one cell, split into
/// connected components, and each is kept when it is large enough, its median depth is in front of the target's own
/// cells in a band around it, and it was a candidate on the frame before. The kept cells, grown by one cell, are
/// then cut at full resolution by Vision's person matte and the depth test, so the edge follows the object and
/// never takes the target's hand.
///
/// Called once per frame, in order, from one task; it keeps the previous frame's candidates.
public final class OccluderMasking: ForegroundMasking {
    let tuning: OccluderTuning
    let context: CIContext
    private var previous: CellGrid?
    /// Share of the frame kept on the last frame, for logs and benchmarks.
    public private(set) var lastShare = 0.0

    public init(tuning: OccluderTuning, context: CIContext) {
        self.tuning = tuning
        self.context = context
    }

    public func protectedMask(frame: Int, size: CGSize) throws -> CIImage? { nil }

    public func protectedMask(_ frame: ForegroundFrame) throws -> CIImage? {
        lastShare = 0
        let extent = frame.depth.extent
        guard tuning.enabled, let targets = unionImage(frame.targets), extent.width > 0, extent.height > 0 else {
            previous = nil
            return nil
        }
        let scale = CGFloat(tuning.gridSide) / max(extent.width, extent.height)
        let w = max(8, Int((extent.width * scale).rounded())), h = max(8, Int((extent.height * scale).rounded()))
        let people = unionImage(frame.people)
        let notPeople = people?.applyingFilter("CIColorInvert") ?? CIImage(color: .white).cropped(to: extent)
        let target = sample(targets, w, h), depth = sample(frame.depth, w, h)
        let person = people.map { sample($0, w, h) } ?? [Float](repeating: 0, count: w * h)
        // The target's own body: tracked and a person to Vision.
        var body = CellGrid(w: w, h: h)
        var bodyDepth: [Float] = []
        for k in 0..<(w * h) where target[k] > 0.5 && person[k] > 0.5 {
            body.cells[k] = true
            bodyDepth.append(depth[k])
        }
        guard let stats = OccluderCells.Stats(bodyDepth, tuning: tuning) else {
            previous = nil
            return nil
        }
        // Candidates on the GPU: inside the edit region, not a person, nearer than the body's median; then opened by
        // one cell on the grid (the frame edge counts as inside).
        let region = targets.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: frame.editRadius])
        let raw = multiply(multiply(region, notPeople), nearer(frame.depth, stats.median, stats.spread * 1e-3))
            .cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 1])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1])
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let found = OccluderCells.find(
            candidates: CellGrid(w: w, h: h, values: sample(raw, w, h)), body: body, depth: depth, stats: stats,
            previous: frame.continues ? previous : nil, tuning: tuning)
        previous = found.candidates
        guard let kept = found.kept, let reference = found.reference else { return nil }
        lastShare = Double(kept.count) / Double(w * h)
        // Grid → frame, grown by a cell so the full-resolution cut decides the edge.
        let grid = CGRect(x: 0, y: 0, width: w, height: h)
        let coarse = CIImage(
            bitmapData: Data(kept.cells.map { $0 ? 255 : 0 }), bytesPerRow: w, size: grid.size, format: .L8,
            colorSpace: nil
        )
        .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1])
        .cropped(to: grid)
        .samplingLinear()
        .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
        .cropped(to: extent)
        var mask = multiply(coarse, nearer(frame.depth, reference.threshold, reference.ramp))
        if let people { mask = multiply(mask, people.applyingFilter("CIColorInvert")) }
        return mask.cropped(to: extent)
    }

    /// One channel of `image` at `w` × `h`, rows top-down.
    private func sample(_ image: CIImage, _ w: Int, _ h: Int) -> [Float] {
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let e = image.extent
        let fitted =
            image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        context.render(
            fitted, toBitmap: &pixels, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBAf, colorSpace: nil)
        return (0..<(w * h)).map { pixels[$0 * 4] }
    }

    private func unionImage(_ masks: [CIImage]) -> CIImage? {
        guard var union = masks.first else { return nil }
        for mask in masks.dropFirst() {
            union = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: union])
        }
        return union
    }

    private func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    /// 1 where `depth` is nearer than `threshold` by `ramp` or more, 0 where it is not nearer.
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
}

/// The grid part of `OccluderMasking`, on plain arrays so it can be tested without images.
enum OccluderCells {
    struct Result {
        /// This frame's candidates that passed the size and depth tests, for the next frame's persistence check.
        let candidates: CellGrid
        /// The protected cells, nil when there are none.
        let kept: CellGrid?
        /// The full-resolution depth test: nearer than `threshold`, with a soft step `ramp` wide.
        let reference: (threshold: Float, ramp: Float)?
    }

    /// The target body's depth on this frame: its median and its 2nd–98th percentile spread.
    struct Stats {
        let median: Float
        let spread: Float

        init?(_ values: [Float], tuning: OccluderTuning) {
            guard values.count >= max(16, tuning.minBandCells) else { return nil }
            var sorted = values
            vDSP.sort(&sorted, sortOrder: .ascending)
            median = sorted[sorted.count / 2]
            spread = max(sorted[sorted.count * 98 / 100] - sorted[sorted.count * 2 / 100], 1e-3)
        }
    }

    /// - Parameters:
    ///   - candidates: cells in the edit region that are no person and nearer than the body's median, opened.
    ///   - body: the target's own cells (tracked and a person); `depth`: larger = nearer; all the same size.
    static func find(
        candidates opened: CellGrid, body: CellGrid, depth: [Float], stats: Stats, previous: CellGrid?,
        tuning: OccluderTuning
    ) -> Result {
        let w = opened.w, h = opened.h
        var candidates = CellGrid(w: w, h: h), kept = CellGrid(w: w, h: h)
        var keptDepths: [Float] = []
        let minCells = max(4, Int(tuning.minArea * Double(body.count)))
        for component in opened.components() where component.count >= minCells {
            let neighbours = body.cells(around: component, within: tuning.band)
            guard neighbours.count >= tuning.minBandCells else { continue }
            let theirs = middle(component.map { depth[$0] }), ours = middle(neighbours.map { depth[$0] })
            guard (theirs - ours) / stats.spread > tuning.depthTolerance else { continue }
            for k in component { candidates.cells[k] = true }
            let carried = previous.map { p in component.filter { p.cells[$0] }.count } ?? 0
            guard Double(carried) >= tuning.persistence * Double(component.count) else { continue }
            for k in component { kept.cells[k] = true }
            keptDepths.append(ours)
        }
        guard let nearest = keptDepths.min() else { return Result(candidates: candidates, kept: nil, reference: nil) }
        // Full resolution: nearer than the body next to the occluders, a step's width in front of it.
        let ramp = tuning.ramp * stats.spread
        return Result(candidates: candidates, kept: kept, reference: (nearest + ramp, ramp))
    }

    private static func middle(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
}

/// A boolean grid of any aspect, rows top-down.
struct CellGrid: Equatable {
    let w: Int
    let h: Int
    var cells: [Bool]

    init(w: Int, h: Int, cells: [Bool]? = nil) {
        self.w = w
        self.h = h
        self.cells = cells ?? [Bool](repeating: false, count: w * h)
    }

    /// Inside where `values` > 0.5.
    init(w: Int, h: Int, values: [Float]) { self.init(w: w, h: h, cells: values.map { $0 > 0.5 }) }

    var count: Int { cells.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Grown by `r` cells in every direction (a square), rows and columns separately.
    func dilated(by r: Int) -> CellGrid { morph(r, grow: true) }

    /// Shrunk by `r` cells: a cell stays when the whole square around it is inside (the frame edge counts as inside).
    func eroded(by r: Int) -> CellGrid { morph(r, grow: false) }

    private func morph(_ r: Int, grow: Bool) -> CellGrid {
        guard r > 0 else { return self }
        let rows = Self.pass(cells, w: w, h: h, r: r, grow: grow, horizontal: true)
        return CellGrid(w: w, h: h, cells: Self.pass(rows, w: w, h: h, r: r, grow: grow, horizontal: false))
    }

    /// One direction of a square morphology: a running count over each row or column, so the cost does not grow
    /// with `r`.
    private static func pass(_ input: [Bool], w: Int, h: Int, r: Int, grow: Bool, horizontal: Bool) -> [Bool] {
        var out = [Bool](repeating: false, count: w * h)
        let (lines, length, step) = horizontal ? (h, w, 1) : (w, h, w)
        var prefix = [Int](repeating: 0, count: length + 1)
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                prefix.withUnsafeMutableBufferPointer { p in
                    for line in 0..<lines {
                        let base = horizontal ? line * w : line
                        for i in 0..<length { p[i + 1] = p[i] + (src[base + i * step] ? 1 : 0) }
                        for i in 0..<length {
                            let lo = max(0, i - r), hi = min(length - 1, i + r)
                            let n = p[hi + 1] - p[lo]
                            dst[base + i * step] = grow ? n > 0 : n == hi - lo + 1
                        }
                    }
                }
            }
        }
        return out
    }

    /// This grid's cells within `r` cells of `component` (cell indices) and not in it, found in its bounding box.
    func cells(around component: [Int], within r: Int) -> [Int] {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for k in component {
            let x = k % w, y = k / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return [] }
        let x0 = max(0, minX - r), y0 = max(0, minY - r), x1 = min(w - 1, maxX + r), y1 = min(h - 1, maxY + r)
        let lw = x1 - x0 + 1, lh = y1 - y0 + 1
        var local = CellGrid(w: lw, h: lh)
        for k in component { local.cells[(k / w - y0) * lw + (k % w - x0)] = true }
        let near = local.dilated(by: r)
        var result: [Int] = []
        for y in 0..<lh {
            for x in 0..<lw where near.cells[y * lw + x] && !local.cells[y * lw + x] {
                let k = (y + y0) * w + x + x0
                if cells[k] { result.append(k) }
            }
        }
        return result
    }

    /// The 4-connected components, as cell indices.
    func components() -> [[Int]] {
        var seen = [Bool](repeating: false, count: cells.count)
        var result: [[Int]] = []
        var stack: [Int] = []
        for start in cells.indices where cells[start] && !seen[start] {
            var component: [Int] = []
            seen[start] = true
            stack.append(start)
            while let k = stack.popLast() {
                component.append(k)
                let x = k % w
                if x > 0, cells[k - 1], !seen[k - 1] { seen[k - 1] = true; stack.append(k - 1) }
                if x < w - 1, cells[k + 1], !seen[k + 1] { seen[k + 1] = true; stack.append(k + 1) }
                if k >= w, cells[k - w], !seen[k - w] { seen[k - w] = true; stack.append(k - w) }
                if k + w < cells.count, cells[k + w], !seen[k + w] { seen[k + w] = true; stack.append(k + w) }
            }
            result.append(component)
        }
        return result
    }
}
