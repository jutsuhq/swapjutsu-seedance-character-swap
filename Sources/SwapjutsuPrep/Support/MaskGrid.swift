import CoreImage

/// A coarse boolean occupancy grid of a mask, for IoU and bounding boxes without touching full-size pixels.
public struct MaskGrid: Sendable, Equatable {
    public let side: Int
    public let cells: [Bool]

    public init(side: Int, cells: [Bool]) {
        precondition(cells.count == side * side, "cells must be side × side")
        self.side = side
        self.cells = cells
    }

    public init(mask: CIImage, side: Int, context: CIContext) {
        let pixels = renderRGBA(mask, width: side, height: side, context: context)
        self.init(side: side, cells: (0..<(side * side)).map { pixels[$0 * 4] > 127 })
    }

    /// The grid of frame-sized mask bytes (rows top-down, inside where > 127), sampled as a mask image is.
    public init(bytes: [UInt8], width: Int, height: Int, side: Int, context: CIContext) {
        let image = CIImage(
            bitmapData: Data(bytes), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8,
            colorSpace: nil)
        self.init(mask: image, side: side, context: context)
    }

    public var area: Int { cells.reduce(0) { $0 + ($1 ? 1 : 0) } }
    public var areaShare: Double { Double(area) / Double(cells.count) }

    public func iou(_ other: MaskGrid) -> Double {
        var intersection = 0, union = 0
        for k in cells.indices {
            if cells[k] && other.cells[k] { intersection += 1 }
            if cells[k] || other.cells[k] { union += 1 }
        }
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    /// Bounding box in unit coordinates with a bottom-left origin (Core Image and Vision convention).
    public var unitBox: CGRect {
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where cells[y * side + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return .zero }
        let s = Double(side)
        // Grid rows are top-down.
        return CGRect(
            x: Double(minX) / s, y: 1 - Double(maxY + 1) / s,
            width: Double(maxX - minX + 1) / s, height: Double(maxY - minY + 1) / s)
    }
}
