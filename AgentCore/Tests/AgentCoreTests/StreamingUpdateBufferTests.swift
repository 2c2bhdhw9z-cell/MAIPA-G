import Foundation
import Testing
@testable import AgentCore

@Suite("Streaming update buffer")
struct StreamingUpdateBufferTests {
    @Test func firstUpdateIsImmediateAndFastOnesCoalesceToNewestTrailingSnapshot() {
        var buffer = StreamingUpdateBuffer<String>(interval: 0.1)
        #expect(buffer.receive("a", immediate: false, at: 0) == "a")
        #expect(buffer.receive("ab", immediate: false, at: 0.02) == nil)
        #expect(buffer.receive("abc", immediate: false, at: 0.04) == nil)
        #expect(abs(buffer.delay(at: 0.04) - 0.06) < 0.0001)
        #expect(buffer.flush(at: 0.1) == "abc")
        #expect(!buffer.hasPending)
    }

    @Test func milestonesBypassThrottleAndSupersedePendingText() {
        var buffer = StreamingUpdateBuffer<String>(interval: 1)
        _ = buffer.receive("draft", immediate: false, at: 0)
        #expect(buffer.receive("draft more", immediate: false, at: 0.1) == nil)
        #expect(buffer.receive("final tool state", immediate: true, at: 0.2) == "final tool state")
        #expect(buffer.flush(at: 1.2) == nil)
    }

    @Test func forcedFlushKeepsFinalOrCancelledText() {
        var buffer = StreamingUpdateBuffer<String>(interval: 1)
        _ = buffer.receive("start", immediate: false, at: 0)
        _ = buffer.receive("partial ```swift\nlet x = 1", immediate: false, at: 0.1)
        #expect(buffer.flush(at: 0.11) == "partial ```swift\nlet x = 1")
    }
}
