import Foundation

/// When a connector that dropped is tried again, and how long a reply waits for that.
///
/// Every reply used to start by reconnecting each broken connector, one after another, and wait
/// for all of them before the AI was asked anything. A connector whose sign-in had been revoked
/// ("invalid_grant: Refresh token not found", logged again and again on 8 and 9 November 2026)
/// was retried at the start of every reply, and a connector server that didn't answer cost up
/// to a minute per request, while the reply said "Thinking…" with nothing sent to the AI yet.
public enum ConnectorReconnectPolicy {
    /// The most a reply waits for connectors before asking the AI. Reconnecting carries on in
    /// the background; a connector that comes back is there for the next reply.
    public static let replyWaitLimit: TimeInterval = 6

    /// Waits after failed reconnects in a row: 1, 2, 5, 15, then 30 minutes.
    static let backoff: [TimeInterval] = [60, 120, 300, 900, 1_800]

    /// True when a reconnect may be tried now. A connector whose sign-in was refused is never
    /// tried by itself; the person signs in again.
    public static func shouldRetry(
        state: ConnectorConnectionState?,
        consecutiveFailures: Int,
        lastFailureAt: Date?,
        now: Date = Date()
    ) -> Bool {
        switch state {
        case .authorizationNeeded, .connecting, .connected: return false
        case .failed, .disconnected, nil: break
        }
        guard consecutiveFailures > 0, let lastFailureAt else { return true }
        let wait = backoff[min(consecutiveFailures, backoff.count) - 1]
        return now.timeIntervalSince(lastFailureAt) >= wait
    }

    /// True when `error` means the saved sign-in itself was refused (revoked or expired refresh
    /// token, unknown client), so trying again can't help until the person signs in again.
    public static func isSignInRefused(_ error: Error) -> Bool {
        let text: String
        if let auth = error as? MCPAuthorizationError {
            switch auth {
            case .rejected(let message): text = message
            case .registrationRequired: return true
            default: return false
            }
        } else {
            text = String(describing: error)
        }
        let lowered = text.lowercased()
        return ["invalid_grant", "invalid_client", "unauthorized_client", "refresh token not found", "refresh token is invalid", "refresh token expired"]
            .contains { lowered.contains($0) }
    }
}

/// How long each step of getting a reply ready took, before the AI was asked anything. A slow
/// start used to look exactly like a slow AI ("Thinking…"); this says where the time went.
public struct ReplySetupTimer: Sendable {
    public private(set) var steps: [(label: String, seconds: TimeInterval)] = []
    private let started: Date

    public init(started: Date = Date()) {
        self.started = started
    }

    public mutating func record(_ label: String, seconds: TimeInterval) {
        steps.append((label, seconds))
    }

    /// Notices at or above this many seconds of setup are shown on the reply.
    public static let noticeSeconds: TimeInterval = 10

    /// "Getting ready took 47s before the AI was asked (reconnecting connectors 41s)." or nil
    /// when getting ready was quick.
    public func notice(now: Date = Date()) -> String? {
        let total = now.timeIntervalSince(started)
        guard total >= Self.noticeSeconds else { return nil }
        let slow = steps.filter { $0.seconds >= 2 }.sorted { $0.seconds > $1.seconds }.prefix(3)
        let detail = slow.map { "\($0.label) \(Int($0.seconds.rounded()))s" }.joined(separator: ", ")
        return "Getting ready took \(Int(total.rounded()))s before the AI was asked" + (detail.isEmpty ? "." : " (\(detail)).")
    }
}
