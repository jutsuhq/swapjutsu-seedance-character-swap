import CryptoKit
import Foundation
import SwapjutsuPrep
import Testing

@testable import SwapjutsuApp

/// A model copy is used only when every file matches its pinned size and hash: a cut-off or damaged file is caught
/// and fetched again, and a bad download never replaces the copy. Stand-in files, no network.
struct ModelFilesTests {
    private static let contents = ["a.mlpackage/Manifest.json": "manifest", "a.mlpackage/weight.bin": "weights"]

    @Test func aCopyCountsOnlyWithEveryFileAtItsPinnedSize() throws {
        let spec = Spec()
        defer { spec.remove() }
        try spec.write(to: spec.files.standard, except: "a.mlpackage/weight.bin")
        #expect(!spec.files.isComplete(spec.files.standard))
        try spec.write("weight", at: "a.mlpackage/weight.bin", in: spec.files.standard)
        #expect(!spec.files.isComplete(spec.files.standard))
        try spec.write(to: spec.files.standard)
        #expect(spec.files.isComplete(spec.files.standard) && spec.files.isIntact(spec.files.standard))
    }

    @Test func aDamagedFileOfTheRightSizeFailsTheIntegrityCheck() throws {
        let spec = Spec()
        defer { spec.remove() }
        try spec.write(to: spec.files.standard)
        try spec.write("WEIGHTS", at: "a.mlpackage/weight.bin", in: spec.files.standard)
        #expect(spec.files.isComplete(spec.files.standard))
        #expect(!spec.files.isIntact(spec.files.standard))
    }

    @Test func installReplacesADamagedCopyAndItsCompiledModel() async throws {
        let spec = Spec(standardName: "a.mlpackage")
        defer { spec.remove() }
        try spec.write(to: spec.files.standard)
        try spec.write("WEIGHTS", at: "a.mlpackage/weight.bin", in: spec.files.standard)
        let compiled = spec.files.standard.deletingPathExtension().appendingPathExtension("mlmodelc")
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        let url = try await spec.files.install(log: { _ in })
        #expect(url == spec.files.standard && spec.files.isIntact(url))
        #expect(!FileManager.default.fileExists(atPath: compiled.path(percentEncoded: false)))
        #expect(spec.downloads.count == 2)
    }

