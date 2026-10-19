import AVFoundation
import ComfyKit
import CoreImage
import Foundation

/// Settings › Own ComfyUI: a ComfyUI the person runs (on this Mac, another Mac, a GPU box on the network)
/// that renders Wan 2.2 Animate. The app only talks to it over its API; nothing of it is bundled. The token, for a
/// ComfyUI behind a reverse proxy, is in the Keychain (`Credentials.ownComfyToken`).
enum OwnComfy {
    static let enabledKey = "ownComfy.enabled"
    static let urlKey = "ownComfy.url"
    static let diffusionKey = "ownComfy.diffusionModel"
    /// The address whose Check found every node and model Wan 2.2 Animate needs; cleared when the address or the token
    /// changes, so Create offers Wan only for a server that passed.
    static let checkedKey = "ownComfy.checked"
    static let defaultURL = ComfyUIClient.local.absoluteString

    /// The server new Wan renders go to, nil while the section is off or the address isn't an http(s) URL.
    static var url: URL? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey) else { return nil }
        return parse(defaults.string(forKey: urlKey) ?? defaultURL)
    }

    /// Whether Create offers Wan 2.2 Animate: the section is on, the address is valid and Check passed for it.
    static func isReady(enabled: Bool, address: String, checked: String) -> Bool {
        guard enabled, let url = parse(address) else { return false }
        return checked == url.absoluteString
    }

    /// `isReady` from the saved settings: what agents are offered, the same as Create.
    static var offersWan: Bool {
        let defaults = UserDefaults.standard
        return isReady(
            enabled: defaults.bool(forKey: enabledKey), address: defaults.string(forKey: urlKey) ?? defaultURL,
            checked: defaults.string(forKey: checkedKey) ?? "")
    }

    /// The diffusion model the person picked from what Check found; the template's FP8 until then.
    static var diffusionModel: String {
        UserDefaults.standard.string(forKey: diffusionKey).flatMap { $0.isEmpty ? nil : $0 } ?? WanModels.fp8
    }

    /// "192.168.1.20:8188" or "http://gpu.local:8188/" as a base URL; nil for anything that isn't http(s) with a host.
    static func parse(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty
        else { return nil }
        // A base URL, so `/prompt` resolves under a reverse proxy's path prefix too.
        if !components.path.hasSuffix("/") { components.path += "/" }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

extension OwnComfy {
    /// Whether App Transport Security refuses plain http to `url` in the app bundle. Measured on macOS 27 with and
    /// without `NSAllowsLocalNetworking`, the same either way: http reaches localhost, `.local` and unqualified names,
    /// and private, loopback and link-local addresses; it is refused for other host names (`gpu.lan`, a tailnet
    /// name) and public or 100.64/10 (Tailscale) addresses, which need https, a reverse proxy for instance.
    static func needsHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", var host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return false }
        if host.contains(":") {
            return !(host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd"))
        }
        let octets = host.split(separator: ".").map { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) < 256 }) else {
            // A name: allowed only without a dot.
            return host.contains(".")
        }
        let (a, b) = (octets[0] ?? 0, octets[1] ?? 0)
        let isPrivate =
            a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254)
        return !isPrivate
    }
}

/// Wan 2.2 Animate's character replacement on the person's own ComfyUI: the prepared source and prep's mask resampled
/// to 16 fps at the render size, uploaded with the character, and the bundled graph queued. Free; it runs on their
/// machine. Request IDs are ComfyUI prompt ids.
struct OwnComfyWan: GenerationProvider {
    let client: ComfyUIClient
    let diffusionModel: String

    static let clientID = "swapjutsu"

