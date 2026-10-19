import AVFoundation
import SwiftUI

/// Still frames of a video file, for the trim strip and grid thumbnails.
enum VideoFrames {
    /// `count` frames spread evenly over the clip; the ones that can't be read are left out.
    static func images(
        for url: URL, count: Int, maxSize: CGSize = CGSize(width: 320, height: 320)
    ) async
        -> [CGImage]
    {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        var images: [CGImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { images.append(image) }
        }
        return images
    }
}

/// One frame from the middle of a video, filling its frame; it loads off the main thread and keeps the slot dark
/// until then.
struct VideoStill: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        Theme.well
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                image = await VideoFrames.images(for: url, count: 1, maxSize: CGSize(width: 640, height: 640)).first
            }
    }
}
