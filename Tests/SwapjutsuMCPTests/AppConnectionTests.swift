import Foundation
import SwapjutsuAgent
import Testing

@testable import SwapjutsuMCP

/// The binary finds the socket from where it sits, without the app's help.
struct AppConnectionTests {
    let home = URL(filePath: "/home/someone")

    /// `<tmp>/Swapjutsu.app/Contents/Helpers/swapjutsu` with an Info.plist naming `group`.
    func bundle(group: String) throws -> (app: URL, helper: URL) {
        let app = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/Swapjutsu.app")
        let helpers = app.appending(path: "Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.jutsustudio.Swapjutsu", AgentSocket.appGroupKey: group]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let helper = helpers.appending(path: "swapjutsu")
        FileManager.default.createFile(atPath: helper.path(percentEncoded: false), contents: Data())
        return (app, helper)
    }

    @Test func bundledFindsItsAppGroupsSocket() throws {
        let (app, helper) = try bundle(group: "ABCDE12345.com.jutsustudio.swapjutsu")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let location = AppConnection.locate(executable: helper, environment: [:], home: home)
        #expect(
            location
                == .bundled(
                    app: app.resolvingSymlinksInPath(), bundleID: "com.jutsustudio.Swapjutsu",
                    socket: URL(
                        filePath:
                            "/home/someone/Library/Group Containers/ABCDE12345.com.jutsustudio.swapjutsu/agent.sock"
                    )))
    }

    @Test func aSymlinkToTheBundledBinaryStillFindsTheApp() throws {
        let (app, helper) = try bundle(group: "ABCDE12345.com.jutsustudio.swapjutsu")
        let folder = app.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "swapjutsu")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        guard case .bundled(_, let bundleID, _) = AppConnection.locate(executable: link, environment: [:], home: home)
        else {
            Issue.record("not found through the symlink")
            return
        }
        #expect(bundleID == "com.jutsustudio.Swapjutsu")
    }

    @Test func aBuildWithoutATeamHasNoSocket() async throws {
        let (app, helper) = try bundle(group: ".com.jutsustudio.swapjutsu")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let location = AppConnection.locate(executable: helper, environment: [:], home: home)
        guard case .bundled(_, _, nil) = location else {
            Issue.record("expected no socket, got \(location)")
            return
        }
        let response = await AppConnection(location: location).send(.capabilities)
        #expect(response.error?.code == .needsTeamBuild)
    }

    @Test func unbundledUsesTheSwiftRunSocketAndTheVariableWins() {
        let unbundled = URL(filePath: "/src/swapjutsu/.build/debug/swapjutsu-cli")
        #expect(
            AppConnection.locate(executable: unbundled, environment: [:], home: home)
                == .socket(URL(filePath: "/home/someone/Library/Application Support/Swapjutsu/agent.sock")))
        #expect(
            AppConnection.locate(
                executable: unbundled, environment: [AppConnection.socketVariable: "/tmp/x.sock"], home: home)
                == .socket(URL(filePath: "/tmp/x.sock")))
    }

    /// A home folder path of 37 bytes puts the group socket past the 103 bytes of a `sockaddr_un`: it is used as it is.
    /// One past `AgentSocket.maxPathLength` is refused at once with its own code, without starting the app, which
    /// couldn't listen there either.
    @Test func aLongHomeStillFindsItsSocketAndOneTooLongSaysSo() async throws {
        let (app, helper) = try bundle(group: "ABCDE12345.com.jutsustudio.swapjutsu")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let long = URL(filePath: "/home/" + String(repeating: "n", count: 31))
        let location = AppConnection.locate(executable: helper, environment: [:], home: long)
        let socket = try #require(location.socket)
        #expect(socket.path(percentEncoded: false).utf8.count == 110)
        #expect(AgentSocket.fits(socket))

        let tooLong = URL(filePath: "/home/" + String(repeating: "n", count: 200))
        let refused = AppConnection.locate(executable: helper, environment: [:], home: tooLong)
        guard case .bundled(_, let bundleID, let socket?) = refused else {
            Issue.record("expected a bundled socket, got \(refused)")
            return
        }
        // A bundle ID nothing has, so a launch attempt would fail with app_not_started instead.
        let response = await AppConnection(
            location: .bundled(app: app, bundleID: bundleID + ".none", socket: socket)
        ).send(.capabilities)
        #expect(response.error?.code == .socketPathTooLong)
        #expect(response.error?.message.contains("\(socket.path(percentEncoded: false).utf8.count) bytes") == true)
    }

    @Test func aSocketNobodyListensOnSaysHowToStartTheApp() async {
        let socket = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sock")
        let response = await AppConnection(location: .socket(socket)).send(.capabilities)
        #expect(response.error?.code == .notListening)
        #expect(response.error?.next?.contains("-allowAgents YES") == true)
    }
}
