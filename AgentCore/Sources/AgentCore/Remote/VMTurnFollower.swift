import Foundation

/// One reply running on the chat computer, as the phone follows it. Stop goes through here so it
/// reaches the computer; closing the app only stops following, and the reply keeps going there.
public actor VMRunHandle {
    public nonisolated let id: String
    public nonisolated let control: VMControl
    private(set) var stopRequested = false

    public init(id: String, control: VMControl) {
        self.id = id
        self.control = control
    }

    /// Stop was tapped: the runner is asked to stop, and following carries on until its final
    /// state arrives.
    public func requestStop() { stopRequested = true }
}

extension AgentRun {
    public static let computerPollInterval: UInt64 = 1_200_000_000

    /// Follows a reply on the chat computer. Each state the runner writes arrives as an event, the
    /// same as a reply running on the phone; steering typed meanwhile is sent to the runner.
    /// Cancelling only stops following (the app went to the background): the runner goes on.
    public static func onComputer(
        _ handle: VMRunHandle,
        startingTurn: AssistantTurn,
        afterSeq: Int = 0,
        pollInterval: UInt64 = computerPollInterval,
        onState: @escaping @Sendable (VMTurnState) async -> Void
    ) -> AgentRun {
        let steering = SteeringInbox()
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let task = Task {
            var seq = afterSeq
            var turn = startingTurn
            var failures = 0
            var stopSent = false
            var goneSince: Date?
            var warnedAwake = false
            var stagedSeen = 0
            func finish(_ notice: String, stoppedEarly: Bool) {
                if !turn.notices.contains(notice) { turn.notices.append(notice) }
                if turn.status == .running { turn.status = .stopped }
                if stoppedEarly { turn.stoppedEarly = true }
                continuation.yield(.updated(turn, milestone: true))
            }
            while !Task.isCancelled {
                for text in await steering.drain() {
                    do { try await handle.control.steer(id: handle.id, text: text) }
                    catch { await steering.enqueue(text); break }
                }
                if await handle.stopRequested, !stopSent {
                    stopSent = true
                    try? await handle.control.stop(id: handle.id)
                }
                do {
                    let poll = try await handle.control.poll(id: handle.id, after: seq)
                    failures = 0
                    if poll.missing {
                        finish("The reply's files on your computer are gone (the computer may have been replaced), so it can't be picked up again. Tap retry to run it again.", stoppedEarly: true)
                        break
                    }
                    if poll.awake == "off", !warnedAwake {
                        warnedAwake = true
                        turn.notices.append(VMNotices.cantStayAwake)
                        continuation.yield(.updated(turn, milestone: false))
                    }
                    if var state = poll.state {
                        if state.staged != nil {
                            stagedSeen = state.stagedVersion
                        } else if state.stagedVersion > stagedSeen,
                                  let files = try? await handle.control.readStaged(id: handle.id, version: state.stagedVersion) {
                            state.staged = files
                            stagedSeen = state.stagedVersion
                        }
                        seq = state.seq
                        let stepped = state.turn.steps.count != turn.steps.count || state.turn.status != turn.status
                        var next = state.turn
                        for notice in turn.notices where !next.notices.contains(notice) && VMNotices.isPhoneNotice(notice) { next.notices.append(notice) }
                        turn = next
                        await onState(state)
                        if state.isFinished {
                            for text in state.unconsumedSteering { await steering.enqueue(text) }
                            continuation.yield(.updated(turn, milestone: true))
                            break
                        }
                        continuation.yield(.updated(turn, milestone: stepped))
                        goneSince = nil
                    } else if !poll.runnerAlive {
                        // No newer state and nothing running: give the last write a moment, then
                        // say the runner ended without finishing.
                        let since = goneSince ?? Date()
                        goneSince = since
                        if Date().timeIntervalSince(since) > 4 {
                            finish(stopSent ? "Stopped on your computer." : VMNotices.runnerEnded, stoppedEarly: !stopSent)
                            break
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failures += 1
                    if failures >= 8 {
                        // Leaves the turn running: the reply may well still be going on the
                        // computer, and is picked up again when the app comes back.
                        turn.notices.append(VMNotices.lostContact)
                        continuation.yield(.updated(turn, milestone: true))
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: pollInterval)
            }
            continuation.finish()
        }
        return AgentRun(events: stream, task: task, steering: steering)
    }
}

/// What the chat says about a reply on the computer.
public enum VMNotices {
    public static let runningOnComputer = "Running on your computer: this reply keeps going if you close the app."
    public static let cantStayAwake = "Your computer couldn't hold itself awake, so this reply only moves on while the app is open."
    public static let runnerEnded = "The reply ended on your computer without finishing (the runner stopped). Tap retry to carry on from where it stopped."
    public static let lostContact = "Lost contact with your computer. The reply keeps going there, and MAIPA-G picks it up again when you come back to the app."

    public static func fellBack(_ reason: String) -> String {
        "Your computer couldn't take this reply (\(reason)), so it runs on the phone and stops if you leave the app."
    }

    static func isPhoneNotice(_ notice: String) -> Bool {
        notice == runningOnComputer || notice == cantStayAwake || notice.hasPrefix("Your computer couldn't take")
    }
}
