import Accelerate
import CoreML
import Foundation

// The bank assembly: which memories and pointers fill which slots of the propagator's inputs.
extension EdgeTAMTracker {
    /// Slots 0–5 hold the six most recent frames, slot 6 the seed; pointer slot 0 the seed, then up to 15
    /// recent frames (`MemoryBank`). Corrections take slots 5 and 4 and pointer slots 1 and 2 (`BankLayout`).
    ///
    /// One object's propagator inputs, kept from frame to frame: every frame copies its memories and pointers into the
    /// same arrays. Which slots are filled depends only on how many conditioning, spatial and pointer entries there
    /// are (`occupancy`); while that stays, the attention bias stays and every filled slot is overwritten. When it
    /// changes, all four start over as freshly made arrays would (zeros, bias −30000), so the inputs are the same as
    /// building them anew each frame.
    ///
    /// Only the community propagator reads the bias. Our v1.1 propagator takes it but its graph does not use it, so
    /// there the empty slots are attended as zeros. Masking them as SAM 2 does (the v1.2 masked propagator, or
    /// repeating the filled slots into the empty ones, which gives the same attention) is worse on the ground truth:
    /// benchmarks/README.md, Section 7.16.
    struct Bank {
        let spatial: MLMultiArray
        let positions: MLMultiArray
        let pointers: MLMultiArray
        let bias: MLMultiArray
    }

    final class BankInputs {
        var arrays: Bank?
        var occupancy: [Int] = []
    }

    /// Each memory's slot and temporal position, and each pointer's slot (`BankLayout`).
    private static func layout(
        _ object: Object, place: (Memory, Int, Int) -> Void, point: (MLMultiArray, Int) -> Void
    ) {
        let conditioning = Self.conditioning(object)
        let spatial = object.recent.spatial(BankLayout.spatialSlots - conditioning.count)
        for s in BankLayout.spatial(conditioning: conditioning.count, recent: spatial.count) {
            switch s.source {
            case .conditioning(let i): place(conditioning[i].memory, s.slot, BankLayout.conditioningPosition)
            case .recent(let i): place(spatial[i].entry.memory, s.slot, spatial[i].temporalPosition)
            }
        }
        let recent = object.recent.pointers
        for p in BankLayout.pointers(conditioning: conditioning.count, recent: recent.count) {
            switch p.source {
            case .conditioning(let i): point(conditioning[i].pointer, p.slot)
            case .recent(let i): point(recent[i].pointer, p.slot)
            }
        }
    }

    /// The seed and the corrections.
    private static func conditioning(_ object: Object) -> [(memory: Memory, pointer: MLMultiArray)] {
        object.conditioning.entries.map(\.entry)
    }

    static func bank(_ object: Object) throws -> Bank {
        let tokens = 512 * 64
        let conditioning = Self.conditioning(object).count
        let occupancy = [
            conditioning, object.recent.spatial(BankLayout.spatialSlots - conditioning).count,
            object.recent.pointers.count,
        ]
        var kept = true
        if object.bank.arrays == nil || object.bank.occupancy != occupancy {
            object.bank.arrays = Bank(
                spatial: try array([1, 7, 512, 64]), positions: try array([1, 7, 512, 64]),
                pointers: try array([1, 16, 256]), bias: try array([1, 1, 1, 3648], fill: -30000))
            object.bank.occupancy = occupancy
            kept = false
        }
        guard let arrays = object.bank.arrays else { throw PrepError.model("no EdgeTAM bank") }
        let (bank, positions, pointers, bias) = (arrays.spatial, arrays.positions, arrays.pointers, arrays.bias)
        var sum = [Float](repeating: 0, count: tokens)
        func place(_ memory: Memory, slot: Int, tpos: Int) {
            copy(memory.features, into: bank, at: slot * tokens, count: tokens)
            // Positions + temporal encoding, in Float as the model's own half → float → half.
            memory.positions.withUnsafeBufferPointer(ofType: Float16.self) { p in
                positions.withUnsafeMutableBufferPointer(ofType: Float16.self) { b, _ in
                    sum.withUnsafeMutableBufferPointer { f in
                        guard let source = p.baseAddress, let target = b.baseAddress, let floats = f.baseAddress
                        else { return }
                        Self.floats(from: source, into: floats, count: tokens)
                        vDSP_vadd(floats, 1, object.temporal[tpos], 1, floats, 1, vDSP_Length(tokens))
                        halves(from: floats, into: target + slot * tokens, count: tokens)
                    }
                }
            }
            if !kept {
                bias.withUnsafeMutableBufferPointer(ofType: Float16.self) { b, _ in
                    b.baseAddress.map { ($0 + slot * 512).update(repeating: 0, count: 512) }
                }
            }
        }
        func point(_ pointer: MLMultiArray, slot: Int) {
            copy(pointer, into: pointers, at: slot * 256, count: 256)
            guard !kept else { return }
            bias.withUnsafeMutableBufferPointer(ofType: Float16.self) { b, _ in
                b.baseAddress.map { ($0 + 3584 + slot * 4).update(repeating: 0, count: 4) }
            }
        }
        layout(object, place: { place($0, slot: $1, tpos: $2) }, point: { point($0, slot: $1) })
        return arrays
    }
}
