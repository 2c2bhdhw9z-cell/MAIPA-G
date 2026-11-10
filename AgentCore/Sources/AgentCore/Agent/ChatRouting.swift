import Foundation

/// What a chat message is asking for, decided from its words alone.
///
/// The chat decides, like Kiro: you type, and the app works out whether that is an answer or a
/// multi-step job. Deliberately conservative: a plain question must never start a workflow, so
/// anything that is not clearly asking for multi-step work is answered normally. This lives in
/// AgentCore, with no app types, so the decision is covered by tests on Linux.
///
/// It never decides anything about money. Whatever it returns starts the way sub-agents do, under
/// the ordinary spend limit and stop-and-ask setting, with no second confirmation of its own.
public enum ChatRouting {
    public enum Decision: String, Sendable, Equatable {
        /// Answer in the chat, as normal.
        case answer
        /// A request to plan something out: investigate and report, no feature build.
        case plan
        /// A request for multi-step work from start to finish.
        case multiStep

        /// The built-in workflow this decision starts, or nil to answer normally.
        public var workflowID: String? {
            switch self {
            case .answer: return nil
            case .plan: return "look-into-something"
            case .multiStep: return "full-feature"
            }
        }
    }

    static let questionStarts = [
        "what ", "what's ", "whats ", "why ", "who ", "when ", "where ", "which ", "how ",
        "is ", "are ", "does ", "did ", "should ", "would ", "will ", "can i ",
        "explain ", "tell me ",
    ]

    static let multiStepCues = [
        "workflow", "step by step", "step-by-step", "end to end", "end-to-end",
        "full feature", "implement the whole", "build the whole", "do all of",
    ]

    static let planCues = [
        "plan this out", "plan it out", "plan out", "write a plan", "make a plan",
        "break this down into steps", "break it down into steps",
    ]

    public static func decide(_ request: String) -> Decision {
        let text = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard text.count >= 12 else { return .answer }
        // A question is an answer, not a job, whatever else it says ("how do I plan this out?").
        if questionStarts.contains(where: { text.hasPrefix($0) }) { return .answer }
        let asksForMultiStep = multiStepCues.contains { text.contains($0) }
        let asksForPlan = planCues.contains { text.contains($0) }
        // A question mark with no clear request for work is a question.
        if text.contains("?"), !asksForPlan, !asksForMultiStep { return .answer }
        if asksForMultiStep { return .multiStep }
        if asksForPlan { return .plan }
        return .answer
    }
}
