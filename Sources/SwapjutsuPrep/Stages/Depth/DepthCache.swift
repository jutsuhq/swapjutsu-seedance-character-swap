import CoreImage

/// Raw depth maps kept on disk between the two passes, so the depth model runs once per frame. Half or single float,
/// as the estimator returns it.
struct DepthCache {
    let directory: URL

    func store(_ map: DepthMap, frame: Int) throws { try store(map, name: "\(frame)") }

    /// A person's crop, keyed like the mask cache.
    func store(_ map: DepthMap, crop key: String) throws { try store(map, name: "\(key).crop") }

    /// A frame's smoothed final depth (#17): half floats at the frame size, rows top-down.
    func store(smoothed half: Data, frame: Int) throws { try half.write(to: url("\(frame).smooth")) }

    func load(smoothed frame: Int, size: CGSize) throws -> CIImage {
        try load(name: "\(frame).smooth", size: size, format: .half)
    }

    func load(frame: Int, size: CGSize, format: DepthFormat = .half) throws -> CIImage {
        try load(name: "\(frame)", size: size, format: format)
    }

    func load(crop key: String, size: CGSize, format: DepthFormat) throws -> CIImage {
        try load(name: "\(key).crop", size: size, format: format)
    }

    private func store(_ map: DepthMap, name: String) throws {
        let buffer = map.buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), let format = DepthFormat(buffer) else {
            throw PrepError.model("unreadable depth buffer")
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer), packed = w * format.bytes
        var data = Data(capacity: packed * h)
        for y in 0..<h { data.append(base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self), count: packed) }
        try data.write(to: url(name))
    }

    /// The stored map as a one-channel image of `size` (model resolution). A missing or truncated file throws: a
    /// target painted from a broken cache would silently stay unreplaced.
    private func load(name: String, size: CGSize, format: DepthFormat) throws -> CIImage {
        let data: Data
        do { data = try Data(contentsOf: url(name)) } catch {
            throw PrepError.readFailed("depth cache \(name): \(error.localizedDescription)")
        }
        let row = Int(size.width) * format.bytes, expected = row * Int(size.height)
        guard data.count == expected else {
            throw PrepError.readFailed("depth cache \(name) has \(data.count) bytes, expected \(expected)")
        }
        return CIImage(bitmapData: data, bytesPerRow: row, size: size, format: format.ciFormat, colorSpace: nil)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).depth") }
}

/// The one-channel float layouts a depth estimator may return.
enum DepthFormat: Sendable {
    case half, single

    init?(_ buffer: CVPixelBuffer) {
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16,
            kCVPixelFormatType_DisparityFloat16:
            self = .half
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32,
            kCVPixelFormatType_DisparityFloat32:
            self = .single
        default: return nil
        }
    }

    var bytes: Int { self == .half ? 2 : 4 }
    var ciFormat: CIFormat { self == .half ? .Rh : .Rf }
}
