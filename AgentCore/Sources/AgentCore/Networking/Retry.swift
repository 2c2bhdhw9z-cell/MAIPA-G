import Foundation

/// When and how long to wait before trying a failed request again.
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Three tries, about 0.6 s then 1.2 s apart, with jitter so retries from parallel tool calls
    /// do not land on the server at the same instant.
    public static let standard = RetryPolicy(maxAttempts: 3, baseDelay: 0.6, maxDelay: 8)
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    func delay(forAttempt attempt: Int, suggested: TimeInterval?) -> TimeInterval {
        if let suggested { return min(max(suggested, 0), maxDelay) }
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        let jitter = Double.random(in: 0.85...1.15)
        return min(exponential * jitter, maxDelay)
    }
}

/// Runs `operation`, retrying while `retryAfter` says the failure is temporary. `retryAfter`
/// returns nil for errors that will not go away by waiting, or the wait it suggests (0 = default).
public func withRetries<T: Sendable>(
    _ policy: RetryPolicy,
    retryAfter: @Sendable (Error) -> TimeInterval?,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            guard attempt < policy.maxAttempts, let suggested = retryAfter(error) else { throw error }
            let wait = policy.delay(forAttempt: attempt, suggested: suggested > 0 ? suggested : nil)
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            attempt += 1
        }
    }
}

/// The usual temporary failures: a dropped connection, a timeout, or a 5xx from a busy server.
public func defaultRetryDelay(_ error: Error) -> TimeInterval? {
    if let http = error as? HTTPError {
        switch http {
        case .transport(_, let isOffline):
            return isOffline ? nil : 0
        case .status(let code, _, let headers):
            if code == 429 || (500...504).contains(code) {
                return headers["retry-after"].flatMap(TimeInterval.init) ?? 0
            }
            return nil
        case .undecodable:
            return nil
        }
    }
    return nil
}
