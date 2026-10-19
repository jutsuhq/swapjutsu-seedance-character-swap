import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.jutsustudio.swapjutsu", category: "Jobs")

/// What agents' sends took of the daily agent budget: one entry per send the budget let through, with its amount
/// as it was let through. It is kept apart from the renders, so dismissing a render or removing its clip gives
/// nothing back. Saved beside the job folders, atomically; days before yesterday are dropped.
///
/// A send's entry is a reservation that must be on disk before the paid request goes: `add` throws, keeping nothing,
/// when it can't be written, and the send is called off. The renders list their sends too (`RenderOrigin.sends`), and
/// `reconcile` adds back any of those the ledger lacks, so a write that reached `job.json` but not the ledger can't
/// lose spend.
@MainActor
@Observable
final class AgentLedger {
    struct Send: Codable, Equatable {
        var render: UUID
        var sent: Date
        var cents: Int
    }

    private(set) var sends: [Send] = []
    /// Nil keeps the ledger in memory only (the smoke-test launch, which leaves the disk alone).
    private let file: URL?

    init(file: URL?) {
        self.file = file
    }

    /// Reads the saved ledger; false when there is none yet, so the caller can seed it.
    func load() -> Bool {
        guard let file, let data = try? Data(contentsOf: file) else { return false }
        do {
            sends = try Self.decoder.decode([Send].self, from: data)
        } catch {
            logger.error("Unreadable agent spend ledger: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// The first ledger, from the sends the renders list (as the budget was counted before the ledger).
    func seed(_ sends: [Send]) {
        self.sends = sends
        saveLogging()
    }

    /// Adds the sends the renders list that the ledger doesn't have (to the second: both files keep whole seconds).
    func reconcile(_ listed: [Send]) {
        var missing: [Send] = []
        for send in listed {
            let isKept = (sends + missing).contains {
                $0.render == send.render && abs($0.sent.timeIntervalSince(send.sent)) < 1
            }
            if !isKept { missing.append(send) }
        }
        guard !missing.isEmpty else { return }
        logger.notice("The agent spend ledger lacked \(missing.count) send(s) the renders list; added")
        sends += missing
        saveLogging()
    }

    /// Keeps a send. Throws, keeping nothing, when the ledger can't be written: the paid send must not go then.
    func add(_ send: Send) throws {
        let before = sends
        sends.append(send)
        do {
            try save()
        } catch {
            sends = before
            throw error
        }
    }

    /// Gives back the last send of `render`: it never reached the provider. A failed write only keeps it counted.
    func removeLast(of render: UUID) {
        guard let index = sends.lastIndex(where: { $0.render == render }) else { return }
        sends.remove(at: index)
        saveLogging()
    }

    /// What the sends on `day` took, in cents.
    func cents(on day: Date) -> Int {
        sends.filter { Calendar.current.isDate($0.sent, inSameDayAs: day) }.reduce(0) {
            let (sum, overflow) = $0.addingReportingOverflow($1.cents)
            return min(Int.max / 2, overflow ? Int.max : sum)
        }
    }

    private func saveLogging() {
        do {
            try save()
        } catch {
            logger.error("Can't save the agent spend ledger: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save(now: Date = Date()) throws {
        // Yesterday stays, so a clock or time zone change around midnight still finds the day's sends.
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now)) {
            sends.removeAll { $0.sent < yesterday }
        }
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(sends).write(to: file, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
