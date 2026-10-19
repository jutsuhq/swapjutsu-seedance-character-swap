import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A person's fix of one target on one frame (#58): a click on the target, or a painted mask. The prep re-tracks the
/// target's shot both ways from it (`CorrectedTracking`) instead of from Vision's seed.
///
/// Corrections live in the prep folder (`corrections.json`, mask PNGs under `corrections/`), not in the prep's
/// options, so a prep run again into the same folder applies them again. Frames are the prep's working frames
/// (`prepared.mp4`, decoded from 0), identities the manifest's.
public struct TargetCorrection: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Codable, Sendable, Equatable {
        /// One positive click: x and y as shares of the frame's width and height, from the top left. EdgeTAM's
        /// initializer turns it into the frame's mask. Negative clicks and more than one point need #19.
        case point(x: Double, y: Double)
        /// A painted mask: a PNG at `file` relative to the prep folder, inside where it is light.
        case mask(file: String)
    }

    public var id: UUID
    /// The shot the frame was in when the person made it; the prep goes by `frame`.
    public let shot: Int
    public let frame: Int
    public let identity: Int
    public let kind: Kind

    public init(id: UUID = UUID(), shot: Int, frame: Int, identity: Int, kind: Kind) {
        (self.id, self.shot, self.frame, self.identity, self.kind) = (id, shot, frame, identity, kind)
    }
}

/// The corrections of a prep folder.
public enum TargetCorrections {
    public static let file = "corrections.json"
    public static let folder = "corrections"

    /// The folder's corrections in the order they were made; none without the file.
    public static func load(from prep: URL) throws -> [TargetCorrection] {
        let url = prep.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
        return try JSONDecoder().decode([TargetCorrection].self, from: Data(contentsOf: url))
    }

    /// Writes the list, or removes the file when it is empty.
    public static func save(_ corrections: [TargetCorrection], to prep: URL) throws {
        let url = prep.appending(path: file)
        guard !corrections.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(corrections).write(to: url, options: .atomic)
    }

    /// Stores frame-sized mask bytes (rows top-down, inside where > 127) as a PNG under `corrections/`; returns the
    /// path for `Kind.mask`.
    public static func storeMask(_ bytes: [UInt8], width: Int, height: Int, in prep: URL, name: String) throws
        -> String
    {
        let relative = "\(folder)/\(name).png"
        let url = prep.appending(path: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let binary = bytes.map { $0 > 127 ? UInt8(255) : 0 }
        guard let provider = CGDataProvider(data: Data(binary) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw PrepError.model("cannot write correction mask \(relative)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PrepError.model("cannot write \(relative)") }
        return relative
    }

    /// A mask image (any PNG or JPEG, scaled to the frame if its size differs) as frame-sized bytes, rows top-down,
    /// 255 inside (light) and 0 outside.
    public static func maskBytes(_ url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PrepError.readFailed("correction mask \(url.lastPathComponent)") }
        var gray = [UInt8](repeating: 0, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw PrepError.readFailed("correction mask \(url.lastPathComponent)") }
        return gray.map { $0 > 127 ? 255 : 0 }
    }
}
