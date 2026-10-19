import AVFoundation
import Foundation
import ImageIO
import SwapjutsuPrep
import UniformTypeIdentifiers

extension DescribeInput {
    /// The input for `video`: `PoseBeats` timed on it, and its keyframes (`PoseBeats.keyframeTimes`) written into
    /// `folder` as JPEGs, at most `maxSide` pixels, named by their time.
    public static func make(
        video: URL, characters: [URL], location: URL?, folder: URL, maxSide: CGFloat = 768
    ) async throws -> DescribeInput {
        let beats = try await PoseBeats.analyse(video: video)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        var keyframes: [Keyframe] = []
        for time in beats.keyframeTimes(duration: beats.duration) {
            let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let url = folder.appending(path: String(format: "%05.2f.jpg", time))
            guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(out) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            keyframes.append(Keyframe(time: time, image: url))
        }
        return DescribeInput(
            characters: characters, location: location, keyframes: keyframes, beats: beats.lines,
            seconds: beats.duration, framing: beats.framing?.label)
    }
}
