import Foundation

/// What one logical call has left of each retry kind in `_request_base`, and how long the next wait is.
struct RetryBudget {
    let policy: PartnerRetryPolicy
    let maxRetries: Int
    let firstDelay: TimeInterval
    let backoff: Double
    var retries = 0
    var delay: TimeInterval
    var rateLimits = 0
    var rateDelay: TimeInterval
    var inFlightWaits = 0

    init(policy: PartnerRetryPolicy, isGet: Bool) {
        self.policy = policy
        (maxRetries, firstDelay, backoff) =
            isGet
            ? (policy.pollRetries, policy.pollRetryDelay, policy.pollBackoff)
            : (policy.maxRetries, policy.retryDelay, policy.backoff)
        (delay, rateDelay) = (firstDelay, firstDelay)
    }

    /// The wait before trying a refused request again, or nil when the refusal stands.
    mutating func wait(status: Int, inFlight: Bool, disabled: Bool, retryAfter: TimeInterval?) -> TimeInterval? {
        if inFlight, inFlightWaits < policy.maxInFlightWaits {
            inFlightWaits += 1
            (retries, delay) = (0, firstDelay)
            let wait = min(policy.inFlightMaxWait, policy.inFlightWait * pow(1.5, Double(inFlightWaits - 1)))
            return max(wait, retryAfter ?? wait)
        }
        if status == 429, rateLimits < policy.maxRateLimitRetries {
            rateLimits += 1
            defer { rateDelay *= backoff }
            return retryAfter ?? min(rateDelay, 30)
        }
        if [408, 500, 502, 503, 504].contains(status), !disabled { return connectionWait(retryAfter: retryAfter) }
        return nil
    }

    /// A dropped connection, or a retryable status: `maxRetries` times with exponential backoff.
    mutating func connectionWait(retryAfter: TimeInterval? = nil) -> TimeInterval? {
        guard retries < maxRetries else { return nil }
        retries += 1
        defer { delay *= backoff }
        return retryAfter ?? delay
    }
}

/// `sync_op` and `poll_op` defaults from `util/client.py`; tests shrink the delays.
public struct PartnerRetryPolicy: Sendable {
    public var maxRetries = 3
    public var retryDelay: TimeInterval = 1
    public var backoff = 2.0
    public var maxRateLimitRetries = 16
    /// The longest server `Retry-After` waited out; a longer one ends the call. Unlike the node's
    /// `_MAX_RETRY_AFTER_WAIT` (150 s), which shortens the server's delay and asks again early, it never shortens one.
    public var maxRetryAfter: TimeInterval = 600
    public var inFlightWait: TimeInterval = 2
    public var inFlightMaxWait: TimeInterval = 30
    /// The node waits out an in-flight attempt until its 1 h timeout; this bounds it by count instead.
    public var maxInFlightWaits = 120
    public var pollRetries = 10
    public var pollRetryDelay: TimeInterval = 1
    public var pollBackoff = 1.4
    public var assetPollInterval: TimeInterval = 5
    public var assetMaxPolls = 1200

    public init() {}
}
