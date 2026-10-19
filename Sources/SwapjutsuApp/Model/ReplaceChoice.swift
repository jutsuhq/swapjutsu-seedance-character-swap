import SwapjutsuPrep

/// Who prep replaces, as Create picks it: Main or Everyone, or people by their ids (`Manifest.Identity.id`). Person 1
/// is prep's main person, so a pick that matches a preset is that preset and only other picks are stored as
/// `JobSpec.targetIDs`.
enum ReplaceChoice: Hashable {
    case preset(PrepTarget)
    case people(Set<Int>)

    init(_ spec: JobSpec) {
        self = spec.targetIDs.map { .people(Set($0)) } ?? .preset(spec.target)
    }

    var preset: PrepTarget? {
        if case .preset(let target) = self { target } else { nil }
    }

    /// The people replaced among `all`, the ids prep found.
    func ids(of all: [Int]) -> Set<Int> {
        switch self {
        case .preset(.main): Set(all).intersection([1])
        case .preset(.all): Set(all)
        case .people(let ids): ids
        }
    }

    /// The choice with `id` switched on or off; the last person replaced stays.
    func toggling(_ id: Int, of all: [Int]) -> ReplaceChoice {
        var ids = ids(of: all)
        if ids.remove(id) == nil { ids.insert(id) }
        if ids.isEmpty { return self }
        if ids == Set(all), all.count > 1 { return .preset(.all) }
        if ids == [1] { return .preset(.main) }
        return .people(ids)
    }
}

extension Manifest {
    /// The people worth offering: those seen in at least `Tuning.minTrackletFrames` frames, as prep's Everyone picks
    /// them, and anyone already replaced.
    var replaceable: [Identity] {
        let minFrames = Tuning().minTrackletFrames
        return identities.filter { $0.isTarget || $0.frames >= minFrames }
    }
}

extension JobStore {
    func prepareAgain(_ job: Job, replacing choice: ReplaceChoice, faceGuide: Bool, replaceBackground: Bool) {
        guard !job.isActive else { return }
        job.edit { $0.replaceBackground = replaceBackground }
        switch choice {
        case .preset(let target): prepareAgain(job, target: target, faceGuide: faceGuide)
        case .people(let ids): prepareAgain(job, target: job.spec.target, faceGuide: faceGuide, people: ids.sorted())
        }
    }
}
