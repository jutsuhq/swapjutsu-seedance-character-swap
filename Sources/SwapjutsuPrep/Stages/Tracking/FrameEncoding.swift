import CoreImage
import CoreML
import Foundation

/// The image side of `EdgeTAMTracker`: a frame, or a crop of it, scaled to 1024² and run through the image encoder.
///
/// The encoder does not read the memory bank, so it need not wait for the frame before it. `encodeAhead` starts the
/// next frame's encoding on a queue of its own while the tracker propagates the current one, and `features` on that
/// frame then waits for that result instead of encoding again (#20). Every frame is still encoded from its own
/// pixels with the same crops, so the masks are the same as encoding in turn. Each side has a 1024² buffer of its own.
///
/// `@unchecked Sendable`: the queue's job touches only `aheadInput` and its own `Job`, which the caller reads after
/// the job signals `done`; everything else is used from the caller's thread.
final class FrameEncoding: @unchecked Sendable {
    /// By crop, nil for the whole frame.
    typealias Features = [TrackingCrop?: MLFeatureProvider]

    /// The features of a frame by crop, and the seconds spent on it by part (`prepare`, `encoder`, and with an ahead
    /// job `encoder wait`, the time the caller waited for it).
    struct Encoded {
        let features: Features
        /// The features came from an ahead job.
        let ahead: Bool
        let spent: [(part: String, seconds: Double)]
    }

    private final class Job: @unchecked Sendable {
        let frame: CIImage
        let done = DispatchSemaphore(value: 0)
        var features: Features = [:]
        var spent: [(part: String, seconds: Double)] = []
        var error: (any Error)?
        init(frame: CIImage) { self.frame = frame }
    }

    private let models: EdgeTAMModels
    private let context: CIContext
    private let queue = DispatchQueue(label: "SwapjutsuPrep.EdgeTAM.encodeAhead", autoreleaseFrequency: .workItem)
    private var input: CVPixelBuffer?
    private var aheadInput: CVPixelBuffer?
    private var job: Job?

    init(models: EdgeTAMModels, context: CIContext) {
        self.models = models
        self.context = context
    }

    /// The features of `frame` in each of `crops` (nil: the whole frame): from the ahead job when it was started on this very frame, the
    /// rest encoded now. A job started on another frame is dropped.
    func features(_ frame: CIImage, crops: [TrackingCrop?]) throws -> Encoded {
        var features: Features = [:]
        var spent: [(part: String, seconds: Double)] = []
        let ahead = job?.frame === frame
        if let job, ahead {
            let start = Date()
            job.done.wait()
            spent.append(("encoder wait", Date().timeIntervalSince(start)))
            if let error = job.error { throw error }
            features = job.features
            spent += job.spent
        }
        job = nil
        for crop in crops where features[crop] == nil {
            features[crop] = try encode(frame, crop: crop, into: &input, spent: &spent)
        }
        return Encoded(features: features, ahead: ahead, spent: spent)
    }

    /// Starts encoding `frame` in `crops` on the encoder's queue, for the next `features` call.
    func encodeAhead(_ frame: CIImage, crops: [TrackingCrop?]) {
        let job = Job(frame: frame)
        self.job = job
        queue.async { [self] in
            defer { job.done.signal() }
            do {
                for crop in crops {
                    job.features[crop] = try encode(job.frame, crop: crop, into: &aheadInput, spent: &job.spent)
                }
            } catch { job.error = error }
        }
    }

    private func encode(
        _ frame: CIImage, crop: TrackingCrop?, into buffer: inout CVPixelBuffer?,
        spent: inout [(part: String, seconds: Double)]
    ) throws -> MLFeatureProvider {
        var start = Date()
        let image = try resized(frame, crop: crop, into: &buffer)
        spent.append(("prepare", Date().timeIntervalSince(start)))
        start = Date()
        let features = try models.imageEncoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["image": image]))
        spent.append(("encoder", Date().timeIntervalSince(start)))
        return features
    }

    /// The frame, or its `crop`, scaled to 1024² (aspect not kept, as the model was trained), into one reused buffer.
    /// A crop's edge pixels are extended outward so the scaling does not blend them with transparent black.
    private func resized(
        _ frame: CIImage, crop: TrackingCrop?, into buffer: inout CVPixelBuffer?
    ) throws -> CVPixelBuffer {
        if buffer == nil {
            CVPixelBufferCreate(nil, EdgeTAMTracker.side, EdgeTAMTracker.side, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { throw PrepError.model("no pixel buffer for EdgeTAM") }
        let side = CGFloat(EdgeTAMTracker.side)
        let image: CIImage
        if let crop {
            let r = crop.imageRect(frameHeight: Int(frame.extent.height))
                .offsetBy(dx: frame.extent.minX, dy: frame.extent.minY)
            image = frame.cropped(to: r).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                .transformed(by: CGAffineTransform(scaleX: side / r.width, y: side / r.height))
                .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        } else {
            let e = frame.extent
            image = frame.transformed(by: CGAffineTransform(scaleX: side / e.width, y: side / e.height))
        }
        context.render(image, to: buffer)
        return buffer
    }
}
