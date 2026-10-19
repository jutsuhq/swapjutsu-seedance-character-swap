import CoreImage
import CoreML
import Vision

/// Vision: faces say which way up a frame is, body pose when no face is seen.
///
/// The face detector finds faces at any roll and reports it, so one pass on the frame as it is gives the turn: a
/// face rolled 90° stands upright after a 90° clockwise turn. Human rectangles are no help here: Vision finds the
/// same body at the same confidence however the frame is turned (measured on a sideways selfie). With no face in
/// the whole shot, body pose is run on the four turns of a few of its frames and the joints it is sure of are
/// counted: it finds a person lying on their side far less well than one standing. Pose is the slow part (four
/// requests a frame), so a shot with a face never runs it.
struct VisionOrientationProbe: OrientationProbing {
    /// Faces under this confidence do not vote.
    var minFaceConfidence: Float = 0.5
    /// A face rolled within this many degrees of a diagonal says nothing about which quarter turn is up.
    var diagonalMargin = 20.0
    /// A pose joint counts above this confidence.
    var minJointConfidence: Float = 0.3
    /// Frames of a faceless shot that pose looks at, spread across it.
    var poseFrames = 3

    func votes(_ frames: [CIImage]) throws -> [Int: Double] {
        var votes: [Int: Double] = [:]
        for frame in frames {
            // Vision cannot be interrupted, so a cancelled run stops between requests.
            try Task.checkCancellation()
            let faces = VNDetectFaceRectanglesRequest()
            onCPU(faces)
            try handler(frame, orientation: .up).perform([faces])
            for face in faces.results ?? [] where face.confidence >= minFaceConfidence {
                guard let roll = face.roll?.doubleValue else { continue }
                let degrees = roll * 180 / .pi
                let quarter = (degrees / 90).rounded()
                guard abs(degrees - quarter * 90) <= 45 - diagonalMargin else { continue }
                votes[Upright(degrees: Int(quarter) * 90, size: .zero).degrees, default: 0] += Double(face.confidence)
            }
        }
        guard votes.isEmpty, !frames.isEmpty else { return votes }
        let step = max(1, frames.count / poseFrames)
        for frame in stride(from: step / 2, to: frames.count, by: step).prefix(poseFrames).map({ frames[$0] }) {
            for degrees in [0, 90, 180, 270] {
                try Task.checkCancellation()
                let pose = VNDetectHumanBodyPoseRequest()
                onCPU(pose)
                let turn = Upright(degrees: degrees, size: frame.extent.size)
                try handler(frame, orientation: turn.vision).perform([pose])
                let joints =
                    try (pose.results ?? []).map {
                        try $0.recognizedPoints(.all).values.filter { $0.confidence > minJointConfidence }.count
                    }.max() ?? 0
                // A whole body is 19 joints: a clear pose is worth about one face.
                votes[degrees, default: 0] += Double(joints) / 19
            }
        }
        return votes.filter { $0.value > 0 }
    }

    /// The probe runs while the depth model loads, which can keep the Neural Engine compiling for seconds; a few dozen
    /// small requests are quicker on the CPU than waiting behind it.
    private func onCPU(_ request: VNRequest) {
        guard let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }),
            let stages = try? request.supportedComputeStageDevices
        else { return }
        for stage in stages.keys { request.setComputeDevice(cpu, for: stage) }
    }

    /// On the frame's own pixel buffer when it has one: handed a Core Image recipe, Vision renders it again for every
    /// request.
    private func handler(_ frame: CIImage, orientation: CGImagePropertyOrientation) -> VNImageRequestHandler {
        guard let buffer = frame.pixelBuffer else {
            return VNImageRequestHandler(ciImage: frame, orientation: orientation)
        }
        return VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
    }
}
