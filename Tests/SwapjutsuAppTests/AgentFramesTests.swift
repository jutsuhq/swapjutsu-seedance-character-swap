import Foundation
import ImageIO
import SwapjutsuAgent
import Testing

@testable import SwapjutsuApp

/// frames on a finished render of the 0.5 s, 64 × 64 test clip: one row per moment, the clip, control.mp4 and the
/// render side by side, in a folder of its own per call.
extension AgentRenderTests {
    @Test func framesPutsTheClipControlAndRenderSideBySide() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: [.success(try await output())]))
        budget.dollars = 1
        let job = try await prepared(store)
        for file in [job.prepared, job.control] { try FileManager.default.copyItem(at: try await JobStoreTests().clip(), to: file) }
        let sent = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        await store.settle(job)
        let done = try #require(try await commands.run(.clips(ClipsCommand(clip: id(job)))).renders?.first)
        #expect(done.next?.contains("frames") == true)

        let frames = try #require(try await commands.run(.frames(FramesCommand(render: sent.id, count: 2))).frames)
        #expect(frames.frames.map(\.seconds) == [0.13, 0.38] && frames.columns == ["source", "control", "render"])
        for frame in frames.frames {
            for file in [frame.source, frame.control, frame.render] { #expect(FileManager.default.fileExists(atPath: file)) }
        }
        let sheet = try #require(CGImageSourceCreateWithURL(URL(filePath: frames.sheet) as CFURL, nil))
        let size = try #require(CGImageSourceCopyPropertiesAtIndex(sheet, 0, nil) as? [CFString: Any])
        #expect(size[kCGImagePropertyPixelWidth] as? Int == 3 * 360 + 4 * 8)
        #expect(size[kCGImagePropertyPixelHeight] as? Int == 2 * 360 + 3 * 8)

        let again = try #require(try await commands.run(.frames(FramesCommand(render: sent.id, seconds: [0]))).frames)
        #expect(again.folder != frames.folder && again.frames.count == 1)
    }

    @Test func framesNeedsAFinishedRenderAndTimesWithinTheClip() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, commands) = make(FakeProvider(statuses: []))
        let job = try await prepared(store)
        let held = try #require(try await commands.run(.render(request(job, "r", maxCost: 1))).renders?.first)
        await #expect(throws: AgentError.Code.badRequest) {
            try await code { try await commands.run(.frames(FramesCommand(render: held.id))) }
        }
        await #expect(throws: AgentError.Code.noSuchClip) {
            try await code { try await commands.run(.frames(FramesCommand(render: UUID().uuidString))) }
        }

        let clip = 0.5
        for bad in [
            FramesCommand(render: "r", seconds: [0.5]), FramesCommand(render: "r", seconds: []),
            FramesCommand(render: "r", seconds: [-1]), FramesCommand(render: "r", count: 0),
            FramesCommand(render: "r", count: FramesCommand.maxCount + 1),
        ] {
            #expect(throws: AgentError.self) { try AgentCommands.times(bad, duration: clip) }
        }
        #expect(try AgentCommands.times(FramesCommand(render: "r"), duration: 8) == [1, 3, 5, 7])
        #expect(try AgentCommands.times(FramesCommand(render: "r", seconds: [0.49]), duration: clip) == [0.49])
    }
}
