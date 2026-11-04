import Foundation

/// A leading/trailing throttle for complete streaming snapshots, never individual deltas.
/// Milestones bypass the interval and supersede any pending snapshot.
public struct StreamingUpdateBuffer<Value: Sendable>: Sendable {
    public let interval: TimeInterval
    private var lastPublished: TimeInterval?
    private var pending: Value?

    public init(interval: TimeInterval = 1.0 / 30.0) {
        self.interval = max(0, interval)
    }

    public var hasPending: Bool { pending != nil }

    public func delay(at now: TimeInterval) -> TimeInterval {
        guard let lastPublished else { return 0 }
        return max(0, interval - (now - lastPublished))
    }

    public mutating func receive(_ value: Value, immediate: Bool, at now: TimeInterval) -> Value? {
        pending = value
        if immediate || delay(at: now) == 0 { return flush(at: now) }
        return nil
    }

    /// Also used at stream end, cancellation checkpoints and before persistence.
    public mutating func flush(at now: TimeInterval) -> Value? {
        guard let value = pending else { return nil }
        pending = nil
        lastPublished = now
        return value
    }
}
