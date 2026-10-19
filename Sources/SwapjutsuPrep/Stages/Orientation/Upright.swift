import CoreImage
import ImageIO

/// How a shot's pixels turn upright. A selfie filmed with the phone sideways can be saved with its pixels turned a
/// quarter and no rotation tag (`VideoSource` applies the tags it finds), so the people lie on their side. Vision's
/// person masks and identity prints are made for people standing up: on such a shot the same person splits into
/// several identities and the target goes unpainted. The people, tracking and depth passes run on the shot turned
/// upright and map what they find back, so every output keeps the source's frame.
public struct Upright: Sendable, Equatable {
    /// Clockwise degrees that stand the shot upright: 0, 90, 180 or 270.
    public let degrees: Int
    /// The source frame's size; frames have their origin at zero.
    public let size: CGSize

    public init(degrees: Int, size: CGSize) {
        self.degrees = ((degrees % 360 + 360) % 360) / 90 * 90
        self.size = size
    }

    public var isTurned: Bool { degrees != 0 }

    /// The upright frame's size: a quarter turn swaps the sides.
    public var uprightSize: CGSize { degrees % 180 == 0 ? size : CGSize(width: size.height, height: size.width) }

    /// Source pixels (bottom-left origin) → upright pixels.
    public var toUpright: CGAffineTransform {
        let w = size.width, h = size.height
        switch degrees {
        case 90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }

    /// Upright pixels → source pixels.
    public var toSource: CGAffineTransform { toUpright.inverted() }

    /// The orientation Vision is told a source frame has, so that its results come in upright coordinates.
    public var vision: CGImagePropertyOrientation {
        switch degrees {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// A source frame turned upright.
    public func upright(_ frame: CIImage) -> CIImage {
        guard isTurned else { return frame }
        return frame.transformed(by: toUpright).cropped(to: CGRect(origin: .zero, size: uprightSize))
    }

    /// An upright frame (or a mask on it) turned back into the source's frame.
    public func source(_ image: CIImage) -> CIImage {
        guard isTurned else { return image }
        return image.transformed(by: toSource).cropped(to: CGRect(origin: .zero, size: size))
    }

    public func source(_ point: CGPoint) -> CGPoint { isTurned ? point.applying(toSource) : point }

    /// An upright rectangle in pixels, in source pixels.
    public func source(_ rect: CGRect) -> CGRect { isTurned ? rect.applying(toSource) : rect }

    /// An upright rectangle in unit coordinates (Vision's, bottom-left origin), in the source's unit coordinates.
    public func source(unit rect: CGRect) -> CGRect {
        guard isTurned else { return rect }
        let up = uprightSize
        let pixels = CGRect(
            x: rect.minX * up.width, y: rect.minY * up.height, width: rect.width * up.width,
            height: rect.height * up.height)
        let back = source(pixels)
        return CGRect(
            x: back.minX / size.width, y: back.minY / size.height, width: back.width / size.width,
            height: back.height / size.height)
    }

    /// One-channel bytes with rows top-down, `size` wide and high, turned upright.
    public func upright(bytes: [UInt8]) -> [UInt8] { turn(bytes, from: size, degrees: degrees) }

    /// One-channel upright bytes with rows top-down turned back into the source's frame.
    public func source(bytes: [UInt8]) -> [UInt8] { turn(bytes, from: uprightSize, degrees: (360 - degrees) % 360) }

    /// A crop of the source frame (rows top-down) as the same pixels of the upright frame.
    public func upright(_ crop: TrackingCrop) -> TrackingCrop {
        guard isTurned else { return crop }
        let w = Int(size.width), h = Int(size.height)
        switch degrees {
        case 90: return TrackingCrop(x: h - crop.y - crop.height, y: crop.x, width: crop.height, height: crop.width)
        case 180:
            return TrackingCrop(
                x: w - crop.x - crop.width, y: h - crop.y - crop.height, width: crop.width, height: crop.height)
        default: return TrackingCrop(x: crop.y, y: w - crop.x - crop.width, width: crop.height, height: crop.width)
        }
    }

    /// A point in source pixels with rows top-down, in the upright frame's.
    public func upright(topDown point: CGPoint) -> CGPoint {
        guard isTurned else { return point }
        let w = size.width, h = size.height
        switch degrees {
        case 90: return CGPoint(x: h - point.y, y: point.x)
        case 180: return CGPoint(x: w - point.x, y: h - point.y)
        default: return CGPoint(x: point.y, y: w - point.x)
        }
    }
}

/// `bytes` (rows top-down, `size`) turned clockwise by `degrees`, a multiple of 90.
private func turn(_ bytes: [UInt8], from size: CGSize, degrees: Int) -> [UInt8] {
    let w = Int(size.width), h = Int(size.height)
    guard degrees != 0, bytes.count == w * h else { return bytes }
    var out = [UInt8](repeating: 0, count: bytes.count)
    bytes.withUnsafeBufferPointer { from in
        out.withUnsafeMutableBufferPointer { to in
            for y in 0..<h {
                for x in 0..<w {
                    let v = from[y * w + x]
                    switch degrees {
                    // Clockwise: the left column becomes the top row; the new frame is h wide.
                    case 90: to[x * h + (h - 1 - y)] = v
                    case 180: to[(h - 1 - y) * w + (w - 1 - x)] = v
                    default: to[(w - 1 - x) * h + y] = v
                    }
                }
            }
        }
    }
    return out
}

extension FaceLandmarks {
    /// The same polylines with every point moved by `place`.
    func mapped(_ place: (CGPoint) -> CGPoint) -> FaceLandmarks {
        FaceLandmarks(regions: regions.map { Region(name: $0.name, points: $0.points.map(place), closed: $0.closed) })
    }
}
