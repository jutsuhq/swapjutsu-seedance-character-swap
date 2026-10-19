import Foundation

/// A client for ComfyUI's own server API, the one its web UI uses: a ComfyUI the person runs themselves, on this Mac,
/// another Mac or a GPU box on the network. Separate from `ComfyClient` (Comfy Cloud API v2), whose jobs, assets and
/// idempotency keys this API doesn't have.
///
/// Read from ComfyUI's `server.py` at commit c06bf5f569d268b80076e5f44126f87cdf835869:
/// - `POST /upload/image`, multipart `image` + `type=input` + `overwrite`: also takes videos, into the input folder.
/// - `POST /prompt {prompt, prompt_id, client_id}` → `{prompt_id, number, node_errors}`; a 400 carries `error` and
///   `node_errors`. A client-chosen `prompt_id` (a lowercase UUID) is accepted since 2025; older servers mint one.
/// - `GET /queue` (running and pending prompts) and `GET /history/{id}` (finished ones: status and outputs).
/// - `GET /view?filename=&subfolder=&type=output` downloads an output.
/// - `POST /interrupt {prompt_id}` stops that prompt only if it is the one running; `POST /queue {delete: [id]}`
///   drops a pending one.
/// - `GET /object_info` lists every node class with its inputs, model loaders with the files they can load.
///
/// `token`, when set, goes as `Authorization: Bearer` for a ComfyUI behind a reverse proxy; ComfyUI itself has none.
public struct ComfyUIClient: Sendable {
    public static let local: URL = {
        guard let url = URL(string: "http://127.0.0.1:8188") else { preconditionFailure("Invalid local ComfyUI URL") }
        return url
    }()

    public let baseURL: URL
    public let token: String?
    public let session: URLSession
    public let retry: RetryPolicy
    public let sleep: Sleeper

    public init(
        baseURL: URL = local, token: String? = nil, session: URLSession = .shared, retry: RetryPolicy = .init(),
        sleep: @escaping Sleeper = taskSleep
    ) {
        self.baseURL = baseURL
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
        self.retry = retry
        self.sleep = sleep
    }

    // MARK: Calls

    /// `POST /upload/image` into the input folder under `name`, replacing a file of that name. The same name and bytes
    /// give the same result, so a dropped upload is sent again. Returns the name a loader node takes.
    public func upload(_ file: URL, as name: String) async throws -> String {
        let boundary = "comfykit-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appending(path: "\(boundary).multipart")
        try Self.writeMultipart(
            to: body, boundary: boundary, file: file, name: name,
            contentType: ComfyClient.contentType(of: file), fields: [("type", "input"), ("overwrite", "true")])
        defer { try? FileManager.default.removeItem(at: body) }
        var request = try request("POST", "/upload/image")
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let uploaded: UploadedFile = try decode(try await send(request, body: .file(body), repeatable: true))
        return uploaded.subfolder.isEmpty ? uploaded.name : "\(uploaded.subfolder)/\(uploaded.name)"
    }

