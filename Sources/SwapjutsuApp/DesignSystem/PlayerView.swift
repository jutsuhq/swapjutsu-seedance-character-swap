import AVKit
import SwiftUI

/// `AVPlayerView` with its inline controls. SwiftUI's `VideoPlayer` crashes in a SwiftPM executable: its superclass
/// can't be resolved there.
struct PlayerView: NSViewRepresentable {
    let url: URL
    /// A time to show, e.g. under a trim handle being dragged; the player pauses there.
    var seek: Double?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        if let seek, seek != context.coordinator.lastSeek {
            context.coordinator.lastSeek = seek
            view.player?.pause()
            view.player?.seek(
                to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSeek: Double?
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
    }
}
