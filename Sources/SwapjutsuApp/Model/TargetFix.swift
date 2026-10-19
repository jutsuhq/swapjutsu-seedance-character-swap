import CoreImage
import Foundation
import Observation
import SwapjutsuPrep

/// Re-tracks one target shot of a prepared clip from corrections (`CorrectionPreview`) and returns the kept frames'
/// masks; tests pass a stand-in. Progress is (frames done, frames to do).
typealias Retracker =
    @Sendable (CorrectionPreview.Request, @escaping @Sendable (Int, Int) -> Void) async throws -> [Int: [UInt8]]

enum Retrackers {
    /// EdgeTAM, from the instance `TrackingModel` keeps loaded, fetched first when the app has none yet.
    @MainActor
    static func edgeTAM(_ tracking: TrackingModel) -> Retracker {
        { request, progress in
            let models = try await tracking.model(for: try await tracking.ensure())
            let context = CIContextCache.shared
            let tracker = EdgeTAMTracker(models: models, context: context)
            return try await CorrectionPreview.run(request, tracker: tracker, context: context, progress: progress)
        }
    }

    /// For tests and the smoke launch: refuses.
    static let unavailable: Retracker = { _, _ in throw CocoaError(.featureUnsupported) }
}

/// One clip's target fix (#58): the frames prep flagged, a click or a painted mask on one frame, the shot re-tracked
/// from it in seconds with its before and after, then the prep run again with it so the control video changes.
///
/// The correction is written to the clip's folder (`TargetCorrections`) when the shot is re-tracked, so the prep run
/// again applies it, and so does every later prep of the clip until it is removed.
@MainActor
@Observable
final class TargetFix {
    /// A run of flagged frames of one target shot.
    struct Flag: Identifiable, Hashable {
        let shot: Int
        let person: Int
        let frame: Int
        let until: Int
        let reasons: [TrackingFlag.Reason]
        var id: String { "\(person)-\(frame)" }

        /// "Frame 72 · size jump".
        var title: String {
            let frames = until > frame ? "Frames \(frame)–\(until)" : "Frame \(frame)"
            return ([frames] + reasons.map(\.title)).joined(separator: " · ")
        }
    }

    enum Tool: Hashable { case click, paint, erase }

    enum Phase: Equatable {
        case editing
        case retracking(done: Int, total: Int)
        /// Re-tracked; `after` holds the new masks.
        case retracked
        case failed(String)
    }

    let job: Job
    /// The prep it was made for (its timings, which differ every run).
    let prep: [String: Double]?
    private let retracker: Retracker
    /// Shown in the clip's Prep step.
    var isOpen = false
    var tool = Tool.click
    var person: Int
    private(set) var frame = 0
    /// A click, as shares of the frame from the top left.
    private(set) var point: CGPoint?
    /// A painted mask, frame-sized bytes rows top-down, 255 inside.
    private(set) var painted: [UInt8]?
    private(set) var phase = Phase.editing
    /// The re-tracked masks of the flagged frames and the corrected one.
    private(set) var after: [Int: [UInt8]] = [:]

    init(job: Job, retracker: @escaping Retracker) {
        self.job = job
        prep = job.manifest?.timings
        self.retracker = retracker
        person = job.manifest?.targets.first ?? 1
        frame = flags.first?.frame ?? 0
    }

    var manifest: Manifest? { job.manifest }
    var width: Int { manifest?.width ?? 0 }
    var height: Int { manifest?.height ?? 0 }
    var frames: Int { manifest?.frames ?? 0 }

    /// The flagged runs of every replaced person's shots, in frame order.
    var flags: [Flag] {
        guard let manifest else { return [] }
        return (manifest.tracking?.shots ?? []).filter { manifest.targets.contains($0.target) }.flatMap { shot in
            (shot.flags ?? []).map {
                Flag(shot: shot.shot, person: shot.target, frame: $0.frame, until: $0.until, reasons: $0.reasons)
            }
        }.sorted { ($0.frame, $0.person) < ($1.frame, $1.person) }
    }

    var hasCorrection: Bool { point != nil || painted != nil }
    var isRetracking: Bool { if case .retracking = phase { true } else { false } }

    /// The shot of `frame`.
    var shot: Manifest.Shot? { manifest?.shots.first { $0.start <= frame && frame <= $0.end } }

    /// The corrections saved in the clip's folder.
    var saved: [TargetCorrection] { (try? TargetCorrections.load(from: job.output)) ?? [] }

    func select(frame: Int, person: Int? = nil) {
        guard frame != self.frame || person.map({ $0 != self.person }) == true else { return }
        self.frame = max(0, min(frame, max(0, frames - 1)))
        if let person { self.person = person }
        point = nil
        painted = nil
        if !isRetracking, phase != .retracked { phase = .editing }
    }

    /// A click on the target, as shares of the frame.
    func click(_ unit: CGPoint) {
        point = CGPoint(x: min(1, max(0, unit.x)), y: min(1, max(0, unit.y)))
        painted = nil
        edited()
    }

