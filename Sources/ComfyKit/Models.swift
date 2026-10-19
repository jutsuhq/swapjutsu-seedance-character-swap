import Foundation

/// An uploaded file or a job output: a UUID record over a content-addressed blob.
public struct Asset: Sendable, Decodable, Equatable {
    public let id: String
    public let hash: String?
    public let contentType: String?
    public let filePath: String?
    /// Short-lived signed link (about 6 h on Comfy Cloud) that downloads without the API key.
    public let url: URL?
    public let urlExpiresAt: String?

    public init(
        id: String, hash: String? = nil, contentType: String? = nil, filePath: String? = nil, url: URL? = nil,
        urlExpiresAt: String? = nil
    ) {
        self.id = id
        self.hash = hash
        self.contentType = contentType
        self.filePath = filePath
        self.url = url
        self.urlExpiresAt = urlExpiresAt
    }
}

public enum JobStatus: String, Sendable, Decodable {
    case queued, running, succeeded, canceling, canceled, failed, expired

    /// `canceling` is not terminal: cancellation lands at a node boundary.
    public var isTerminal: Bool { [.succeeded, .canceled, .failed, .expired].contains(self) }
}

/// One execution of a workflow, durable until `expiresAt`; `outputs` fill in as nodes finish.
public struct Job: Sendable, Decodable {
    public struct Output: Sendable, Decodable, Equatable {
        public let nodeId: String
        public let name: String?
        public let contentType: String
        public let id: String
    }

    public struct Failure: Sendable, Decodable, Equatable {
        public let code: String?
        public let message: String
        public let nodeId: String?
        public let classType: String?
    }

    public struct Progress: Sendable, Decodable, Equatable {
        public let value: Double
    }

    public let id: String
    public let status: JobStatus
    public let queuePosition: Int?
    public let progress: Progress?
    public let outputs: [Output]
    public let error: Failure?

    enum CodingKeys: String, CodingKey { case id, status, queuePosition, progress, outputs, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(JobStatus.self, forKey: .status)
        queuePosition = try c.decodeIfPresent(Int.self, forKey: .queuePosition)
        progress = try c.decodeIfPresent(Progress.self, forKey: .progress)
        outputs = try c.decodeIfPresent([Output].self, forKey: .outputs) ?? []
        error = try c.decodeIfPresent(Failure.self, forKey: .error)
    }
}

/// The documented error envelope, mapped to the cases a client acts on differently.
public enum ComfyError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized(String)
    case insufficientCredits(String)
    case invalidWorkflow(String)
    case missingAsset(String)
    case idempotencyKeyReuse(String)
    /// `queue_full` / `rate_limited`: back off for `retryAfter` and send the same request again.
    case busy(code: String, message: String, retryAfter: TimeInterval?)
    case notFound(String)
    case rejected(status: Int, code: String?, message: String)
    case jobFailed(Job.Failure)
    case malformedResponse(String)

    /// The `code` of a `409` whose request the server was still running when the client stopped waiting for it.
    public static let inFlight = "idempotency_in_flight"

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m): "Comfy refused the API key: \(m)"
        case .insufficientCredits(let m): "Not enough Comfy credits: \(m)"
        case .invalidWorkflow(let m): "Comfy rejected the workflow: \(m)"
        case .missingAsset(let m): "An uploaded input is missing on Comfy: \(m)"
        case .idempotencyKeyReuse(let m): "Comfy already received this request: \(m)"
        case .busy(let code, let m, _): "Comfy is busy (\(code)): \(m)"
        case .notFound(let m): "Not found on Comfy: \(m)"
        case .rejected(let status, let code, let m): "Comfy answered \(status)\(code.map { " \($0)" } ?? ""): \(m)"
        case .jobFailed(let f): f.message
        case .malformedResponse(let m): "Unexpected answer from Comfy: \(m)"
        }
    }

    static func from(status: Int, body: Data, retryAfter: TimeInterval?) -> ComfyError {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) else {
            return .rejected(status: status, code: nil, message: String(decoding: body.prefix(500), as: UTF8.self))
        }
        let (code, message) = (envelope.error.code, envelope.error.message)
        switch (status, code) {
        case (401, _), (_, "unauthorized"): return .unauthorized(message)
        case (402, _), (_, "insufficient_credits"): return .insufficientCredits(message)
        case (_, "invalid_workflow"), (_, "workflow_format_ui"): return .invalidWorkflow(message)
        case (_, "missing_asset"): return .missingAsset(message)
        case (_, "idempotency_key_reuse"): return .idempotencyKeyReuse(message)
        case (429, _): return .busy(code: code, message: message, retryAfter: retryAfter)
        case (404, _): return .notFound(message)
        default: return .rejected(status: status, code: code, message: message)
        }
    }
}

/// `{"error": {"code", "message"}}`, the shape of every refusal.
private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }
    let error: Body
}
