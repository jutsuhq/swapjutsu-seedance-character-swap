import CoreImage

/// Share of `inner` covered by `outer`.
func overlap(_ outer: CGRect, _ inner: CGRect) -> Double {
    let i = outer.intersection(inner)
    guard !i.isNull, inner.width * inner.height > 0 else { return 0 }
    return Double(i.width * i.height / (inner.width * inner.height))
}

func fit(_ image: CIImage, to extent: CGRect) -> CIImage {
    image.transformed(
        by: CGAffineTransform(scaleX: extent.width / image.extent.width, y: extent.height / image.extent.height))
}

/// RGBA8 pixels of `image` scaled to `width` × `height`, rows top-down.
func renderRGBA(_ image: CIImage, width: Int, height: Int, context: CIContext) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let e = image.extent
    let fitted =
        image
        .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / e.width, y: CGFloat(height) / e.height))
    context.render(
        fitted, toBitmap: &buffer, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
        format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    return buffer
}