    /// Paints or erases a disc of `radius` (share of the frame's width) at `unit`, starting from `base` (the mask
    /// the prep made on this frame) the first time. A drag goes on past the canvas: the part of the disc off the
    /// frame is dropped, and a disc wholly off it changes nothing.
    func brush(_ unit: CGPoint, radius: Double, base: [UInt8]?) {
        guard width > 0, height > 0 else { return }
        let (cx, cy) = (unit.x * Double(width), unit.y * Double(height))
        let r = max(1, radius * Double(width))
        // Clamped as Doubles, so the Int conversion below never sees a value out of the frame (or not finite).
        let x0 = max(0, (cx - r).rounded(.down)), x1 = min(Double(width - 1), (cx + r).rounded(.down))
        let y0 = max(0, (cy - r).rounded(.down)), y1 = min(Double(height - 1), (cy + r).rounded(.down))
        guard cx.isFinite, cy.isFinite, r.isFinite, x0 <= x1, y0 <= y1 else { return }
        var mask = painted ?? base ?? [UInt8](repeating: 0, count: width * height)
        guard mask.count == width * height else { return }
        let value: UInt8 = tool == .erase ? 0 : 255
        for y in Int(y0)...Int(y1) {
            for x in Int(x0)...Int(x1) {
                let (dx, dy) = (Double(x) - cx, Double(y) - cy)
                if dx * dx + dy * dy <= r * r { mask[y * width + x] = value }
            }
        }
        painted = mask
        point = nil
        edited()
    }

    /// A whole mask for the frame, as an agent gives it.
    func setMask(_ bytes: [UInt8]) {
        guard bytes.count == width * height else { return }
        painted = bytes
        point = nil
        tool = .paint
        edited()
    }

    /// A new click or mask is not re-tracked yet; the last re-track's frames stay to compare.
    private func edited() {
        if !isRetracking { phase = .editing }
    }

    /// Saves the correction in the clip's folder and re-tracks its shot from every correction of this person there.
    func retrack() async {
        guard let shot, !isRetracking, hasCorrection, job.stage == .prepared else { return }
        do {
            let correction = try save(shot: shot.index)
            let mine = saved.filter { $0.identity == person && $0.frame >= shot.start && $0.frame <= shot.end }
            let crop = manifest?.tracking?.shots.first { $0.shot == shot.index && $0.target == person }?.crop
            let keep = Set(flags.filter { $0.shot == shot.index }.flatMap { [$0.frame, $0.until] } + [correction.frame])
            let request = CorrectionPreview.Request(
                prep: job.output, shot: shot.index, start: shot.start, end: shot.end + 1, identity: person,
                crop: crop.flatMap { $0.count == 4 ? TrackingCrop(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil },
                corrections: mine.isEmpty ? [correction] : mine, keep: keep, orientation: shot.orientation ?? 0)
            phase = .retracking(done: 0, total: shot.end - shot.start + 2)
            let masks = try await retracker(request) { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.isRetracking else { return }
                    self.phase = .retracking(done: done, total: total)
                }
            }
            after = masks
            phase = .retracked
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Writes the correction (a mask as a PNG beside it), replacing an earlier one of the same person and frame.
    private func save(shot: Int) throws -> TargetCorrection {
        let kind: TargetCorrection.Kind
        if let point {
            kind = .point(x: point.x, y: point.y)
        } else if let painted {
            kind = .mask(
                file: try TargetCorrections.storeMask(
                    painted, width: width, height: height, in: job.output, name: "p\(person)-f\(frame)"))
        } else {
            throw CocoaError(.userCancelled)
        }
        let correction = TargetCorrection(shot: shot, frame: frame, identity: person, kind: kind)
        var all = saved.filter { !($0.identity == person && $0.frame == frame) }
        all.append(correction)
        try TargetCorrections.save(all, to: job.output)
        return correction
    }

    /// Removes this person's corrections of the shot from the clip's folder; the prep run again tracks it as before.
    func removeFixes() {
        guard let shot else { return }
        let rest = saved.filter { !($0.identity == person && $0.frame >= shot.start && $0.frame <= shot.end) }
        try? TargetCorrections.save(rest, to: job.output)
        after = [:]
        point = nil
        painted = nil
        phase = .editing
    }

    /// What an agent sees of the fix.
    var summary: String? {
        switch phase {
        case .editing: hasCorrection ? "correction on frame \(frame), not re-tracked yet" : nil
        case .retracking(let done, let total): "re-tracking shot \(shot?.index ?? 0): \(done)/\(total) frames"
        case .retracked:
            "re-tracked shot \(shot?.index ?? 0) from frame \(frame); prepare_again applies it to the control video"
        case .failed(let message): "re-tracking failed: \(message)"
        }
    }
}

/// Each clip's target fix, the same one for the Prep step and agents; a fix made before the clip was prepared again
/// is dropped.
@MainActor
@Observable
final class TargetFixes {
    let retracker: Retracker
    private var fixes: [UUID: TargetFix] = [:]

    init(retracker: @escaping Retracker) { self.retracker = retracker }

    func fix(for job: Job) -> TargetFix {
        if let fix = existing(for: job) { return fix }
        let fix = TargetFix(job: job, retracker: retracker)
        fixes[job.id] = fix
        return fix
    }

    /// The clip's fix if one was opened for its current prep.
    func existing(for job: Job) -> TargetFix? {
        fixes[job.id].flatMap { $0.job === job && $0.prep == job.manifest?.timings ? $0 : nil }
    }
}

extension TrackingFlag.Reason {
    var title: String {
        switch self {
        case .areaJump: "size jump"
        case .overlap: "on someone else"
        case .lost: "lost"
        case .lowScore: "unsure"
        }
    }
}

/// One Core Image context for the app's re-tracks.
enum CIContextCache {
    nonisolated(unsafe) static let shared = CIContext(options: [.cacheIntermediates: false])
}
