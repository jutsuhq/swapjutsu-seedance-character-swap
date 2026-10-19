import CryptoKit
import Foundation

/// Core ML packages the app keeps in Application Support, pinned to one revision (a Hugging Face commit or a GitHub
/// release) with the size and SHA-256 of every file. `scripts/fetch-models.sh` pins the same files for a checkout's
/// `Models/`; keep the two in step.
///
/// A copy counts only when every file has its pinned size (`isComplete`, cheap enough for a view) and, before use,
/// its pinned hash (`isIntact`). `install` fills a temporary folder, from a checkout's `Models/` where its files
/// match, else downloaded file by file or as one pinned zip, checks every file and only then moves the folder into
/// place, so neither a cut-off download nor a damaged file ever passes for the model.
struct ModelFiles: Sendable {
    struct File: Sendable {
        /// Relative to `base` and to the installed copy.
        let path: String
        let size: Int
        let sha256: String
    }

    /// As progress lines and errors name it: "depth model".
    let title: String
    let megabytes: Int
    /// `https://huggingface.co/<repo>/resolve/<revision>/<folder>`, or the release a `zip` is in.
    let base: String
    let files: [File]
    /// The app's copy: a package, or a folder of packages.
    let standard: URL
    /// The same in a checkout's `Models/`, for Debug builds from source; nil in a Release build.
    let checkout: URL?
    /// One zip at `<base>/<path>` that holds every file, pinned like one: downloaded instead of the files unless a
    /// checkout has them all.
    var zip: File? = nil
    /// Fetches one link to a temporary file; tests pass a stand-in.
    var download: @Sendable (URL) async throws -> URL = Self.download

    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Swapjutsu/Models") }