    /// `POST /prompt`. Not idempotent: it is sent again only when it never reached the server. A refused graph
    /// (`node_errors`) throws `.invalidWorkflow` with what ComfyUI said about each node.
    public func queue(_ workflow: Workflow, promptID: String, clientID: String) async throws -> String {
        let payload: [String: JSONValue] = [
            "prompt": .object(workflow.nodes), "prompt_id": .string(promptID), "client_id": .string(clientID),
        ]
        var request = try request("POST", "/prompt")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: .data(try JSONEncoder().encode(payload)), repeatable: false)
        let queued: QueuedPrompt = try decode(data)
        return queued.promptID
    }

    /// `GET /queue`: the prompts running and waiting.
    public func queueState() async throws -> QueueState {
        let data = try await send(try request("GET", "/queue"), body: nil, repeatable: true)
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data).object else {
            throw ComfyError.malformedResponse("ComfyUI's queue isn't a JSON object.")
        }
        // Each entry is `[number, prompt_id, prompt, extra_data, outputs, …]`.
        func ids(_ key: String) -> [String] {
            guard case .array(let items)? = object[key] else { return [] }
            return items.compactMap { item in
                guard case .array(let fields) = item, fields.count > 1 else { return nil }
                return fields[1].string
            }
        }
        return QueueState(running: ids("queue_running"), pending: ids("queue_pending"))
    }

    /// `GET /history/{id}`: nil until the prompt finished (ComfyUI writes history only then).
    public func history(_ promptID: String) async throws -> PromptHistory? {
        let data = try await send(try request("GET", "/history/\(promptID)"), body: nil, repeatable: true)
        let entries: [String: PromptHistory] = try decode(data)
        return entries[promptID]
    }

    /// `GET /view` of an output, streamed to `destination`.
    public func download(_ output: OutputFile, to destination: URL) async throws {
        guard var components = URLComponents(url: try url("/view"), resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            .init(name: "filename", value: output.filename), .init(name: "subfolder", value: output.subfolder),
            .init(name: "type", value: output.type),
        ]
        guard let link = components.url else { throw URLError(.badURL) }
        var request = authorized(URLRequest(url: link, timeoutInterval: 600), method: "GET")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (file, response) = try await session.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: file, to: destination)
                    return
                }
                let error = Self.error(status: status, body: Data())
                guard status >= 500, attempt < retry.maxAttempts else { throw error }
            } catch let error as URLError {
                guard error.code != .cancelled, attempt < retry.maxAttempts else { throw error }
            }
            try await sleep(retry.delay(attempt))
        }
    }

    /// Stops `promptID` wherever it is: dropped from the queue if it waits, interrupted if it runs, nothing if it
    /// already finished. The interrupt names the prompt and is sent only while that prompt runs, since a ComfyUI from
    /// before targeted interrupts stops whatever runs, another person's render on a shared box included.
    public func cancel(_ promptID: String) async throws {
        let state = try await queueState()
        if state.pending.contains(promptID) {
            try await post("/queue", ["delete": [.string(promptID)]])
        } else if state.running.contains(promptID) {
            try await post("/interrupt", ["prompt_id": .string(promptID)])
        }
    }

    private func post(_ path: String, _ json: JSONValue) async throws {
        var request = try request("POST", path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await send(request, body: .data(try JSONEncoder().encode(json)), repeatable: true)
    }

    /// `GET /object_info`: node class → its definition (`input.required`, `input.optional`, …).
    public func objectInfo() async throws -> [String: JSONValue] {
        var request = try request("GET", "/object_info")
        // Every node of the install is in it; a box with many custom nodes takes a while.
        request.timeoutInterval = 60
        let data = try await send(request, body: nil, repeatable: true)
        guard let object = try? JSONDecoder().decode(JSONValue.self, from: data).object else {
            throw ComfyError.malformedResponse("ComfyUI's object_info isn't a JSON object.")
        }
        return object
    }

    // MARK: Transport

    enum Body {
        case data(Data)
        case file(URL)
    }

    private func url(_ path: String) throws -> URL {
        // Relative to the base's path, so a reverse proxy's prefix (`https://box/comfy/`) stays.
        guard let url = URL(string: String(path.drop { $0 == "/" }), relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        return url.absoluteURL
    }

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        var request = authorized(URLRequest(url: try url(path), timeoutInterval: 30), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func authorized(_ request: URLRequest, method: String) -> URLRequest {
        var request = request
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// One logical call. `repeatable` calls (every GET, an upload under a fixed name, a cancel) are tried again on a
    /// dropped connection or a 5xx with backoff; the rest only when the request never reached the server, like
    /// `ComfyClient`'s POSTs. A 429's `Retry-After` is waited out up to `maxDelay`.
    private func send(_ request: URLRequest, body: Body?, repeatable: Bool) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            let wait: TimeInterval
            do {
                let (data, response) =
                    switch body {
                    case .data(let data): try await session.upload(for: request, from: data)
                    case .file(let file): try await session.upload(for: request, fromFile: file)
                    case nil: try await session.data(for: request)
                    }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let error = Self.error(status: status, body: data)
                guard attempt < retry.maxAttempts else { throw error }
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(ComfyClient.retryAfter)
                if status == 429, let retryAfter, retryAfter <= retry.maxDelay {
                    wait = retryAfter
                } else if repeatable, status >= 500 {
                    wait = retry.delay(attempt)
                } else {
                    throw error
                }
            } catch let error as URLError {
                guard attempt < retry.maxAttempts, error.code != .cancelled,
                    ComfyClient.neverDelivered(error) || repeatable
                else { throw error }
                wait = retry.delay(attempt)
            }
            try await sleep(wait)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            // No key strategy: it would rename the keys inside free-form `JSONValue`s too.
            return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
        } catch {
            throw ComfyError.malformedResponse("\(T.self): \(error.localizedDescription)")
        }
    }

    /// A refusal as the app acts on it. ComfyUI answers a refused graph with 400 and `node_errors`; a proxy in front
    /// of it with 401 or 403.
    static func error(status: Int, body: Data) -> ComfyError {
        let json = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
        switch status {
        case 401, 403: return .unauthorized("ComfyUI (or the proxy in front of it) refused the token (HTTP \(status)).")
        case 400 where json["error"] != nil || json["node_errors"] != nil:
            return .invalidWorkflow(promptErrors(json))
        case 404: return .notFound("The server answered HTTP 404; is this the address of a ComfyUI?")
        default:
            let text = String(decoding: body.prefix(300), as: UTF8.self)
            return .rejected(status: status, code: nil, message: text.isEmpty ? "HTTP \(status)" : text)
        }
    }

    /// "Prompt outputs failed validation · UNETLoader (1): Value not in list: unet_name: 'x' not in [...]".
    static func promptErrors(_ json: JSONValue) -> String {
        var lines: [String] = []
        if let message = json["error"]?["message"]?.string ?? json["error"]?.string { lines.append(message) }
        for (node, entry) in (json["node_errors"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let type = entry["class_type"]?.string ?? "node"
            guard case .array(let errors)? = entry["errors"] else { continue }
            for error in errors {
                let text = [error["message"]?.string, error["details"]?.string].compactMap(\.self)
                    .filter { !$0.isEmpty }.joined(separator: ": ")
                lines.append("\(type) (\(node)): \(text)")
            }
        }
        return lines.isEmpty ? "ComfyUI refused the workflow." : lines.joined(separator: " · ")
    }

    static func writeMultipart(
        to destination: URL, boundary: String, file: URL, name: String, contentType: String,
        fields: [(String, String)]
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        func text(_ string: String) throws { try out.write(contentsOf: Data(string.utf8)) }
        for (field, value) in fields {
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n")
        }
        try text(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\n"
                + "Content-Type: \(contentType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try text("\r\n--\(boundary)--\r\n")
    }
}

// MARK: Shapes

/// `/upload/image`'s answer.
struct UploadedFile: Decodable {
    let name: String
    let subfolder: String
}

/// `/prompt`'s answer.
struct QueuedPrompt: Decodable {
    let promptID: String
    enum CodingKeys: String, CodingKey { case promptID = "prompt_id" }
}

/// The prompts `GET /queue` lists, by id.
public struct QueueState: Sendable, Equatable {
    public var running: [String]
    public var pending: [String]

    public init(running: [String], pending: [String]) {
        self.running = running
        self.pending = pending
    }

    public func contains(_ promptID: String) -> Bool { running.contains(promptID) || pending.contains(promptID) }
}

/// A file a node saved: what `/view` takes.
public struct OutputFile: Sendable, Decodable, Equatable {
    public let filename: String
    public let subfolder: String
    public let type: String

    public init(filename: String, subfolder: String = "", type: String = "output") {
        self.filename = filename
        self.subfolder = subfolder
        self.type = type
    }
}

/// One finished prompt in `/history/{id}`: whether it succeeded, why not, and the files each output node saved.
public struct PromptHistory: Sendable, Decodable {
    public let status: PromptStatus?
    /// Node id → its UI output, `{"images": [file], "animated": [true]}` for a SaveVideo.
    public let outputs: [String: JSONValue]

    enum CodingKeys: String, CodingKey { case status, outputs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(PromptStatus.self, forKey: .status)
        outputs = try c.decodeIfPresent([String: JSONValue].self, forKey: .outputs) ?? [:]
    }

    public var succeeded: Bool { status?.statusStr == "success" }

    /// ComfyUI's reason for an error: the failing node and its exception, or that it was interrupted.
    public var failure: String? {
        guard !succeeded else { return nil }
        for message in status?.messages ?? [] {
            guard case .array(let pair) = message, pair.count == 2, let event = pair[0].string else { continue }
            let data = pair[1]
            if event == "execution_error" {
                let node = [data["node_type"]?.string, data["node_id"]?.string.map { "(\($0))" }]
                    .compactMap(\.self).joined(separator: " ")
                let exception = data["exception_message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                return [node.isEmpty ? nil : node, exception].compactMap(\.self).joined(separator: ": ")
            }
            if event == "execution_interrupted" { return "The render was interrupted on ComfyUI." }
        }
        return status?.statusStr.map { "ComfyUI finished with status \($0)." } ?? "ComfyUI finished without a status."
    }

    /// The files `node` saved, under any of the keys ComfyUI and video node packs use.
    public func files(of node: String) -> [OutputFile] {
        guard let output = outputs[node]?.object else { return [] }
        return ["images", "videos", "gifs"].flatMap { key -> [OutputFile] in
            guard case .array(let items)? = output[key] else { return [] }
            return items.compactMap { item in
                guard let name = item["filename"]?.string else { return nil }
                return OutputFile(
                    filename: name, subfolder: item["subfolder"]?.string ?? "", type: item["type"]?.string ?? "output")
            }
        }
    }
}

/// A finished prompt's `status` in `/history/{id}`.
public struct PromptStatus: Sendable, Decodable {
    /// `success` or `error`.
    public let statusStr: String?
    /// `[event, data]` pairs: `execution_start`, `execution_cached`, `execution_error`, `execution_interrupted`,
    /// `execution_success`.
    public let messages: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case statusStr = "status_str"
        case messages
    }
}
