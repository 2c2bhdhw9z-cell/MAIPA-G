import Foundation

/// The AI sent nothing at all (no words, no thinking, no tool call) for `seconds`.
public struct ModelWentSilent: Error, Sendable, CustomStringConvertible {
    public let seconds: TimeInterval

    public init(seconds: TimeInterval) {
        self.seconds = seconds
    }

    public var description: String {
        "Nothing arrived from the AI for \(Int(seconds.rounded())) seconds (no words, no thinking, no tool call), so the request was stopped."
    }
}

/// Ends a model stream that has gone quiet, instead of letting the reply sit on "Thinking…".
///
/// URLSession's idle timeout only counts bytes, and OpenRouter sends a `: OPENROUTER PROCESSING`
/// keep-alive comment every few seconds. The SSE parser drops those comments, so a provider that
/// stalls behind OpenRouter kept the connection "alive" while the reply received nothing, up to
/// the session's one-hour resource limit. This counts only real elements, starting from the moment
/// the request is sent, so a request that never gets its first word is caught as well.
enum SilenceWatchdog {
    static func watch<Element: Sendable>(
        limit: TimeInterval,
        open: @escaping @Sendable () async throws -> AsyncThrowingStream<Element, Error>
    ) -> AsyncThrowingStream<Element, Error> {
        let (stream, continuation) = AsyncThrowingStream<Element, Error>.makeStream()
        let clock = ActivityClock()
        let reader = Task {
            do {
                let upstream = try await open()
                for try await element in upstream {
                    clock.touch()
                    continuation.yield(element)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                let quiet = clock.secondsSinceLastActivity()
                if quiet >= limit {
                    continuation.finish(throwing: ModelWentSilent(seconds: limit))
                    reader.cancel()
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64((limit - quiet) * 1_000_000_000) + 1_000_000)
                } catch {
                    return
                }
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            watchdog.cancel()
        }
        return stream
    }
}

/// When something last showed signs of life. Safe to touch from any task. Also restarts a tool's
/// inactivity limit (`AgentLoop.bounded(activity:)`).
public final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ProcessInfo.processInfo.systemUptime

    public init() {}

    public func touch() {
        lock.withLock { last = ProcessInfo.processInfo.systemUptime }
    }

    public func secondsSinceLastActivity() -> TimeInterval {
        lock.withLock { ProcessInfo.processInfo.systemUptime - last }
    }
}

/// A tool call ran past `AgentEnvironment.toolTimeLimit` and was stopped.
public struct ToolTimedOut: Error, Sendable, CustomStringConvertible {
    public let tool: String
    public let seconds: TimeInterval
    /// True when the limit counted from the tool's last progress rather than from its start.
    public var sinceLastActivity = false

    public var description: String {
        sinceLastActivity
            ? "\(tool) sent no output or progress for \(AgentLoop.spokenDuration(seconds)), so it was stopped."
            : "\(tool) was still running after \(AgentLoop.spokenDuration(seconds)), so it was stopped."
    }
}


/// Hands one result to one waiter; later results are ignored. Safe to resume before `wait()`.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func resume(_ value: Result<T, Error>) {
        let target: CheckedContinuation<T, Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            let w = waiter
            waiter = nil
            return w
        }
        target?.resume(with: value)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let ready: Result<T, Error>? = lock.withLock {
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
