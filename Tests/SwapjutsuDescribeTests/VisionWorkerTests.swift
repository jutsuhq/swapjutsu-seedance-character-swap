import Foundation
import Testing

@testable import SwapjutsuDescribe

/// A model in a child process: its answers come back through the pipe, and a child that dies, as one does on an MLX
/// error, is a failed answer the Describer falls through, not the end of the app.
@Suite struct VisionWorkerTests {
    /// A shell child: `script` runs with each request line in `$l`.
    static func child(_ name: String, _ script: String) -> WorkerVisionModel {
        WorkerVisionModel(
            name: name, executable: URL(filePath: "/bin/sh"), arguments: ["-c", "while read l; do \(script); done"])
    }

    @Test func answersComeBackFromOneChild() async throws {
        let model = Self.child("Echo", #"echo noise; echo "@@vision {\"answer\":\"ok $$\"}""#)
        let first = try await model.respond(to: "a", images: [], maxTokens: 10)
        let second = try await model.respond(to: "b", images: [], maxTokens: 10)
        #expect(first.hasPrefix("ok ") && first == second)
        await model.unload()
    }

    @Test func aChildThatDiesIsAFailedAnswer() async throws {
        let model = Self.child("Crash", "kill -TRAP $$")
        await #expect(throws: VisionModelError.self) { try await model.respond(to: "a", images: [], maxTokens: 10) }
        // The next answer starts a new child.
        await #expect(throws: VisionModelError.self) { try await model.respond(to: "a", images: [], maxTokens: 10) }
    }

    @Test func theDescriberFallsThroughADeadChild() async throws {
        let input = DescribeInput(characters: [URL(filePath: "/c1.jpg")], keyframes: [], beats: [], seconds: 5)
        let next = ScriptedModel("System") { DescriberTests.answer($0) }
        let description = try #require(
            await Describer(models: [Self.child("Crash", "kill -TRAP $$"), next]).describe(input))
        #expect(description.source == "System")
    }

    @Test func serveAnswersEachLine() async throws {
        let requests = Pipe(), answers = Pipe()
        let model = ScriptedModel("Local") { "said \($0)" }
        let request = #"{"prompt":"hi","images":[],"maxTokens":5}"# + "\n"
        try requests.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        try requests.fileHandleForWriting.close()
        await VisionWorker.serve(model, input: requests.fileHandleForReading, output: answers.fileHandleForWriting)
        try answers.fileHandleForWriting.close()
        let out = String(decoding: answers.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out == VisionWorker.marker + #"{"answer":"said hi"}"# + "\n")
        #expect(model.unloads == 1)
    }
}
