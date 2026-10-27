import AVFoundation
import SwapjutsuAgent

/// frames: the same moments of a finished render, its clip (`prepared.mp4`) and `control.mp4`, side by side. Each
/// call writes a folder of its own in the clip's folder, so an earlier sheet is never overwritten.
extension AgentCommands {
    func frames(_ command: FramesCommand) async throws(AgentError) -> AgentResponse {
        let (job, render) = try findRender(command.render)
        guard render.stage == .done, let result = job.resultURL(of: render) else {
            throw .invalid("\(job.name(of: render)) is \(render.stage.rawValue); frames needs a finished render.")
        }
        guard let duration = job.duration, duration > 0 else { throw .notPrepared(job) }
        let times = try Self.times(command, duration: duration)
        let folder = job.output.appending(path: "frames/\(render.id.uuidString.prefix(8))-\(UUID().uuidString.prefix(8))")
        let videos = [job.prepared, job.control, result]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var rows: [[CGImage]] = []
            var frames: [AgentFrame] = []
            for seconds in times {
                var row: [CGImage] = []
                for video in videos { row.append(try await Self.frame(of: video, at: seconds)) }
                let stamp = String(format: "%06.2f", seconds)
                let files = try zip(AgentFrames.columns, row).map { column, image in
                    let file = folder.appending(path: "\(stamp)-\(column).jpg")
                    try JobFiles.writeJPEG(image, to: file)
                    return file.path(percentEncoded: false)
                }
                rows.append(row)
                frames.append(AgentFrame(seconds: seconds, source: files[0], control: files[1], render: files[2]))
            }
            let sheet = folder.appending(path: "sheet.jpg")
            try JobFiles.writeJPEG(try Self.sheet(rows), to: sheet)
            return AgentResponse(
                frames: AgentFrames(
                    render: command.render, folder: folder.path(percentEncoded: false),
                    sheet: sheet.path(percentEncoded: false), frames: frames))
        } catch {
            throw AgentError(
                .badRequest, message: "The frames couldn't be written: \(error.localizedDescription)",
                retryable: false, next: "Check in Library that the render still plays.")
        }
    }

    /// The agent's times, or `count` spread evenly over the clip, each at the middle of its share.
    static func times(_ command: FramesCommand, duration: Double) throws(AgentError) -> [Double] {
        if let seconds = command.seconds {
            guard (1...FramesCommand.maxCount).contains(seconds.count),
                seconds.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < duration })
            else {
                throw .invalid(
                    "seconds takes 1–\(FramesCommand.maxCount) times from 0 to under the clip's "
                        + "\(String(format: "%.2f", duration)) s.")
            }
            return seconds
        }
        let count = command.count ?? FramesCommand.defaultCount
        guard (1...FramesCommand.maxCount).contains(count) else {
            throw .invalid("count is 1–\(FramesCommand.maxCount).")
        }
        return (0..<count).map { (duration * (Double($0) + 0.5) / Double(count) * 100).rounded() / 100 }
    }

    /// The frame shown at `seconds`, not the nearest keyframe, at no more than 1024 px a side.
    private static func frame(of video: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The rows one under the other, each image scaled to the same height and kept in its own shape, on dark grey.
    static func sheet(_ rows: [[CGImage]], height: Int = 360, gap: Int = 8) throws -> CGImage {
        let widths = rows.map { row in row.map { $0.width * height / max(1, $0.height) } }
        let width = (widths.map { $0.reduce(0, +) + gap * ($0.count + 1) }.max() ?? 0)
        let total = rows.count * height + gap * (rows.count + 1)
        guard width > 0,
            let context = CGContext(
                data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(gray: 0.12, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: total))
        context.interpolationQuality = .high
        for (r, row) in rows.enumerated() {
            // Core Graphics counts from the bottom; the first row goes on top.
            let y = total - (r + 1) * (height + gap)
            var x = gap
            for (c, image) in row.enumerated() {
                context.draw(image, in: CGRect(x: x, y: y, width: widths[r][c], height: height))
                x += widths[r][c] + gap
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