    /// The checkout this file was built from, `#filePath` four folders up. Debug only, so a Release binary carries
    /// no path of the Mac it was built on.
    private static var checkoutModels: URL? {
        #if DEBUG
            URL(filePath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Models")
        #else
            nil
        #endif
    }

    /// Depth Anything V2 Small, Apple's Core ML conversion (Apache-2.0).
    static let depth = ModelFiles(
        title: "depth model", megabytes: 48,
        base: "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/"
            + "cfef6f6f2a70783dedc0bfae40cecbc2052285d3/DepthAnythingV2SmallF16.mlpackage",
        files: [
            File(
                path: "Manifest.json", size: 617,
                sha256: "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"),
            File(
                path: "Data/com.apple.CoreML/model.mlmodel", size: 399_433,
                sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"),
            File(
                path: "Data/com.apple.CoreML/weights/weight.bin", size: 49_419_072,
                sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"),
        ],
        standard: folder.appending(path: "DepthAnythingV2SmallF16.mlpackage"),
        checkout: checkoutModels?.appending(path: "DepthAnythingV2SmallF16.mlpackage"))

    /// EdgeTAM's four video models (Meta, Apache-2.0) in our Core ML conversion, jutsuhq/edgetam-coreml v1.1, in one
    /// folder with the release's LICENSE and NOTICE, which go with every copy.
    static let edgeTAM = ModelFiles(
        title: "tracking model", megabytes: 51,
        base: "https://github.com/jutsuhq/edgetam-coreml/releases/download/v1.1",
        files: [
            package(
                "EdgeTAMVideoImageEncoder",
                manifest: "a1280c7dc52efa77f8f476c74490c333db9ec76bb40649086981b9dd5cc3e74a",
                model: (205_683, "617a8c518d561a1152b04f2d619741002e1b0e83a1a0ea70ea878ad2ed120f03"),
                weights: (9_818_944, "337900984a90039da4d26ad92abc32943ed920b4d8c7434f1ac717e2fbbc108b")),
            package(
                "EdgeTAMVideoInitializer",
                manifest: "d0c76e40b8f183a4963560389d2fccecddca2d368f953f4fe56087206d3508a2",
                model: (143_749, "bf65c24c715684d64422e8f3d58a4309ae92624a28ee0299e3818e402e129d19"),
                weights: (26_240_768, "86d71536e489b5ae5c4388e1213d97921a4e7fc1ef88b76ac2e2e8e51f155a07")),
            package(
                "EdgeTAMVideoMemoryEncoder",
                manifest: "6eca763508e70798da6b1fb62e1632e2c4da76ac352a1a10be203b3fd50a7e95",
                model: (100_672, "b111e7feb0610356ab77fb12c49e6ea1f907278d9465c2707744f4e45db38a1e"),
                weights: (3_890_432, "c8a7cda81c1cd0c4fafc94fd14d755d306fa50750dd8d022f974239601dc6f1d")),
            package(
                "EdgeTAMVideoPropagator",
                manifest: "8cad09783edd4ab5dabca429d9d85df80573a165b2b4b26eb1f0afd4f467a78f",
                model: (260_303, "8fdafe96cd169deaa9cdd84b0d43754c4abac7bea4296a2dcbb80706efa4a07f"),
                weights: (28_279_040, "54667d6f2d4586c67cedfa46fa102c45f85630b1238a7897ef5cc5fdbde3fb06")),
            [
                File(
                    path: "LICENSE", size: 11_357,
                    sha256: "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"),
                File(
                    path: "NOTICE", size: 780,
                    sha256: "e4e5146f34236dc370925b97ce122037d8b0a87c839fefc6d53bfc9dc276159c"),
            ],
        ].flatMap(\.self),
        standard: folder.appending(path: "EdgeTAM"),
        checkout: checkoutModels?.appending(path: "EdgeTAM"),
        zip: File(
            path: "edgetam-coreml-v1.1.zip", size: 51_099_552,
            sha256: "6a4cf09ef7e02f0504155d4f2d949a4882fc764e0fbf773e8f8b11a2f48e07b9"))

    /// The three files of a Core ML package; every Manifest.json of these packages is 617 bytes.
    private static func package(
        _ name: String, manifest: String, model: (Int, String), weights: (Int, String)
    ) -> [File] {
        let root = "\(name).mlpackage"
        return [
            File(path: "\(root)/Manifest.json", size: 617, sha256: manifest),
            File(path: "\(root)/Data/com.apple.CoreML/model.mlmodel", size: model.0, sha256: model.1),
            File(path: "\(root)/Data/com.apple.CoreML/weights/weight.bin", size: weights.0, sha256: weights.1),
        ]
    }

    /// Every file is at `copy` with its pinned size.
    func isComplete(_ copy: URL) -> Bool {
        files.allSatisfy { Self.size(of: copy.appending(path: $0.path)) == $0.size }
    }

    /// Every file is at `copy` with its pinned size and hash. Reads the whole model (about 50 ms for 50 MB), so call
    /// it off the main actor.
    func isIntact(_ copy: URL) -> Bool {
        files.allSatisfy { Self.matches(copy.appending(path: $0.path), $0) }
    }

    /// Puts a checked copy at `standard`, replacing whatever is there (and the compiled model Core ML kept next to
    /// it).
    func install(log: @Sendable (String) -> Void) async throws -> URL {
        let staging = standard.deletingLastPathComponent()
            .appending(path: ".download-\(UUID().uuidString)/\(standard.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let isInCheckout =
            checkout.map { root in files.allSatisfy { Self.matches(root.appending(path: $0.path), $0) } } == true
        log(
            isInCheckout
                ? "Copying the \(title) into Application Support"
                : "Downloading the \(title) (\(megabytes) MB, once)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        if let zip, !isInCheckout {
            let archive = try await fetch(zip)
            defer { try? FileManager.default.removeItem(at: archive) }
            try await unzip(archive, named: zip.path, into: staging)
        } else {
            for file in files {
                let destination = staging.appending(path: file.path)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let local = checkout?.appending(path: file.path), Self.matches(local, file) {
                    try FileManager.default.copyItem(at: local, to: destination)
                } else {
                    try FileManager.default.moveItem(at: try await fetch(file), to: destination)
                }
            }
        }
        for file in files where !Self.matches(staging.appending(path: file.path), file) {
            throw ModelFilesError.damaged(title, file.path)
        }
        try? FileManager.default.removeItem(at: standard)
        if standard.pathExtension == "mlpackage" {
            try? FileManager.default.removeItem(
                at: standard.deletingPathExtension().appendingPathExtension("mlmodelc"))
        }
        try FileManager.default.moveItem(at: staging, to: standard)
        return standard
    }

    /// `<base>/<path>` downloaded to a temporary file with its pinned size and hash.
    private func fetch(_ file: File) async throws -> URL {
        guard let link = URL(string: "\(base)/\(file.path)") else { throw URLError(.badURL) }
        let temporary: URL
        do { temporary = try await download(link) } catch { throw ModelFilesError.download(title, file.path) }
        guard Self.matches(temporary, file) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ModelFilesError.damaged(title, file.path)
        }
        return temporary
    }

    /// `ditto`, which the App Sandbox lets the app run: the child inherits the sandbox, so it reads and writes the
    /// container as the app does.
    private func unzip(_ archive: URL, named name: String, into folder: URL) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path(percentEncoded: false), folder.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw ModelFilesError.damaged(title, name) }
    }

    @Sendable static func download(_ link: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: link)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return temporary
    }

    /// The first of `files` missing from `folder` or different from its pin, nil when every one matches. Reads them
    /// all, so call it off the main actor.
    static func firstMismatch(_ files: [File], in folder: URL) -> String? {
        files.first { !matches(folder.appending(path: $0.path), $0) }?.path
    }

    /// The size of the file itself, through a link (a Hugging Face snapshot links each file to its blob).
    private static func size(of url: URL) -> Int? {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    private static func matches(_ url: URL, _ file: File) -> Bool {
        guard size(of: url) == file.size, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
}

enum ModelFilesError: LocalizedError, Equatable {
    case download(String, String)
    case damaged(String, String)

    var errorDescription: String? {
        switch self {
        case .download(let title, let file):
            "Couldn't download the \(title) (\(file)). Check the connection and prepare again."
        case .damaged(let title, let file):
            "The downloaded \(title) is damaged (\(file)). Prepare again to download it again."
        }
    }
}
