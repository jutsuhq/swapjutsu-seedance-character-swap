import AVFoundation
import SwapjutsuPrep
import SwiftUI

/// The Prep step's target fix (#58): the frames prep flagged, the frame with the mask the prep made, a click or a
/// brush to correct it, the shot re-tracked with its progress, the frame before and after, and the prep run again
/// with the fix.
struct TargetFixPanel: View {
    /// The panel's id in the column of steps, which scrolls to it when it opens.
    static let anchor = "target-fix"
    let fix: TargetFix
    @Environment(JobStore.self) private var jobs
    @State private var image: CGImage?
    /// The prep's mask on the frame, from `mask.mp4`.
    @State private var before: [UInt8]?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            flagged
            HStack(spacing: Theme.Spacing.small) {
                Text("Frame \(fix.frame)").font(Theme.Typography.strongNote).foregroundStyle(Theme.text)
                    .monospacedDigit()
                Slider(
                    value: Binding(get: { Double(fix.frame) }, set: { fix.select(frame: Int($0.rounded())) }),
                    in: 0...Double(max(1, fix.frames - 1)), step: 1
                )
                .disabled(fix.isRetracking)
            }
            FrameCanvas(image: image, mask: fix.painted ?? before, width: fix.width, height: fix.height, point: fix.point)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in if fix.tool != .click { edit(value.location, value.startLocation) } }
                        .onEnded { value in if fix.tool == .click { edit(value.location, value.startLocation) } }
                )
                .onPreferenceChange(CanvasSizeKey.self) { canvasSize = $0 }
                .disabled(fix.isRetracking)
                .help(fix.tool == .click ? "Click the person to replace" : "Drag to paint or erase the mask")
            SegmentedControl(
                selection: Binding(get: { fix.tool }, set: { fix.tool = $0 }),
                options: [(.click, "Click"), (.paint, "Paint"), (.erase, "Erase")], isCompact: true
            )
            .fixedSize()
            status
            actions
        }
        .task(id: [fix.frame, fix.job.manifest?.frames ?? 0]) { await load() }
    }

    @State private var canvasSize = CGSize(width: 1, height: 1)

    private var flagged: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(fix.flags.isEmpty ? "Prep flagged no frames; pick one to check." : "Frames to check")
                .font(Theme.Typography.note).foregroundStyle(Theme.muted)
            if !fix.flags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.Spacing.xSmall) {
                        ForEach(fix.flags) { flag in
                            Button(flag.title) { fix.select(frame: flag.frame, person: flag.person) }
                                .buttonStyle(.secondaryAction)
                                .disabled(fix.isRetracking)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch fix.phase {
        case .editing:
            line(
                fix.hasCorrection
                    ? "Re-track the shot from this frame to check the fix."
                    : "Click the person to replace, or paint the mask, on a frame where it is wrong.",
                color: Theme.muted)
        case .retracking(let done, let total):
            ProgressView(value: Double(done), total: Double(max(1, total))).progressViewStyle(.linear)
                .tint(Theme.accent)
            line("Re-tracking shot \(fix.shot?.index ?? 0): \(done) of \(total) frames", color: Theme.muted)
        case .retracked:
            if let after = fix.after[fix.frame] {
                HStack(spacing: Theme.Spacing.small) {
                    labelled("Before", FrameCanvas(image: image, mask: before, width: fix.width, height: fix.height))
                    labelled("After", FrameCanvas(image: image, mask: after, width: fix.width, height: fix.height))
                }
            } else {
                line("Re-tracked. Pick a flagged frame to see it before and after.", color: Theme.muted)
            }
        case .failed(let message):
            line(message, color: Theme.danger)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button("Re-track Shot", systemImage: "scope") { Task { await fix.retrack() } }
                .buttonStyle(.secondaryAction)
                .disabled(!fix.hasCorrection || fix.isRetracking)
                .help("Seconds, on this Mac; the control video changes when you prepare again")
            if fix.phase == .retracked || !fix.saved.isEmpty {
                Button("Prepare Again with Fix", systemImage: "arrow.clockwise") { jobs.prepareAgain(fix.job) }
                    .buttonStyle(.primaryAction)
                    .disabled(fix.isRetracking || fix.job.isRendering)
                    .help("Free; renders already made stay")
                Button("Remove Fix") { fix.removeFixes() }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.strongNote)
                    .foregroundStyle(Theme.muted)
                    .pointerCursor()
                    .disabled(fix.isRetracking)
            }
        }
    }

    private func edit(_ location: CGPoint, _ start: CGPoint) {
        let unit = CGPoint(x: location.x / canvasSize.width, y: location.y / canvasSize.height)
        if fix.tool == .click {
            // A click, not a drag.
            guard hypot(location.x - start.x, location.y - start.y) < 6 else { return }
            fix.click(unit)
        } else {
            fix.brush(unit, radius: 0.025, base: before)
        }
    }

    private func load() async {
        guard let manifest = fix.manifest else { return }
        let n = fix.frame
        async let frame = ClipFrame.image(fix.job.output.appending(path: "prepared.mp4"), frame: n, fps: manifest.fps)
        async let mask = ClipFrame.image(fix.job.output.appending(path: "mask.mp4"), frame: n, fps: manifest.fps)
        let (f, m) = await (frame, mask)
        guard n == fix.frame else { return }
        image = f
        before = m.map { ClipFrame.bytes($0, width: manifest.width, height: manifest.height) }
    }

    private func labelled(_ title: String, _ content: some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Typography.note).foregroundStyle(Theme.faint)
            content
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text).font(Theme.Typography.note).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}

/// A frame with a mask painted over it in the accent colour and the click, if any, as a dot.
struct FrameCanvas: View {
    let image: CGImage?
    let mask: [UInt8]?
    let width: Int
    let height: Int
    var point: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Theme.well
                if let image { Image(decorative: image, scale: 1).resizable() }
                if let overlay = mask.flatMap({ ClipFrame.maskImage($0, width: width, height: height) }) {
                    Theme.accent.opacity(0.5)
                        .mask { Image(decorative: overlay, scale: 1).resizable().luminanceToAlpha() }
                }
                if let point {
                    Circle().fill(Theme.danger).stroke(Theme.text, lineWidth: 2)
                        .frame(width: 12, height: 12)
                        .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                }
            }
            .preference(key: CanvasSizeKey.self, value: geometry.size)
        }
        .aspectRatio(CGFloat(max(1, width)) / CGFloat(max(1, height)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct CanvasSizeKey: PreferenceKey {
    static let defaultValue = CGSize(width: 1, height: 1)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Single frames of the prep's videos, and masks as bytes and images.
enum ClipFrame {
    /// Frame `n` of a video written at `fps`, exactly (no tolerance).
    static func image(_ url: URL, frame n: Int, fps: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // The middle of the frame, so rounding never lands on its neighbour.
        let time = CMTime(value: CMTimeValue(2 * n + 1), timescale: CMTimeScale(2 * max(1, fps)))
        return try? await generator.image(at: time).image
    }

    /// An image's light pixels as 255, the rest 0, at `width` × `height`, rows top-down.
    static func bytes(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var gray = [UInt8](repeating: 0, count: width * height)
        gray.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return gray.map { $0 > 127 ? 255 : 0 }
    }

    /// Mask bytes as a grey image, to tint.
    static func maskImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count == width * height,
            let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
