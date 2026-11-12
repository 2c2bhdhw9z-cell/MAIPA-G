import Foundation

/// One reply running on the chat computer, as the phone follows it. Stop goes through here so it
/// reaches the computer; closing the app only stops following, and the reply keeps going there.
public actor VMRunHandle {
    public nonisolated let id: String
    public nonisolated let control: VMControl
    private(set) var stopRequested = false
    /// How many times Stop was tapped. Each tap starts sending the stop again.
    private(set) var stopRequests = 0

    public init(id: String, control: VMControl) {
        self.id = id
        self.control = control
    }

    /// Stop was tapped: the runner is asked to stop (again and again for a while if the computer
    /// can't be reached), and following carries on until its final state arrives.
    public func requestStop() {
        stopRequested = true
        stopRequests += 1
    }
}

extension AgentRun {
    public static let computerPollInterval: UInt64 = 1_200_000_000
    /// The longest one check on the reply may take before it's given up and asked again.
    static let pollTimeLimit: TimeInterval = 45
    /// The longest one attempt to stop the reply may take: the computer waits up to about 26
    /// seconds for the runner to end (`VMControl.stopScript`).
    public static let stopTimeLimit: TimeInterval = 45
    /// How long a Stop that can't reach the computer is sent again before the chat says so.
    public static let stopRetryWindow: TimeInterval = 60

    /// The wait before the next attempt to send a stop that failed: 1, 2, 4, 8, then 10 seconds.
    static func stopRetryDelay(afterFailures failures: Int) -> TimeInterval {
        min(pow(2, Double(max(failures, 1) - 1)), 10)
    }

