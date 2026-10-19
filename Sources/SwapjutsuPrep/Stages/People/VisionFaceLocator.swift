import CoreImage
import Vision

/// Vision face landmarks: the whole-frame face inside the person's mask, else a search inside their head region,
/// upscaled, which finds small and turned faces that a whole-frame pass misses.
struct VisionFaceLocator: FaceLocating {
    /// The largest whole-frame face whose centre lies inside the person's mask, else a search in their head region.
    func face(
        in frame: CIImage, person grid: MaskGrid, personBox: CGRect, frameFaces: [DetectedFace]
    ) throws -> FaceLandmarks? {
        let own = frameFaces.filter { f in
            let x = Int(f.box.midX * Double(grid.side)), y = Int((1 - f.box.midY) * Double(grid.side))
            return x >= 0 && x < grid.side && y >= 0 && y < grid.side && grid.cells[y * grid.side + x]
        }
        if let best = own.max(by: { $0.box.width < $1.box.width }), let landmarks = best.landmarks {
            return landmarks
        }
        return try faceInHead(of: frame, personBox: personBox)
    }

    private func faceInHead(of frame: CIImage, personBox: CGRect) throws -> FaceLandmarks? {
        let head = CGRect(
            x: personBox.minX, y: personBox.maxY - personBox.height * 0.45,
            width: personBox.width, height: personBox.height * 0.45
        ).intersection(frame.extent)
        guard head.width > 8, head.height > 8 else { return nil }
        let scale = max(1, 512 / head.width)
        let crop = frame.cropped(to: head)
            .transformed(by: CGAffineTransform(translationX: -head.minX, y: -head.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        try VNImageRequestHandler(ciImage: crop).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
            let landmarks = face.landmarks
        else { return nil }
        return FaceLandmarks(landmarks, size: crop.extent.size) {
            CGPoint(x: $0.x / scale + head.minX, y: $0.y / scale + head.minY)
        }
    }
}

extension FaceLandmarks {
    /// Vision's landmark polylines in frame pixels; `place` maps from the analysed image to the frame.
    init(_ landmarks: VNFaceLandmarks2D, size: CGSize, place: (CGPoint) -> CGPoint) {
        func region(_ name: String, _ r: VNFaceLandmarkRegion2D?, closed: Bool) -> (String, [CGPoint], Bool)? {
            guard let r else { return nil }
            return (name, r.pointsInImage(imageSize: size).map(place), closed)
        }
        let regions = [
            region("faceContour", landmarks.faceContour, closed: false),
            region("outerLips", landmarks.outerLips, closed: true),
            region("innerLips", landmarks.innerLips, closed: true),
            region("leftEye", landmarks.leftEye, closed: true), region("rightEye", landmarks.rightEye, closed: true),
            region("leftEyebrow", landmarks.leftEyebrow, closed: false),
            region("rightEyebrow", landmarks.rightEyebrow, closed: false),
            region("nose", landmarks.nose, closed: true), region("noseCrest", landmarks.noseCrest, closed: false),
        ].compactMap { $0 }
        self.init(regions: regions.map { Region(name: $0.0, points: $0.1, closed: $0.2) })
    }
}
