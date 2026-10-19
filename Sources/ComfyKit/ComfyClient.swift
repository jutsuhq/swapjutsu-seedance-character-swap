import Foundation
import UniformTypeIdentifiers

/// A client for the Comfy API v2: upload inputs, submit an API-format workflow, poll the job, fetch outputs.
/// The same contract runs on Comfy Cloud, a Comfy API deployment and self-hosted ComfyUI behind comfy-api-proxy,
/// so only `baseURL` changes. Retries and polling follow the rules of Comfy's own SDKs.
public struct ComfyClient: Sendable {
    public static let cloud: URL = {
        guard let url = URL(string: "https://cloud.comfy.org") else { preconditionFailure("Invalid Comfy Cloud URL") }
        return url
    }()

    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession
    public let retry: RetryPolicy
    public let sleep: Sleeper

    public init(
        apiKey: String, baseURL: URL = cloud, session: URLSession = .shared, retry: RetryPolicy = .init(),
        sleep: @escaping Sleeper = taskSleep
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.retry = retry
        self.sleep = sleep
    }

    // MARK: Assets

    /// `POST /api/v2/assets`, one multipart call streamed from a temporary file.
    public func upload(_ file: URL, contentType: String? = nil, tags: [String] = ["input"]) async throws -> Asset {
        let type = contentType ?? Self.contentType(of: file)
        let boundary = "comfykit-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appending(path: "\(boundary).multipart")
        try Self.writeMultipart(to: body, boundary: boundary, file: file, contentType: type, tags: tags)
        defer { try? FileManager.default.removeItem(at: body) }
        var request = try request("POST", "/api/v2/assets")
        request.timeoutInterval = 600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return try await send(request, body: .file(body), idempotent: true)
    }

    /// `GET /api/v2/assets/{id}`: the record with a fresh signed `url`.
    public func asset(_ id: String) async throws -> Asset {
        try await send(try request("GET", "/api/v2/assets/\(id)"), body: nil, idempotent: false)
    }

    // MARK: Jobs

    /// `POST /api/v2/jobs`. `partnerAPIKey` lets partner (API) nodes in the graph bill the Comfy account.
    public func submit(_ workflow: Workflow, partnerAPIKey: String? = nil) async throws -> Job {
        var payload: [String: JSONValue] = ["workflow": .object(workflow.nodes)]
        if let partnerAPIKey, !partnerAPIKey.isEmpty {
            payload["extra_data"] = ["api_key_comfy_org": .string(partnerAPIKey)]
        }
        var request = try request("POST", "/api/v2/jobs")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, body: .data(try JSONEncoder().encode(payload)), idempotent: true)
    }

    /// `GET /api/v2/jobs/{id}`, the authoritative view of a job until it expires.
    public func job(_ id: String) async throws -> Job {
        try await send(try request("GET", "/api/v2/jobs/\(id)"), body: nil, idempotent: false)
    }

    public func cancel(_ id: String) async throws {
        let _: JSONValue = try await send(try request("POST", "/api/v2/jobs/\(id)/cancel"), body: nil, idempotent: true)
    }

    /// Polls until the job is terminal, backing off from 0.5 s to 5 s like the SDKs; cancelling the task stops it.
    /// Returns the succeeded job, throws `.jobFailed` for a failed, canceled or expired one.
    public func waitForCompletion(of id: String, onUpdate: (Job) -> Void = { _ in }) async throws -> Job {
        var delay = retry.pollStart
        while true {
            let job = try await job(id)
            onUpdate(job)
            if job.status.isTerminal {
                guard job.status == .succeeded else {
                    throw ComfyError.jobFailed(
                        job.error
                            ?? .init(
                                code: job.status.rawValue, message: "The job \(job.status.rawValue).", nodeId: nil,
                                classType: nil))
                }
                return job
            }
            try await sleep(delay)
            delay = min(delay * retry.pollFactor, retry.pollCap)
        }
    }

    // MARK: Transport

    enum Body {
        case data(Data)
        case file(URL)
    }

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// One logical call. A POST mints one `Idempotency-Key` and reuses it on every attempt, and is retried only
    /// where the key is documented to survive: never delivered, or a 429 naming `Retry-After`. GETs also retry
    /// 5xx and dropped connections.
    private func send<T: Decodable>(_ request: URLRequest, body: Body?, idempotent: Bool) async throws -> T {
        var request = request
        if idempotent { request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let isGet = request.httpMethod == "GET"
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
                if (200..<300).contains(status) {
                    do {
                        return try Self.decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
                    } catch {
                        throw ComfyError.malformedResponse("\(T.self): \(error.localizedDescription)")
                    }
                }
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Self.retryAfter)
                let error = ComfyError.from(status: status, body: data, retryAfter: retryAfter)
                guard attempt < retry.maxAttempts else { throw error }
                // The server's delay is never shortened; one too long to wait for here goes back to the caller.
                if status == 429 || (isGet && status >= 500), let retryAfter {
                    guard retryAfter <= retry.maxDelay else { throw error }
                    wait = retryAfter
                } else if isGet, status >= 500 {
                    wait = retry.delay(attempt)
                } else {
                    throw error
                }
            } catch let error as URLError {
                guard attempt < retry.maxAttempts, Self.neverDelivered(error) || (isGet && error.code != .cancelled)
                else { throw error }
                wait = retry.delay(attempt)
            }
            try await sleep(wait)
        }
    }

    /// `Retry-After` as delta-seconds or an HTTP date, in seconds from now.
    static func retryAfter(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Failures before the request reached the server, so its idempotency key was never claimed.
    public static func neverDelivered(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed]
            .contains(error.code)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func writeMultipart(
        to destination: URL, boundary: String, file: URL, contentType: String, tags: [String]
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        func text(_ string: String) throws { try out.write(contentsOf: Data(string.utf8)) }
        let name = file.lastPathComponent
        // Comfy reads `tags` as one JSON array of strings, not as a repeated field.
        let tagList = String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)
        for (field, value) in [("content_type", contentType), ("file_path", name), ("tags", tagList)] {
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n")
        }
        try text(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n"
                + "Content-Type: \(contentType)\r\n\r\n")
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try text("\r\n--\(boundary)--\r\n")
    }

    /// The MIME type for an upload, from the file extension; an unknown one is sent as such rather than guessed.
    public static func contentType(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// Waits that many seconds, throwing when the task is canceled; tests pass one that records the wait instead.
public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

/// The real wait.
public let taskSleep: Sleeper = { try await Task.sleep(for: .seconds($0)) }

/// How many times a logical call is attempted and how fast a job is polled. `maxDelay` caps the client's own backoff
/// and the longest server `Retry-After` it waits out before giving the error back.
public struct RetryPolicy: Sendable {
    public var maxAttempts = 4
    public var baseDelay: TimeInterval = 0.5
    public var maxDelay: TimeInterval = 30
    public var pollStart: TimeInterval = 0.5
    public var pollFactor: Double = 1.5
    public var pollCap: TimeInterval = 5

    public init() {}

    func delay(_ attempt: Int) -> TimeInterval { min(baseDelay * pow(2, Double(attempt - 1)), maxDelay) }
}
