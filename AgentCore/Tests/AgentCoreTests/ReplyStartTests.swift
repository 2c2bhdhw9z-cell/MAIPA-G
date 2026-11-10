import Foundation
import Testing
@testable import AgentCore

/// "It says Thinking… and never answers", with every provider (owner, 10 November 2026).
@Suite("A reply asks the AI without waiting on broken connectors")
struct ReplyStartTests {
    @Test("A connector whose sign-in was refused isn't retried at the start of every reply")
    func refusedSignInIsNotRetried() {
        let refused = MCPAuthorizationError.rejected(#"{"error":"invalid_grant","error_description":"Refresh token not found"}"#)
        #expect(ConnectorReconnectPolicy.isSignInRefused(refused))
        #expect(!ConnectorReconnectPolicy.isSignInRefused(HTTPError.transport("The request timed out.", isOffline: false)))
        #expect(!ConnectorReconnectPolicy.shouldRetry(state: .authorizationNeeded, consecutiveFailures: 0, lastFailureAt: nil))
    }

    @Test("A connector that keeps failing is tried again less and less often")
    func failingConnectorBacksOff() {
        let now = Date()
        #expect(ConnectorReconnectPolicy.shouldRetry(state: .failed, consecutiveFailures: 0, lastFailureAt: nil, now: now))
        #expect(!ConnectorReconnectPolicy.shouldRetry(state: .failed, consecutiveFailures: 1, lastFailureAt: now.addingTimeInterval(-30), now: now))
        #expect(ConnectorReconnectPolicy.shouldRetry(state: .failed, consecutiveFailures: 1, lastFailureAt: now.addingTimeInterval(-61), now: now))
        #expect(!ConnectorReconnectPolicy.shouldRetry(state: .failed, consecutiveFailures: 9, lastFailureAt: now.addingTimeInterval(-1_000), now: now))
        #expect(ConnectorReconnectPolicy.shouldRetry(state: .failed, consecutiveFailures: 9, lastFailureAt: now.addingTimeInterval(-1_801), now: now))
        #expect(!ConnectorReconnectPolicy.shouldRetry(state: .connected, consecutiveFailures: 0, lastFailureAt: nil, now: now))
        #expect(ConnectorReconnectPolicy.replyWaitLimit <= 10)
    }

    @Test("A slow start says where its time went, instead of looking like the AI is thinking")
    func slowSetupIsExplained() {
        let started = Date(timeIntervalSince1970: 1_000)
        var timer = ReplySetupTimer(started: started)
        timer.record("reconnecting connectors", seconds: 41)
        timer.record("checking the computer", seconds: 0.4)
        timer.record("reading the repo", seconds: 5)
        #expect(timer.notice(now: started.addingTimeInterval(47)) == "Getting ready took 47s before the AI was asked (reconnecting connectors 41s, reading the repo 5s).")
        #expect(ReplySetupTimer(started: started).notice(now: started.addingTimeInterval(3)) == nil)
    }

    @Test("An empty OneProvider balance (429 insufficient_quota) is not waited on like a rate limit")
    func emptyBalanceIsNotRetried() {
        // The exact answer api.oneprovider.dev gave on 10 November 2026 for a key with no balance.
        let body = Data(#"{"error":{"code":"insufficient_quota","message":"Insufficient balance on this API key. Top up: dashboard.oneprovider.dev","type":"insufficient_balance"},"type":"error"}"#.utf8)
        let error = OpenRouterAPIError(status: 429, body: body, headers: ["x-should-retry": "false"], providerName: "OneProvider")
        #expect(error.kind == .outOfCredits)
        let limited = OpenRouterAPIError(status: 429, body: Data(#"{"error":{"code":429,"message":"Rate limit exceeded"}}"#.utf8), headers: [:])
        #expect(limited.kind == .rateLimited)
    }
}
