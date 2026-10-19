import Foundation

/// A vision model run in a child process: a request per line on its stdin, an answer per line on its stdout. An MLX
/// error, such as a Metal command buffer that hit the GPU's timeout while another app kept the GPU busy, ends the
/// process with `fatalError`, and an error handler can't save it: the next MLX call on the broken arrays fails a
/// precondition. Out here only the child dies, and the description falls through to the next model.
///
/// The process lives for one description, with the weights loaded once; `unload` ends it, which also gives prep all
/// of the model's memory back.
public actor WorkerVisionModel: VisionLanguageModel {
    public nonisolated let name: String
    let executable: URL
    let arguments: [String]
    let isAvailable: @Sendable () -> Bool
    private var running: Running?

    private struct Running {
        let process: Process
        let input: FileHandle
        var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    }

    /// `executable` with `arguments` serves `VisionWorker.serve` on its stdin and stdout.
    public init(
        name: String, executable: URL, arguments: [String], isAvailable: @escaping @Sendable () -> Bool = { true }
    ) {
        (self.name, self.executable, self.arguments, self.isAvailable) = (name, executable, arguments, isAvailable)
    }

    public nonisolated func availability() async -> VisionModelAvailability {
        isAvailable() ? .available : .unavailable("\(name) isn't downloaded.")
    }

    public func respond(to prompt: String, images: [URL], maxTokens: Int) async throws -> String {
        let request = VisionWorker.Request(prompt: prompt, images: images.map(\.path), maxTokens: maxTokens)
        var worker = try running ?? start()
        running = nil
        do {
            try worker.input.write(contentsOf: JSONEncoder().encode(request) + Data("\n".utf8))
        } catch {
            worker.process.terminate()
            throw VisionModelError.failed("\(name) stopped: its process ended (\(Self.reason(worker.process))).")
        }
        let answer = try await withTaskCancellationHandler {
            try await Self.answer(from: &worker.lines)
        } onCancel: { [process = worker.process] in
            process.terminate()
        }
        guard let answer else {
            worker.process.terminate()
            throw VisionModelError.failed("\(name) stopped: its process ended (\(Self.reason(worker.process))).")
        }
        running = worker
        if let error = answer.error { throw VisionModelError.failed(error) }
        return answer.answer ?? ""
    }

    public func unload() async {
        guard let worker = running else { return }
        running = nil
        try? worker.input.close()
        worker.process.terminate()
    }

    private func start() throws -> Running {
        // A write to a child that just died would otherwise end this process too.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let input = Pipe(), output = Pipe()
        (process.standardInput, process.standardOutput) = (input, output)
        try process.run()
        return Running(
            process: process, input: input.fileHandleForWriting,
            lines: output.fileHandleForReading.bytes.lines.makeAsyncIterator())
    }

    /// The next answer line, skipping whatever else the child prints; nil when its output ends.
    private static func answer(
        from lines: inout AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    ) async throws -> VisionWorker.Answer? {
        while let line = try await lines.next() {
            guard line.hasPrefix(VisionWorker.marker) else { continue }
            return try JSONDecoder().decode(
                VisionWorker.Answer.self, from: Data(line.dropFirst(VisionWorker.marker.count).utf8))
        }
        return nil
    }

    private static func reason(_ process: Process) -> String {
        process.waitUntilExit()
        return process.terminationReason == .uncaughtSignal
            ? "signal \(process.terminationStatus)" : "status \(process.terminationStatus)"
    }
}

/// The child's side of `WorkerVisionModel`.
public enum VisionWorker {
    /// Starts each answer line, so a library printing to stdout can't be read as one.
    static let marker = "@@vision "

    struct Request: Codable {
        let prompt: String
        let images: [String]
        let maxTokens: Int
    }

    struct Answer: Codable {
        var answer: String?
        var error: String?
    }

    /// Answers each request line on `input` with `model` until `input` ends.
    public static func serve(
        _ model: any VisionLanguageModel, input: FileHandle = .standardInput, output: FileHandle = .standardOutput
    ) async {
        do {
            for try await line in input.bytes.lines {
                guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
                var answer = Answer()
                do {
                    answer.answer = try await model.respond(
                        to: request.prompt, images: request.images.map { URL(filePath: $0) },
                        maxTokens: request.maxTokens)
                } catch {
                    answer.error = error.localizedDescription
                }
                let encoded = (try? JSONEncoder().encode(answer)) ?? Data(#"{"error":"unencodable"}"#.utf8)
                try output.write(contentsOf: Data(marker.utf8) + encoded + Data("\n".utf8))
            }
        } catch {}
        await model.unload()
    }
}
