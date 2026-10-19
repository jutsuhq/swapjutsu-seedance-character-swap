import Foundation

/// The job store's background work, each task owned by what it is for: a clip's prep, its description and the
/// reading of its prompt by the clip, a render by the render. Work is keyed by that id and its kind, so canceling or
/// awaiting a clip finds its description as well as its prep.
///
/// It also owns the one slot for heavy local work: prep, a clip's description and the reading of a render's prompt
/// each hold it while they run, so a vision model never shares the RAM with prep's depth and tracking models or with
/// another vision model. The slot is taken before the work's first `await` and given back when it ends.
@MainActor
final class JobWork {
    enum Kind: Hashable { case prep, describe, wish, render }

    struct Key: Hashable {
        var id: UUID
        var kind: Kind

        static func prep(_ id: UUID) -> Key { Key(id: id, kind: .prep) }
        static func describe(_ id: UUID) -> Key { Key(id: id, kind: .describe) }
        static func wish(_ id: UUID) -> Key { Key(id: id, kind: .wish) }
        static func render(_ id: UUID) -> Key { Key(id: id, kind: .render) }
    }

    private var tasks: [Key: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Who holds the heavy work slot.
    private(set) var heavy: Key?
    /// Runs whenever the slot is given back, to start what waits for it.
    var onFree: @MainActor () -> Void = {}

    var isBusy: Bool { heavy != nil }

    /// Takes the slot for `key`; false while someone holds it.
    func take(_ key: Key) -> Bool {
        guard heavy == nil else { return false }
        heavy = key
        return true
    }

    func release(_ key: Key) {
        guard heavy == key else { return }
        heavy = nil
        onFree()
    }

    /// Starts `work` as the task of `key`, holding the slot from now until it ends; false when the slot is taken.
    @discardableResult
    func runHeavy(_ key: Key, _ work: @escaping @MainActor () async -> Void) -> Bool {
        guard take(key) else { return false }
        run(key) {
            defer { self.release(key) }
            await work()
        }
        return true
    }

    /// Starts `work` as the task of `key`; it leaves the list when it ends, unless another took its key meanwhile.
    func run(_ key: Key, _ work: @escaping @MainActor () async -> Void) {
        let token = UUID()
        let task = Task { @MainActor in
            await work()
            if self.tasks[key]?.token == token { self.tasks[key] = nil }
        }
        tasks[key] = (token, task)
    }

    func task(_ key: Key) -> Task<Void, Never>? { tasks[key]?.task }

    func isRunning(_ key: Key) -> Bool { tasks[key] != nil }

    func cancel(_ key: Key) { tasks[key]?.task.cancel() }
}