    /// Follows a reply on the chat computer. Each state the runner writes arrives as an event, the
    /// same as a reply running on the phone; steering typed meanwhile is sent to the runner.
    /// Cancelling only stops following (the app went to the background): the runner goes on.
    public static func onComputer(
        _ handle: VMRunHandle,
        startingTurn: AssistantTurn,
        afterSeq: Int = 0,
        pollInterval: UInt64 = computerPollInterval,
        stopRetryWindow: TimeInterval = AgentRun.stopRetryWindow,
        onState: @escaping @Sendable (VMTurnState) async -> Void
    ) -> AgentRun {
        let steering = SteeringInbox()
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        let task = Task {
            var seq = afterSeq
            var turn = startingTurn
            var failures = 0
            var goneSince: Date?
            var warnedAwake = false
            var stagedSeen = 0
            // Stop: each tap is a round, sent again with growing waits until the computer takes
            // it or the reply is seen to end, for up to `stopRetryWindow`. One silent try used to
            // be all, so a Stop tapped while the computer didn't answer was lost.
            var stopRound = 0
            var stopDelivered = false
            var stopGaveUp = false
            var stopAskedAt = Date()
            var stopFailures = 0
            var nextStopTry = Date.distantPast
            func finish(_ notice: String, stoppedEarly: Bool) {
                if !turn.notices.contains(notice) { turn.notices.append(notice) }
                turn.notices.removeAll { $0 == VMNotices.stopFailed }
                if turn.status == .running { turn.status = .stopped }
                if stoppedEarly { turn.stoppedEarly = true }
                // Nothing is running these any more: they mustn't go on showing as running.
                AgentLoop.settleRunningTools(in: &turn)
                continuation.yield(.updated(turn, milestone: true))
            }
            while !Task.isCancelled {
                // Steering goes out in the order it was typed. One that can't be sent goes back
                // to the front with everything after it, to go out next time (the ones after a
                // failed one used to be lost, and the failed one went to the back).
                let outgoing = await steering.drain()
                for (index, text) in outgoing.enumerated() {
                    do { try await handle.control.steer(id: handle.id, text: text) }
                    catch { await steering.prepend(Array(outgoing[index...])); break }
                }
                let requests = await handle.stopRequests
                if requests > stopRound {
                    stopRound = requests
                    stopDelivered = false
                    stopGaveUp = false
                    stopAskedAt = Date()
                    stopFailures = 0
                    nextStopTry = .distantPast
                    if turn.notices.contains(VMNotices.stopFailed) {
                        turn.notices.removeAll { $0 == VMNotices.stopFailed }
                        continuation.yield(.updated(turn, milestone: false))
                    }
                }
                if stopRound > 0, !stopDelivered, !stopGaveUp, Date() >= nextStopTry {
                    let id = handle.id, control = handle.control
                    do {
                        try await AgentLoop.bounded(seconds: AgentRun.stopTimeLimit, label: "Stopping the reply") {
                            try await control.stop(id: id)
                        }
                        stopDelivered = true
                    } catch is CancellationError {
                        break
                    } catch {
                        if Task.isCancelled { break }
                        stopFailures += 1
                        if Date().timeIntervalSince(stopAskedAt) >= stopRetryWindow {
                            // Said plainly: the reply may well still be going on the computer.
                            stopGaveUp = true
                            if !turn.notices.contains(VMNotices.stopFailed) { turn.notices.append(VMNotices.stopFailed) }
                            continuation.yield(.updated(turn, milestone: true))
                        } else {
                            nextStopTry = Date().addingTimeInterval(AgentRun.stopRetryDelay(afterFailures: stopFailures))
                        }
                    }
                }
                let asked = Date()
                do {
                    // A check that hangs is given up on, so one stuck request can't hold the reply's
                    // progress back; the next check goes out straight after.
                    let id = handle.id, control = handle.control, after = seq
                    let poll = try await AgentLoop.bounded(seconds: AgentRun.pollTimeLimit, label: "Checking on the reply") {
                        try await control.poll(id: id, after: after)
                    }
                    if turn.notices.contains(VMNotices.lostContact) || turn.notices.contains(VMNotices.signInNeeded) {
                        turn.notices.removeAll { $0 == VMNotices.lostContact || $0 == VMNotices.signInNeeded }
                        continuation.yield(.updated(turn, milestone: false))
                    }
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
                            // Handed back by the runner: these were sent before anything still
                            // waiting here, so they go first.
                            await steering.prepend(state.unconsumedSteering)
                            turn.notices.removeAll { $0 == VMNotices.stopFailed }
                            if turn.status == .running { turn.status = .stopped }
                            AgentLoop.settleRunningTools(in: &turn)
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
                            if stopRound > 0 {
                                finish("Stopped on your computer.", stoppedEarly: false)
                            } else {
                                // Say why, from the runner's own last words (a crash or the computer
                                // ending it); "the runner stopped" alone told nobody anything.
                                let id = handle.id, control = handle.control
                                let words = (try? await AgentLoop.bounded(seconds: 20, label: "Reading why the runner stopped") { try await control.logTail(id: id) }) ?? ""
                                finish(VMNotices.runnerEnded + (words.isEmpty ? "" : " Its last words: \(words)"), stoppedEarly: true)
                            }
                            break
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    // The phone was asleep in the middle of the check (iOS froze the app): that
                    // says nothing about the computer, so it isn't counted.
                    if Date().timeIntervalSince(asked) > AgentRun.pollTimeLimit * 2 { continue }
                    failures += 1
                    if ConnectorReconnectPolicy.isSignInRefused(error) {
                        if !turn.notices.contains(VMNotices.signInNeeded) {
                            turn.notices.removeAll { $0 == VMNotices.lostContact }
                            turn.notices.append(VMNotices.signInNeeded)
                            continuation.yield(.updated(turn, milestone: true))
                        }
                    } else if failures == 8 {
                        // The reply may well still be going on the computer. The app keeps
                        // trying, more slowly, and picks it up the moment the computer answers
                        // (it used to stop trying until the app was closed and opened again).
                        if !turn.notices.contains(VMNotices.lostContact) { turn.notices.append(VMNotices.lostContact) }
                        continuation.yield(.updated(turn, milestone: true))
                    }
                }
                let wait = failures >= 8 ? min(UInt64(failures - 6) * 5_000_000_000, 30_000_000_000) : pollInterval
                try? await Task.sleep(nanoseconds: wait)
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
    public static let lostContact = "Lost contact with your computer. The reply keeps going there, and MAIPA-G keeps trying to reach it."
    public static let signInNeeded = "Your computer's connector needs you to sign in again (Settings → Connectors). The reply keeps going there, and shows up here once you do."
    public static let stopFailed = "MAIPA-G couldn't reach your computer to stop this reply, so it may still be running there. Tap Stop again to try again."

    public static func fellBack(_ reason: String) -> String {
        "Your computer couldn't take this reply (\(reason)), so it runs on the phone and stops if you leave the app."
    }

    static func isPhoneNotice(_ notice: String) -> Bool {
        notice == runningOnComputer || notice == cantStayAwake || notice == stopFailed || notice.hasPrefix("Your computer couldn't take")
    }
}
