import CoreImage
import Vision

/// Where the targets' hands are, as a soft mask the control lifts nearer in depth. A hand resting on the belly or
/// tucked into a pocket sits at the torso's depth, so the coloured depth shows no hand at all and Seedance invents
/// stumps; lifted by `Tuning.handLift`, the hand and its fingers stand out as a depth edge. It is depth, not drawn
/// lines: lines on the face were copied into the render.
struct HandCue {
    /// One hand's joints in frame pixels (bottom-left origin), by finger from the wrist out.
    struct Hand: Equatable {
        var wrist: CGPoint
        /// Thumb, index, middle, ring and little: each from its base joint to the tip, the joints Vision was sure of.
        var fingers: [[CGPoint]]

        /// Wrist to the middle finger's base: how large the hand is, for the stroke width.
        var size: CGFloat {
            guard let base = fingers.count > 2 ? fingers[2].first : nil else { return 0 }
            return hypot(base.x - wrist.x, base.y - wrist.y)
        }
    }

    /// The hands Vision finds in `box` of `frame`, at least `minimumJoints` confident joints each. A small box is
    /// upscaled first: hand pose misses hands under ~60 px.
    static func hands(in frame: CIImage, box: CGRect, minimumJoints: Int = 8) throws -> [Hand] {
        let region = box.intersection(frame.extent)
        guard region.width > 16, region.height > 16 else { return [] }
        let scale = max(1, 512 / max(region.width, region.height))
        let crop = frame.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 4
        try VNImageRequestHandler(ciImage: crop).perform([request])
        let size = crop.extent.size
        func place(_ point: VNRecognizedPoint) -> CGPoint {
            CGPoint(
                x: point.location.x * size.width / scale + region.minX,
                y: point.location.y * size.height / scale + region.minY)
        }
        let chains: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbCMC, .thumbMP, .thumbIP, .thumbTip], [.indexMCP, .indexPIP, .indexDIP, .indexTip],
            [.middleMCP, .middlePIP, .middleDIP, .middleTip], [.ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.littleMCP, .littlePIP, .littleDIP, .littleTip],
        ]
        return (request.results ?? []).compactMap { observation in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            let sure = points.filter { $0.value.confidence > 0.3 }
            // The wrist is often unsure where the hand meets a sleeve or a pocket; its estimate still places the palm.
            guard sure.count >= minimumJoints, let wrist = points[.wrist] else { return nil }
            let fingers = chains.map { chain in chain.compactMap { sure[$0].map(place) } }
            return Hand(wrist: place(wrist), fingers: fingers)
        }
    }

    /// The hands as a white-on-black mask the size of `extent`: the palm filled, each finger a round stroke from
    /// the palm to its tip, about a third of the hand's size wide, softened by a pixel so the edge reads as depth.
    static func mask(_ hands: [Hand], extent: CGRect) -> CIImage? {
        let drawn = hands.filter { $0.size > 2 }
        guard !drawn.isEmpty,
            let cg = CGContext(
                data: nil, width: Int(extent.width), height: Int(extent.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        cg.fill(CGRect(origin: .zero, size: extent.size))
        cg.translateBy(x: -extent.minX, y: -extent.minY)
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        for hand in drawn {
            let width = hand.size * 0.32
            let palm = [hand.wrist] + hand.fingers.compactMap(\.first)
            if palm.count > 2 {
                cg.addLines(between: palm)
                cg.closePath()
                cg.fillPath()
            }
            cg.setLineWidth(width)
            for finger in hand.fingers where !finger.isEmpty {
                cg.addLines(between: [hand.wrist] + finger)
                cg.strokePath()
            }
        }
        guard let image = cg.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .applyingGaussianBlur(sigma: 1)
            .cropped(to: extent)
    }

    /// Vision loses a hand for a frame or two as it turns or slides into a pocket: the last hands found hold for up to
    /// `frames` frames within the shot. Counts the frames that get hands.
    struct Hold {
        var limit = 3
        private(set) var frames = 0
        private var last: (frame: Int, shot: Int)?
        private var hands: [Hand] = []

        /// "  hands lifted in 46/120 frames", nil when none was.
        func summary(of count: Int) -> String? { frames == 0 ? nil : "  hands lifted in \(frames)/\(count) frames" }

        mutating func hands(_ found: [Hand], frame: Int, shot: Int) -> [Hand] {
            if !found.isEmpty {
                (last, hands) = ((frame, shot), found)
            } else if let last, last.shot == shot, frame - last.frame <= limit {
                // Held.
            } else {
                return []
            }
            frames += 1
            return hands
        }
    }
}
