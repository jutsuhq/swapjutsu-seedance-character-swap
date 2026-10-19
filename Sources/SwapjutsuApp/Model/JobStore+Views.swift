import Foundation
import SwapjutsuPrep

/// The characters' views from a known angle, added by the person. Each is one more view of the person in `cast`
/// (`addReferences(asView:)`) with its angle noted (`JobSpec.viewAngles`).
extension JobStore {
    /// Puts `url` on the clip as replaced person `person`'s view from `angle`, copied into its folder, replacing the
    /// view they had from that angle. Returns why it was refused, if it was.
    @discardableResult
    func addView(_ url: URL, angle: CharacterAngle, person: Int, to job: Job) -> String? {
        guard let targets = job.manifest?.targets,
            let binding = job.cast.first(where: { $0.person == person }), binding.character != nil
        else { return "Add the character's image first." }
        let count = job.spec.references.count
        if let problem = addReferences([url], to: job, person: person, asView: true) { return problem }
        let index =
            job.spec.references.count > count
            ? count : job.spec.references.firstIndex { $0.standardizedFileURL == url.standardizedFileURL }
        guard let index else { return nil }
        let file = job.spec.references[index]
        job.edit { spec in
            let replaced = spec.cast(for: targets).first { $0.person == person }?.views
                .filter { $0 != index && spec.angle(of: $0) == angle } ?? []
            spec.viewAngles = (spec.viewAngles ?? [:]).merging([file.lastPathComponent: angle]) { $1 }
            for old in replaced.sorted(by: >) { spec.removeReference(at: old) }
        }
        save(job)
        return nil
    }
}