    func submit(_ request: GenerationRequest) async throws -> String {
        guard case .animate(let source, let mask, let character, let prompt, let quality) = request else {
            throw GenerationError.rejected("Wan 2.2 Animate renders a prepared clip; it has no drafts to finalize.")
        }
        let promptID = UUID().uuidString.lowercased()
        let tag = "swapjutsu-\(promptID.prefix(8))"
        let work = FileManager.default.temporaryDirectory.appending(path: tag)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let natural = try await WanVideo.size(of: source)
        let size = WanAnimateWorkflow.size(width: natural.width, height: natural.height, quality: quality)
        let frames = try await WanVideo.resample(
            source, to: work.appending(path: "source.mp4"), width: size.width, height: size.height,
            fps: WanAnimateWorkflow.fps)
        _ = try await WanVideo.resample(
            mask, to: work.appending(path: "mask.mp4"), width: size.width, height: size.height,
            fps: WanAnimateWorkflow.fps)

        let sourceName = try await client.upload(work.appending(path: "source.mp4"), as: "\(tag)-source.mp4")
        let maskName = try await client.upload(work.appending(path: "mask.mp4"), as: "\(tag)-mask.mp4")
        let ext = character.pathExtension.isEmpty ? "png" : character.pathExtension.lowercased()
        let characterName = try await client.upload(character, as: "\(tag)-character.\(ext)")
        let workflow = try WanAnimateWorkflow.make(
            .init(
                source: sourceName, mask: maskName, character: characterName, prompt: prompt, width: size.width,
                height: size.height, frames: frames, seed: Int.random(in: 0..<(1 << 48)),
                diffusionModel: diffusionModel))
        return try await ComfySeedance.sendOnce {
            do {
                return try await client.queue(workflow, promptID: promptID, clientID: Self.clientID)
            } catch ComfyError.invalidWorkflow(let reason) {
                // A refused graph was never queued.
                throw GenerationError.rejected("ComfyUI refused the workflow: \(reason)")
            }
        }
    }

    /// The queue first, then the history: ComfyUI writes a prompt's history before it leaves the queue, so a prompt
    /// in neither is gone (the server restarted, or the queue was cleared).
    func status(of requestID: String) async throws -> GenerationStatus {
        if try await client.queueState().contains(requestID) { return .pending }
        guard let history = try await client.history(requestID) else {
            return .failed(
                "ComfyUI has no prompt \(requestID): it may have restarted or its queue was cleared. Render again; "
                    + "it costs nothing.")
        }
        guard history.succeeded else { return .failed(history.failure ?? "ComfyUI couldn't finish the render.") }
        let saved = history.files(of: WanAnimateWorkflow.saveNode)
        guard
            let file = saved.first
                ?? history.outputs.keys.sorted().flatMap(history.files(of:)).first(where: {
                    ["mp4", "webm", "mov", "mkv"].contains(URL(filePath: $0.filename).pathExtension.lowercased())
                })
        else { return .failed("ComfyUI finished without a video.") }
        let ext = URL(filePath: file.filename).pathExtension
        let local = FileManager.default.temporaryDirectory.appending(
            path: "wan-\(requestID).\(ext.isEmpty ? "mp4" : ext)")
        try await client.download(file, to: local)
        return .completed(GenerationOutput(video: local))
    }

    /// Dropped from the queue or interrupted; either way nothing more runs or costs anything.
    func cancel(_ requestID: String) async throws -> Bool {
        try await client.cancel(requestID)
        return true
    }
}

/// Video for Wan 2.2 Animate: its frame rate and size, made on the Mac before the upload so the graph needs no
/// resampling node and the upload stays small.
enum WanVideo {
    /// The frame size as displayed.
    static func size(of url: URL) async throws -> (width: Int, height: Int) {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        return (Int(abs(shown.width).rounded()), Int(abs(shown.height).rounded()))
    }

    /// `url` at `fps` and exactly `width`×`height`, scaled to fill and cut at the centre (as the template's Image
    /// Scale does), as H.264 MP4. Returns how many frames it has.
    @discardableResult
    static func resample(_ url: URL, to output: URL, width: Int, height: Int, fps: Int) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let target = CGSize(width: width, height: height)
        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                request.finish(with: fill(request.sourceImage, target), context: nil)
            })
        composition.renderSize = target
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        export.videoComposition = composition
        try? FileManager.default.removeItem(at: output)
        try await export.export(to: output, as: .mp4)
        let duration = try await AVURLAsset(url: output).load(.duration)
        return max(1, Int((duration.seconds * Double(fps)).rounded()))
    }

    /// `image` scaled to cover `size` and cropped to it, centred, with its origin at zero.
    static func fill(_ image: CIImage, _ size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = scaled.extent.minX + (scaled.extent.width - size.width) / 2
        let y = scaled.extent.minY + (scaled.extent.height - size.height) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: -x, y: -y))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}
