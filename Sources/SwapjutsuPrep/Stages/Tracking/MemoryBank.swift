import Foundation

/// An object's recent memory: its last tracked frames, newest last, and which of them fill the bank.
struct MemoryBank<Entry> {
    /// Six recent spatial slots (the seed is the seventh) and fifteen recent object pointers (the seed's is the
    /// sixteenth), as EdgeTAM was trained.
    static var spatialSlots: Int { 6 }
    static var pointerSlots: Int { 15 }

    private(set) var entries: [Entry] = []

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.pointerSlots { entries.removeFirst() }
    }

    /// Spatial slots 0–5: the most recent frames, newest first, each with its temporal position (0-based here as the
    /// slot: frames back minus one).
    var spatial: [(entry: Entry, temporalPosition: Int)] { spatial(Self.spatialSlots) }

    /// The `limit` most recent, as `spatial` (fewer slots when corrections take some, `BankLayout`).
    func spatial(_ limit: Int) -> [(entry: Entry, temporalPosition: Int)] {
        entries.reversed().prefix(limit).enumerated().map { ($1, $0) }
    }

    /// Pointer slots 1–15, newest first (pointers carry no temporal position in EdgeTAM).
    var pointers: [Entry] { Array(entries.reversed().prefix(Self.pointerSlots)) }

    /// An empty bank.
    var emptied: Self { Self() }
}
