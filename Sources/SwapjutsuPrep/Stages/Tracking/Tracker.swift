import Foundation

/// A run of detections of one person inside one shot, linked by mask overlap between consecutive frames.
public final class Tracklet {
    public internal(set) var shot: Int
    public private(set) var detections: [PersonDetection] = []
    public internal(set) var identity = 0
    var frames: Set<Int> { Set(detections.map(\.frame)) }

    init(shot: Int) { self.shot = shot }
    func append(_ detection: PersonDetection) { detections.append(detection) }

    public var screenArea: Int { detections.reduce(0) { $0 + $1.grid.area } }
    var confirmedShare: Double { Double(detections.filter(\.confirmed).count) / Double(max(1, detections.count)) }

    /// Detections spread over the tracklet, at most `count`.
    func sample(_ count: Int) -> [PersonDetection] {
        let step = max(1, detections.count / count)
        return stride(from: 0, to: detections.count, by: step).map { detections[$0] }
    }
}

/// Links each frame's detections to the open tracklets of the current shot by best mask IoU.
struct Tracker {
    let tuning: Tuning
    private(set) var tracklets: [Tracklet] = []
    private var open: [Tracklet] = []
    private var shot = 0

    init(tuning: Tuning) { self.tuning = tuning }

    mutating func cut() {
        shot += 1
        open = []
    }

    mutating func add(_ detections: [PersonDetection]) {
        var current: [Tracklet] = []
        var free = open
        // Largest people first: they are the most reliable to match.
        for detection in detections.sorted(by: { $0.grid.area > $1.grid.area }) {
            let best = free.compactMap { tracklet -> (Tracklet, Double)? in
                guard let last = tracklet.detections.last,
                    histogramDistance(last.appearance.colour, detection.appearance.colour) < tuning.trackSplitColour
                else { return nil }
                return (tracklet, last.grid.iou(detection.grid))
            }
            .filter { $0.1 > tuning.trackIoU }.max { $0.1 < $1.1 }?.0
            let tracklet = best ?? Tracklet(shot: shot)
            if best == nil { tracklets.append(tracklet) }
            free.removeAll { $0 === tracklet }
            tracklet.append(detection)
            current.append(tracklet)
        }
        open = current
    }

    var shotCount: Int { shot + 1 }
}