    @Test func installCopiesMatchingCheckoutFilesAndDownloadsTheRest() async throws {
        let spec = Spec()
        defer { spec.remove() }
        try spec.write(to: #require(spec.files.checkout))
        try spec.write("WEIGHTS", at: "a.mlpackage/weight.bin", in: #require(spec.files.checkout))
        _ = try await spec.files.install(log: { _ in })
        #expect(spec.files.isIntact(spec.files.standard))
        #expect(spec.downloads.links.map(\.lastPathComponent) == ["weight.bin"])
    }

    @Test func aDamagedDownloadIsNotInstalled() async throws {
        let spec = Spec(serving: ["a.mlpackage/weight.bin": "WEIGHTS"])
        defer { spec.remove() }
        await #expect(throws: ModelFilesError.self) { try await spec.files.install(log: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: spec.files.standard.path(percentEncoded: false)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: spec.root.path(percentEncoded: false))
        #expect(!leftovers.contains { $0.hasPrefix(".download-") })
    }

    @MainActor
    @Test func aDamagedCopyIsFetchedAgainBeforeItIsLoaded() async throws {
        let spec = Spec()
        defer { spec.remove() }
        try spec.write(to: spec.files.standard)
        try spec.write("WEIGHTS", at: "a.mlpackage/weight.bin", in: spec.files.standard)
        let model = LocalModel<Int>(files: spec.files) { _ in 1 }
        #expect(model.phase == .ready)
        let url = try await model.ensure()
        #expect(spec.files.isIntact(url) && spec.downloads.count == 2)
        _ = try await model.ensure()
        #expect(spec.downloads.count == 2)
    }

    @Test func aZipIsDownloadedOnceAndUnpackedIntoPlace() async throws {
        let spec = Spec(zipped: true)
        defer { spec.remove() }
        let url = try await spec.files.install(log: { _ in })
        #expect(spec.files.isIntact(url))
        #expect(spec.downloads.links.map(\.lastPathComponent) == ["models.zip"])
    }

    @Test func aZipWithTheWrongHashIsNotUnpacked() async throws {
        let spec = Spec(serving: ["a.mlpackage/weight.bin": "WEIGHTS"], zipped: true)
        defer { spec.remove() }
        await #expect(throws: ModelFilesError.damaged("test model", "models.zip")) {
            try await spec.files.install(log: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: spec.files.standard.path(percentEncoded: false)))
    }

    @Test func aZipWithADamagedFileIsNotInstalled() async throws {
        let spec = Spec(serving: ["a.mlpackage/weight.bin": "WEIGHTS"], zipped: true, pinsServedZip: true)
        defer { spec.remove() }
        await #expect(throws: ModelFilesError.damaged("test model", "a.mlpackage/weight.bin")) {
            try await spec.files.install(log: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: spec.files.standard.path(percentEncoded: false)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: spec.root.path(percentEncoded: false))
        #expect(!leftovers.contains { $0.hasPrefix(".download-") })
    }

    /// An older conversion in the app's folder, with its compiled models, fails the pins and is replaced whole.
    @Test func aZipReplacesAnOlderCopyWithNothingLeftOfIt() async throws {
        let spec = Spec(zipped: true)
        defer { spec.remove() }
        try spec.write("old manifest", at: "a.mlpackage/Manifest.json", in: spec.files.standard)
        try spec.write("old weights", at: "a.mlpackage/weight.bin", in: spec.files.standard)
        try spec.write("compiled", at: "a.mlmodelc/model.mil", in: spec.files.standard)
        #expect(!spec.files.isComplete(spec.files.standard))
        _ = try await spec.files.install(log: { _ in })
        #expect(spec.files.isIntact(spec.files.standard))
        let left = try FileManager.default.subpathsOfDirectory(atPath: spec.files.standard.path(percentEncoded: false))
        #expect(Set(left) == ["a.mlpackage", "a.mlpackage/Manifest.json", "a.mlpackage/weight.bin"])
    }

    @Test func aZippedModelIsCopiedFromACheckoutThatHasEveryFile() async throws {
        let spec = Spec(zipped: true)
        defer { spec.remove() }
        try spec.write(to: #require(spec.files.checkout))
        _ = try await spec.files.install(log: { _ in })
        #expect(spec.files.isIntact(spec.files.standard) && spec.downloads.links.isEmpty)
    }

    @Test func edgeTAMPinsEveryFileOfItsFourPackagesAndTheReleaseZip() throws {
        let edgeTAM = ModelFiles.edgeTAM
        let roots = Set(edgeTAM.files.map { $0.path.components(separatedBy: "/")[0] })
        #expect(roots == Set(EdgeTAMModels.names.map { "\($0).mlpackage" } + ["LICENSE", "NOTICE"]))
        #expect(edgeTAM.files.count == 14)
        let zip = try #require(edgeTAM.zip)
        #expect(edgeTAM.base.hasPrefix("https://github.com/jutsuhq/edgetam-coreml/releases/download/v"))
        #expect(zip.sha256.count == 64 && zip.path.hasSuffix(".zip"))
        #expect(ModelFiles.depth.zip == nil)
        let depth = ModelFiles.depth.base
        #expect(depth.contains("/resolve/") && !depth.contains("/resolve/main/"))
        for spec in [edgeTAM, .depth] { #expect(spec.files.allSatisfy { $0.sha256.count == 64 }) }
    }

    /// Two stand-in files, an app copy and a checkout under one temporary folder, and a download that serves the
    /// pinned contents (or `serving` instead) and records what it was asked for. `zipped` serves them as one
    /// `models.zip` instead, pinned to the zip of the pinned contents, or with `pinsServedZip` to the one it serves.
    private struct Spec {
        let root = FileManager.default.temporaryDirectory.appending(path: "swapjutsu-models-\(UUID().uuidString)")
        let downloads = Downloads()
        let files: ModelFiles

        init(
            standardName: String = "Models", serving: [String: String] = [:], zipped: Bool = false,
            pinsServedZip: Bool = false
        ) {
            let served = contents.merging(serving) { $1 }
            let root = root, downloads = downloads
            let pinnedZip = zipped ? Self.zip(contents, in: root) : Data()
            let servedZip = zipped && !serving.isEmpty ? Self.zip(served, in: root) : pinnedZip
            files = ModelFiles(
                title: "test model", megabytes: 1, base: "https://models.invalid/resolve/abc",
                files: contents.keys.sorted().map { Self.pin($0, Data(contents[$0, default: ""].utf8)) },
                standard: root.appending(path: "Support/\(standardName)"),
                checkout: root.appending(path: "Checkout/Models"),
                zip: zipped ? Self.pin("models.zip", pinsServedZip ? servedZip : pinnedZip) : nil,
                download: { link in
                    downloads.record(link)
                    let path = link.path(percentEncoded: false).replacingOccurrences(of: "/resolve/abc/", with: "")
                    let file = root.appending(path: "served-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try (path == "models.zip" ? servedZip : Data(served[path, default: ""].utf8)).write(to: file)
                    return file
                })
        }

        private static func pin(_ path: String, _ data: Data) -> ModelFiles.File {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ModelFiles.File(path: path, size: data.count, sha256: hash)
        }

        /// A zip of `files` at its root, as the release is, made with `ditto`.
        private static func zip(_ files: [String: String], in root: URL) -> Data {
            let folder = root.appending(path: "zip-\(UUID().uuidString)")
            let archive = folder.appendingPathExtension("zip")
            defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: archive) }
            for (path, text) in files {
                let url = folder.appending(path: path)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: url)
            }
            let ditto = Process()
            ditto.executableURL = URL(filePath: "/usr/bin/ditto")
            ditto.arguments = [
                "-c", "-k", "--norsrc", folder.path(percentEncoded: false), archive.path(percentEncoded: false),
            ]
            try? ditto.run()
            ditto.waitUntilExit()
            return (try? Data(contentsOf: archive)) ?? Data()
        }

        func write(to copy: URL, except skipped: String? = nil) throws {
            for (path, text) in contents where path != skipped { try write(text, at: path, in: copy) }
        }

        func write(_ text: String, at path: String, in copy: URL) throws {
            let url = copy.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private final class Downloads: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URL] = []
        var links: [URL] { lock.withLock { recorded } }
        var count: Int { links.count }
        func record(_ link: URL) { lock.withLock { recorded.append(link) } }
    }
}
