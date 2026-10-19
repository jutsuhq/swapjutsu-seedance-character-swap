import Testing

@testable import SwapjutsuPrep

/// EdgeTAM's recent memory on plain integers, no Core ML.
struct MemoryBankTests {
    @Test func bankKeepsFifteenPointersAndSixSlots() {
        var bank = MemoryBank<Int>()
        for frame in 0..<40 { bank.append(frame) }
        #expect(bank.pointers == Array((25..<40).reversed()))
        #expect(bank.spatial.map(\.entry) == Array((34..<40).reversed()))
        #expect(bank.spatial.map(\.temporalPosition) == [0, 1, 2, 3, 4, 5])
        #expect(bank.emptied.entries.isEmpty)
    }
}
