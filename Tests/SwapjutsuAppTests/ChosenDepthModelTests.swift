import Foundation
import Testing

@testable import SwapjutsuApp

/// A depth model chosen in Settings is kept as a security-scoped bookmark, which a sandboxed build can open again
/// after a relaunch; one that no longer resolves is dropped and the app's copy is used.
struct ChosenDepthModelTests {
    @Test func aBookmarkResolvesToTheChosenModel() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let model = scratch.folder.appending(path: "Depth.mlpackage")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        scratch.defaults.set(try DepthModel.depthBookmark(for: model), forKey: AppPaths.depthModelKey)
        let chosen = DepthModel.chosenDepth(in: scratch.defaults, environment: [:])
        #expect(chosen?.resolvingSymlinksInPath() == model.resolvingSymlinksInPath())
        #expect(scratch.defaults.data(forKey: AppPaths.depthModelKey) != nil)
    }

    @Test func aBookmarkThatNoLongerResolvesIsDropped() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        scratch.defaults.set(Data("not a bookmark".utf8), forKey: AppPaths.depthModelKey)
        #expect(DepthModel.chosenDepth(in: scratch.defaults, environment: [:]) == nil)
        #expect(scratch.defaults.object(forKey: AppPaths.depthModelKey) == nil)
    }

    @Test func withoutAChoiceTheDebugVariableIsUsed() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let chosen = DepthModel.chosenDepth(
            in: scratch.defaults, environment: ["SWAPJUTSU_DEPTH_MODEL": "/models/b.mlpackage"])
        #expect(chosen == URL(filePath: "/models/b.mlpackage"))
        #expect(DepthModel.chosenDepth(in: scratch.defaults, environment: [:]) == nil)
    }

    /// Defaults of their own and a temporary folder, so the tests never touch the app's settings.
    private struct Scratch {
        let name = "ChosenDepthModelTests-\(UUID().uuidString)"
        let defaults: UserDefaults
        let folder: URL

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            folder = FileManager.default.temporaryDirectory.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
