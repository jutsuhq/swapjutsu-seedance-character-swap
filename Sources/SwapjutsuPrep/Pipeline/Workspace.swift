import CoreImage
import Foundation

/// Scratch files of one run, under `<output>/work`; removed when the run finishes.
struct Workspace {
    let output: URL
    var root: URL { output.appendingPathComponent("work") }
    var depth: DepthCache { DepthCache(directory: root.appendingPathComponent("depth")) }
    var masks: MaskCache { MaskCache(directory: root.appendingPathComponent("masks")) }

    func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    func create() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: masks.directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: depth.directory, withIntermediateDirectories: true)
        try fm.createDirectory(at: output.appendingPathComponent("identities"), withIntermediateDirectories: true)
    }
}

/// Person masks kept between the passes as 8-bit frames compressed with LZ4: a mask is mostly zeros, so a 960 × 540
/// frame shrinks from 0.5 MB to a few kilobytes, and LZ4 runs at memory speed, well ahead of a PNG encode.
struct MaskCache {
    let directory: URL

    func store(_ mask: CIImage, key: String, context: CIContext) throws {
        let w = Int(mask.extent.width), h = Int(mask.extent.height)
        var bytes = Data(count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                mask, toBitmap: base, rowBytes: w, bounds: mask.extent, format: .L8, colorSpace: nil)
        }
        try store(bytes, key: key)
    }

    /// One-channel bytes, rows top-down.
    func store(_ bytes: Data, key: String) throws {
        try (bytes as NSData).compressed(using: .lz4).write(to: url(key))
    }

    /// The mask as a frame-sized one-channel image. A missing or truncated file throws: a target dropped from a
    /// broken cache would silently stay unreplaced.
    func load(key: String, size: CGSize) throws -> CIImage {
        CIImage(
            bitmapData: try bytes(key: key, size: size), bytesPerRow: Int(size.width), size: size, format: .L8,
            colorSpace: nil)
    }

    /// The mask's bytes, rows top-down.
    func bytes(key: String, size: CGSize) throws -> Data {
        let data: Data
        do { data = try (NSData(contentsOf: url(key)).decompressed(using: .lz4)) as Data } catch {
            throw PrepError.readFailed("mask cache \(key): \(error.localizedDescription)")
        }
        guard data.count == Int(size.width) * Int(size.height) else {
            throw PrepError.readFailed("mask cache \(key) has \(data.count) bytes")
        }
        return data
    }

    private func url(_ key: String) -> URL { directory.appendingPathComponent("\(key).l8") }
}
