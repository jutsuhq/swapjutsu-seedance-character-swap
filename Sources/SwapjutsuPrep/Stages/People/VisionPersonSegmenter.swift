import CoreImage
import Vision

/// Vision: person instance masks refined by the accurate person matte.
///
/// `VNGeneratePersonInstanceMaskRequest` separates up to four people, but its masks have holes inside the body
/// (patterned clothing) and soft blobs on nearby objects; `VNGeneratePersonSegmentationRequest` (accurate) fills
/// bodies and has clean edges, but merges everyone and grabs objects next to people (seat headrests). Each person
/// is the matte inside their own closed instance core — closing fills the holes without reaching objects — minus
/// the other people's cores.
struct VisionPersonSegmenter: PersonSegmenting {
    let tuning: Tuning
    let context: CIContext

    func analyse(_ frame: CIImage) throws -> FrameAnalysis {
        let extent = frame.extent
        let handler = VNImageRequestHandler(ciImage: frame)
        let instances = VNGeneratePersonInstanceMaskRequest()
        let matte = VNGeneratePersonSegmentationRequest()
        matte.qualityLevel = .accurate
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceLandmarksRequest()
        faces.revision = VNDetectFaceLandmarksRequestRevision3
        try handler.perform([instances, matte, humans, faces])
        let humanBoxes = humans.results?.map(\.boundingBox) ?? []
        let faceObservations = Self.faces(faces.results ?? [], size: extent.size)
        guard let observation = instances.results?.first, let matteBuffer = matte.results?.first?.pixelBuffer else {
            return FrameAnalysis(people: [], humans: humanBoxes, faces: faceObservations)
        }
        let matteImage = fit(CIImage(cvPixelBuffer: matteBuffer), to: extent)
        let cores = try observation.allInstances.map {
            CIImage(
                cvPixelBuffer: try observation.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: $0), from: handler)
            )
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.35])
        }
        let radius = extent.width * tuning.closeRadius
        let people = cores.enumerated().map { i, core in
            // Clamping extends the frame edge outward, so a body cut off by the frame closes too.
            var claim = core.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
            // Instance masks can miss a whole stretch of patterned clothing; the person's body rectangle lets the
            // matte fill it.
            let box = MaskGrid(mask: core, side: 48, context: context).unitBox
            if let body = humanBoxes.map({ ($0, overlap($0, box)) }).filter({ $0.1 > 0.5 }).max(by: { $0.1 < $1.1 })?.0
            {
                let rect = CGRect(
                    x: body.minX * extent.width, y: body.minY * extent.height,
                    width: body.width * extent.width, height: body.height * extent.height
                )
                .insetBy(dx: -extent.width * 0.02, dy: -extent.width * 0.02)
                claim = CIImage(color: .white).cropped(to: rect)
                    .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: claim]).cropped(
                        to: extent)
            }
            var mask = matteImage.applyingFilter(
                "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: claim])
            for (j, other) in cores.enumerated() where j != i {
                mask = mask.applyingFilter(
                    "CIMultiplyCompositing",
                    parameters: [
                        kCIInputBackgroundImageKey: other.applyingFilter("CIColorInvert")
                    ])
            }
            return mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: core]).cropped(
                to: extent)
        }
        return FrameAnalysis(people: people, humans: humanBoxes, faces: faceObservations)
    }

    private static func faces(_ observations: [VNFaceObservation], size: CGSize) -> [DetectedFace] {
        observations.map {
            DetectedFace(box: $0.boundingBox, landmarks: $0.landmarks.map { FaceLandmarks($0, size: size) { $0 } })
        }
    }
}
