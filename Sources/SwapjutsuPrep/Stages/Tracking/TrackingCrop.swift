import CoreGraphics

/// The part of the frame the tracker sees of one target through one shot, in whole pixels with rows top-down (the
/// layout of mask bytes).
///
/// EdgeTAM reads a 1024² square, so a full portrait frame is squeezed and a full-body person gets few pixels. The crop
/// is the union of the target's boxes over the shot plus a margin, widened toward a square as far as the frame allows
/// and shifted back inside it. It stays fixed for the whole shot, so the tracker's spatial memory stays valid; where
/// the frame does not allow a square the rest is squeezed into 1024², as the full frame was.
public struct TrackingCrop: Hashable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    /// The crop around `boxes` (frame pixels, bottom-left origin, as `PersonDetection.box`) in a frame of `size`:
    /// their union grown by `margin` × its longer side on every side, widened to at least `minShare` × the frame's
    /// shorter side and toward a square, clamped to the frame. Nil without a non-empty box.
    public static func around(
        _ boxes: [CGRect], frame size: CGSize, margin: Double, minShare: Double
    ) -> TrackingCrop? {
        let boxes = boxes.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard let first = boxes.first, size.width >= 1, size.height >= 1 else { return nil }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        let pad = margin * max(union.width, union.height)
        let grown = union.insetBy(dx: -pad, dy: -pad)
        let side = max(grown.width, grown.height, minShare * min(size.width, size.height))
        let width = min(size.width, max(grown.width, side)), height = min(size.height, max(grown.height, side))
        let minX = min(max(0, grown.midX - width / 2), size.width - width)
        let minY = min(max(0, grown.midY - height / 2), size.height - height)
        // Outward to whole pixels, rows top-down.
        let x0 = Int(minX.rounded(.down)), x1 = min(Int(size.width), Int((minX + width).rounded(.up)))
        let top = Int((size.height - (minY + height)).rounded(.down))
        let bottom = min(Int(size.height), Int((size.height - minY).rounded(.up)))
        return TrackingCrop(x: max(0, x0), y: max(0, top), width: x1 - max(0, x0), height: bottom - max(0, top))
    }

    /// The crop in Core Image coordinates (bottom-left origin) of a frame `height` pixels tall.
    public func imageRect(frameHeight height: Int) -> CGRect {
        CGRect(x: x, y: height - y - self.height, width: width, height: self.height)
    }

    /// Whether the crop lies inside a `width` × `height` frame.
    public func fits(width: Int, height: Int) -> Bool {
        x >= 0 && y >= 0 && self.width > 0 && self.height > 0 && x + self.width <= width && y + self.height <= height
    }

    /// The crop's pixels of a frame-sized mask (`frameWidth` wide, rows top-down).
    public func cut(_ mask: [UInt8], frameWidth: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let from = (y + row) * frameWidth + x
            out.replaceSubrange((row * width)..<((row + 1) * width), with: mask[from..<(from + width)])
        }
        return out
    }

    /// A crop-sized mask back in a `frameWidth` × `frameHeight` frame; outside the crop is empty.
    public func place(_ mask: [UInt8], frameWidth: Int, frameHeight: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frameWidth * frameHeight)
        // Row copies through pointers: `replaceSubrange` on slices took over 1 ms a 960² mask in Debug builds.
        mask.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                guard let from = m.baseAddress, let to = o.baseAddress else { return }
                for row in 0..<height {
                    (to + (y + row) * frameWidth + x).update(from: from + row * width, count: width)
                }
            }
        }
        return out
    }
}
