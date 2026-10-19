import Foundation
import Testing

@testable import SwapjutsuApp

/// Library's Export never loses a file: not the result, not what the destination held before.
struct ResultExporterTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-export-\(UUID().uuidString)")

    func file(_ name: String, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func text(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    @Test func exportingOntoTheResultItselfIsRefusedAndKeepsIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try file("final.mp4", "result")
        await #expect(throws: ResultExporter.Failure.self) { try await ResultExporter.export(result, to: result) }
        let sameFolder = URL(filePath: folder.path + "/./final.mp4")
        await #expect(throws: ResultExporter.Failure.self) { try await ResultExporter.export(result, to: sameFolder) }
        #expect(try text(result) == "result")
    }

    @Test func aFailedCopyKeepsTheOldDestination() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = try file("export.mp4", "old")
        let missing = folder.appending(path: "gone.mp4")
        await #expect(throws: (any Error).self) { try await ResultExporter.export(missing, to: target) }
        #expect(try text(target) == "old")
    }

    @Test func theResultReplacesOrCreatesTheDestination() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try file("final.mp4", "result")
        let existing = try file("export.mp4", "old")
        try await ResultExporter.export(result, to: existing)
        #expect(try text(existing) == "result" && text(result) == "result")
        let new = folder.appending(path: "new.mp4")
        try await ResultExporter.export(result, to: new)
        #expect(try text(new) == "result")
    }
}
