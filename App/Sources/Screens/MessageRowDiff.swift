import AgentCore
import Foundation

/// Whether a chat row needs redrawing, decided from ids, counts, statuses and text lengths.
/// Comparing whole messages compared every attachment (one message has 5,587) and every
/// tool's full output, for every row, on every update while a reply streamed in.
enum MessageRowDiff {
    static func same(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        guard lhs.id == rhs.id, lhs.createdAt == rhs.createdAt, lhs.starredMemoryID == rhs.starredMemoryID else { return false }
        switch (lhs.body, rhs.body) {
        case (.user(let a), .user(let b)):
            return sameText(a.text, b.text) && sameAttachments(a.attachments, b.attachments)
        case (.assistant(let a), .assistant(let b)):
            return sameTurn(a, b)
        default:
            return false
        }
    }

    /// Short text is compared in full; long text by its length and both ends, which catches
    /// streaming (it grows) and a rolling window (its ends move) without reading it all.
    static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        let count = lhs.utf8.count
        guard count == rhs.utf8.count else { return false }
        if count <= 1_024 { return lhs == rhs }
        return lhs.utf8.prefix(256).elementsEqual(rhs.utf8.prefix(256))
            && lhs.utf8.suffix(256).elementsEqual(rhs.utf8.suffix(256))
    }

    static func sameText(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let a?, let b?): return sameText(a, b)
        default: return false
        }
    }

    static func sameAttachments(_ lhs: [AttachmentReference], _ rhs: [AttachmentReference]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard let first = lhs.first, let last = lhs.last else { return true }
        return first == rhs.first && last == rhs.last && lhs[lhs.count / 2] == rhs[rhs.count / 2]
    }

    static func sameTurn(_ lhs: AssistantTurn, _ rhs: AssistantTurn) -> Bool {
        guard lhs.status == rhs.status,
              lhs.steps.count == rhs.steps.count,
              lhs.failure == rhs.failure,
              lhs.notices == rhs.notices,
              lhs.routeLabel == rhs.routeLabel,
              lhs.spendCheck == rhs.spendCheck,
              lhs.approvedSpendUpTo == rhs.approvedSpendUpTo,
              lhs.stoppedEarly == rhs.stoppedEarly,
              lhs.balanceBefore == rhs.balanceBefore,
              lhs.balanceAfter == rhs.balanceAfter,
              lhs.balanceProvider == rhs.balanceProvider,
              lhs.balanceShared == rhs.balanceShared,
              lhs.balancesBefore == rhs.balancesBefore,
              lhs.balancesAfter == rhs.balancesAfter,
              lhs.providersTried == rhs.providersTried else { return false }
        for (a, b) in zip(lhs.steps, rhs.steps) where !sameStep(a, b) {
            return false
        }
        return true
    }

    static func sameStep(_ lhs: AssistantStep, _ rhs: AssistantStep) -> Bool {
        guard lhs.id == rhs.id,
              lhs.startedAt == rhs.startedAt,
              lhs.finishedAt == rhs.finishedAt,
              lhs.reasoningFinishedAt == rhs.reasoningFinishedAt,
              lhs.model == rhs.model,
              lhs.provider == rhs.provider,
              lhs.providersTried == rhs.providersTried,
              lhs.finishReason == rhs.finishReason,
              lhs.usage == rhs.usage,
              lhs.timing == rhs.timing,
              lhs.citations == rhs.citations,
              lhs.generatedImages == rhs.generatedImages,
              lhs.steeredMessages == rhs.steeredMessages,
              lhs.toolCalls.count == rhs.toolCalls.count,
              sameText(lhs.text, rhs.text),
              sameText(lhs.reasoning, rhs.reasoning) else { return false }
        for (a, b) in zip(lhs.toolCalls, rhs.toolCalls) where !sameCall(a, b) {
            return false
        }
        return true
    }

    static func sameCall(_ lhs: ToolCallRecord, _ rhs: ToolCallRecord) -> Bool {
        guard lhs.id == rhs.id,
              lhs.name == rhs.name,
              lhs.status == rhs.status,
              lhs.summary == rhs.summary,
              lhs.startedAt == rhs.startedAt,
              lhs.finishedAt == rhs.finishedAt,
              lhs.billedCost == rhs.billedCost,
              lhs.questions == rhs.questions,
              lhs.livePreview == rhs.livePreview,
              sameText(lhs.arguments, rhs.arguments),
              sameText(lhs.detail, rhs.detail),
              sameText(lhs.result, rhs.result) else { return false }
        switch (lhs.subagents, rhs.subagents) {
        case (nil, nil):
            return true
        case (let a?, let b?):
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where !sameSubagent(x, y) {
                return false
            }
            return true
        default:
            return false
        }
    }

    static func sameSubagent(_ lhs: SubagentRunItem, _ rhs: SubagentRunItem) -> Bool {
        lhs.id == rhs.id
            && lhs.agentID == rhs.agentID
            && lhs.name == rhs.name
            && lhs.model == rhs.model
            && lhs.status == rhs.status
            && lhs.toolCallCount == rhs.toolCallCount
            && lhs.cost == rhs.cost
            && lhs.latestActivity == rhs.latestActivity
            && lhs.explanation == rhs.explanation
            && lhs.toolSummaries.count == rhs.toolSummaries.count
            && lhs.toolSummaries.last == rhs.toolSummaries.last
            && sameText(lhs.task, rhs.task)
            && sameText(lhs.liveThought, rhs.liveThought)
            && sameText(lhs.output, rhs.output)
    }
}
