import Foundation

/// Summary of an active or saved workflow run exposed to chat tools and UI cards.
public struct ActiveWorkflowRunSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var definition: WorkflowDefinition
    public var checkpoint: WorkflowCheckpoint
    public var isRunning: Bool
    public var errorMessage: String?

    public init(
        id: String,
        definition: WorkflowDefinition,
        checkpoint: WorkflowCheckpoint,
        isRunning: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.definition = definition
        self.checkpoint = checkpoint
        self.isRunning = isRunning
        self.errorMessage = errorMessage
    }

    public func formattedTreeSummary() -> String {
        var lines: [String] = []
        let stateLabel: String = {
            if isRunning { return "RUNNING" }
            if checkpoint.isCancelled { return "STOPPED" }
            if checkpoint.pendingQuestion != nil || checkpoint.isPausedByUser { return "PAUSED" }
            if errorMessage != nil { return "FAILED" }
            return "COMPLETED"
        }()
        lines.append("Workflow: \(definition.name) (\(definition.id)) — \(stateLabel)")
        if let model = checkpoint.defaultModelID {
            let effort = checkpoint.defaultEffort.map { " · effort: \($0.rawValue)" } ?? ""
            lines.append("Default model: \(model)\(effort) · Cost: $\(String(format: "%.4f", checkpoint.cumulativeCost))")
        }
        func render(_ nodes: [WorkflowNode], indent: String) {
            for node in nodes {
                let status = checkpoint.statuses[node.id]?.rawValue ?? "pending"
                let iter = checkpoint.repeatIterations[node.id].map { " (round \($0))" } ?? ""
                let modelNote = node.modelID.map { " [\($0)]" } ?? ""
                lines.append("\(indent)- [\(status)] \(node.title) (`\(node.id)`, \(node.kind.rawValue))\(iter)\(modelNote)")
                if !node.children.isEmpty {
                    render(node.children, indent: indent + "  ")
                }
            }
        }
        render(definition.steps, indent: "")
        if let pending = checkpoint.pendingQuestion {
            lines.append("Waiting on (\(pending.nodeID)): \(pending.text) [\(pending.options.joined(separator: " / "))]")
        }
        if let errorMessage, !errorMessage.isEmpty {
            lines.append("Error: \(errorMessage)")
        }
        if !checkpoint.outputs.isEmpty {
            lines.append("\nLatest step outputs:")
            for output in checkpoint.outputs.suffix(6) {
                let snippet = String(output.text.prefix(600))
                lines.append("### \(output.title) (`\(output.nodeID)`)\n\(snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Validates and saves a reusable Kiro-parity 5-node workflow recipe (`step`/`agent`, `sequence`,
/// `repeat`, `parallel`, `watch`; `<= 50` steps, `<= 8` depth, unique IDs, no Free AIs).
public struct SaveWorkflowDefinitionTool: AgentTool {
    public let name = "save_workflow_definition"
    private let knownAgentIDs: @Sendable () async -> Set<String>
    private let saveHandler: @Sendable (WorkflowDefinition) async throws -> WorkflowDefinition

    public init(
        knownAgentIDs: @escaping @Sendable () async -> Set<String>,
        saveHandler: @escaping @Sendable (WorkflowDefinition) async throws -> WorkflowDefinition
    ) {
        self.knownAgentIDs = knownAgentIDs
        self.saveHandler = saveHandler
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
            Save a validated multi-step workflow recipe (up to 50 steps and 8 nesting levels) so the person can review and run it. \
            Supported step `kind` values: `"step"` (or `"agent"`), `"sequence"`, `"repeat"` (`maxIterations`, `onMaxIterations`: `"pause"|"continue"|"fail"`, `containsText` or `goal`), `"parallel"` (`joinPolicy`: `"all"|"allSettled"|"any"`), `"watch"` (`maxIterations`, `pollIntervalSeconds`, `containsText`), and `"ask"`. \
            Steps may reference earlier outputs via `{{stepId.output}}` and override `modelId` / `effortLevel`.
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Optional stable workflow slug (e.g. `audit-and-fix`)."],
                    "name": ["type": "string", "description": "Human-readable workflow title."],
                    "summary": ["type": "string", "description": "One-sentence summary of what the workflow accomplishes."],
                    "steps": [
                        "type": "array",
                        "description": "Ordered list of workflow nodes (`id`, `kind`, `title`, `instruction`/`prompt`, optional `agent`, `modelId`, `effortLevel`, `children`/`steps`, etc.).",
                        "items": ["type": "object"],
                    ],
                ],
                "required": ["name", "summary", "steps"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        "Saving workflow \(arguments.optionalString("name") ?? "")…"
    }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let title = arguments.optionalString("name") ?? "Custom Workflow"
        let stepCount = (arguments["steps"]?.arrayValue ?? []).count
        return ToolApprovalRequest(
            question: "Approve and save workflow \"\(title)\" (\(stepCount) top-level step\(stepCount == 1 ? "" : "s"))?",
            allowLabel: "Approve workflow"
        )
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let approval = await approvalRequest(for: arguments) {
            throw ToolApprovalRequired(approval)
        }
        return try await runApproved(arguments: arguments, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let definition = try await parseAndValidate(arguments: arguments)
        let saved = try await saveHandler(definition)
        return ToolOutput(
            forModel: "Saved approved workflow \"\(saved.name)\" (id: `\(saved.id)`, \(saved.allNodes.count) total steps).",
            summary: "Saved workflow \(saved.name)",
            detail: "\(saved.name) (`\(saved.id)`)\n\(saved.summary)\nTotal steps: \(saved.allNodes.count)"
        )
    }

    private func parseAndValidate(arguments: JSONValue) async throws -> WorkflowDefinition {
        let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = try arguments.requiredString("summary").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stepsValue = arguments["steps"] else {
            throw ToolInputError("steps array is required.")
        }
        let stepsData = try JSONEncoder().encode(stepsValue)
        let decodedSteps: [WorkflowNode]
        do {
            decodedSteps = try JSONDecoder().decode([WorkflowNode].self, from: stepsData)
        } catch {
            throw ToolInputError("Invalid workflow step recipe: \(error.localizedDescription)")
        }
        let rawID = arguments.optionalString("id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanID: String = {
            if let rawID, !rawID.isEmpty { return rawID }
            let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            return "workflow-" + String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32)
        }()
        let definition = WorkflowDefinition(
            id: cleanID,
            name: name,
            summary: summary,
            steps: decodedSteps,
            isBuiltIn: false,
            isApproved: true
        )
        let validAgents = await knownAgentIDs()
        let errors = definition.validationErrors(agentIDs: validAgents)
        if !errors.isEmpty {
            throw ToolInputError("Workflow validation failed: " + errors.joined(separator: " "))
        }
        return definition
    }
}

/// Runs a saved or inline Kiro workflow after explicit plan approval, wrapping the user's goal
/// inside `<workflow_prompt>...</workflow_prompt>` and returning a structured checkpoint summary.
public struct RunWorkflowTool: AgentTool {
    public let name = "run_workflow"
    private let resolveWorkflow: @Sendable (String) async -> WorkflowDefinition?
    private let knownAgentIDs: @Sendable () async -> Set<String>
    private let executeHandler: @Sendable (WorkflowDefinition, String, @escaping @Sendable (String) -> Void) async throws -> ActiveWorkflowRunSnapshot

    public init(
        resolveWorkflow: @escaping @Sendable (String) async -> WorkflowDefinition?,
        knownAgentIDs: @escaping @Sendable () async -> Set<String>,
        executeHandler: @escaping @Sendable (WorkflowDefinition, String, @escaping @Sendable (String) -> Void) async throws -> ActiveWorkflowRunSnapshot
    ) {
        self.resolveWorkflow = resolveWorkflow
        self.knownAgentIDs = knownAgentIDs
        self.executeHandler = executeHandler
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Run an approved built-in or custom workflow (or an inline 5-node workflow recipe) in fresh per-step agent sessions with checkpointing. Always pauses for the person's approval before starting.",
            parameters: [
                "type": "object",
                "properties": [
                    "workflow_id": ["type": "string", "description": "ID of an existing built-in or saved workflow (e.g. `full-feature`, `two-ai-review`, `checklist`, or a saved custom workflow ID)."],
                    "prompt": ["type": "string", "description": "Goal and context passed into `<workflow_prompt>` for the workflow."],
                    "inline_workflow": [
                        "type": "object",
                        "description": "Optional inline workflow definition (`name`, `summary`, `steps`) when running a one-off workflow without saving first.",
                    ],
                ],
                "required": ["prompt"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String {
        let id = arguments.optionalString("workflow_id") ?? arguments["inline_workflow"]?["name"]?.stringValue ?? "workflow"
        return "Running workflow \(id)…"
    }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let label = arguments.optionalString("workflow_id")
            ?? arguments["inline_workflow"]?["name"]?.stringValue
            ?? "workflow"
        return ToolApprovalRequest(
            question: "Start workflow \"\(label)\" now?",
            allowLabel: "Run workflow"
        )
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let approval = await approvalRequest(for: arguments) {
            throw ToolApprovalRequired(approval)
        }
        return try await runApproved(arguments: arguments, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let prompt = try arguments.requiredString("prompt")
        let definition: WorkflowDefinition
        if let workflowID = arguments.optionalString("workflow_id"), !workflowID.isEmpty {
            guard var found = await resolveWorkflow(workflowID) else {
                throw ToolInputError("No workflow found with id `\(workflowID)`.")
            }
            found.isApproved = true
            definition = found
        } else if let inline = arguments["inline_workflow"] {
            let name = inline["name"]?.stringValue ?? "Inline Workflow"
            let summary = inline["summary"]?.stringValue ?? prompt
            guard let stepsValue = inline["steps"] else {
                throw ToolInputError("inline_workflow requires a `steps` array.")
            }
            let data = try JSONEncoder().encode(stepsValue)
            let steps = try JSONDecoder().decode([WorkflowNode].self, from: data)
            let candidate = WorkflowDefinition(
                id: "inline-\(UUID().uuidString.prefix(8).lowercased())",
                name: name,
                summary: summary,
                steps: steps,
                isBuiltIn: false,
                isApproved: true
            )
            let errors = candidate.validationErrors(agentIDs: await knownAgentIDs())
            if !errors.isEmpty {
                throw ToolInputError("Inline workflow validation failed: " + errors.joined(separator: " "))
            }
            definition = candidate
        } else {
            throw ToolInputError("Provide either `workflow_id` or `inline_workflow`.")
        }

        let snapshot = try await executeHandler(definition, prompt, progress)
        let tree = snapshot.formattedTreeSummary()
        return ToolOutput(
            forModel: tree,
            summary: "Workflow \(definition.name) · \(snapshot.isRunning ? "running" : (snapshot.checkpoint.pendingQuestion != nil ? "paused" : "finished"))",
            detail: tree,
            billedCost: snapshot.checkpoint.cumulativeCost
        )
    }
}

public struct InspectWorkflowTool: AgentTool {
    public let name = "inspect_workflow"
    private let inspectHandler: @Sendable (String?) async -> String

    public init(inspectHandler: @escaping @Sendable (String?) async -> String) {
        self.inspectHandler = inspectHandler
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Inspect active workflow runs, step statuses, outputs, and available built-in or saved workflow definitions.",
            parameters: [
                "type": "object",
                "properties": [
                    "workflow_id": ["type": "string", "description": "Optional workflow or run ID to inspect in detail. Omit to list active runs and saved definitions."],
                ],
                "additionalProperties": false,
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Inspecting workflows…" }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        let report = await inspectHandler(arguments.optionalString("workflow_id"))
        return ToolOutput(forModel: report, summary: "Inspected workflows", detail: report)
    }
}

public struct UpdateWorkflowTool: AgentTool {
    public let name = "update_workflow"
    private let replaceHandler: @Sendable (String?, [WorkflowNode]) async throws -> String

    public init(replaceHandler: @escaping @Sendable (String?, [WorkflowNode]) async throws -> String) {
        self.replaceHandler = replaceHandler
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "Update an active or paused workflow using `replace_remaining` to replace unexecuted remaining top-level steps (validated against the 50-step / 8-depth limits).",
            parameters: [
                "type": "object",
                "properties": [
                    "operation": ["type": "string", "enum": ["replace_remaining"]],
                    "run_id": ["type": "string", "description": "Optional active workflow run ID (defaults to the latest active run in this chat)."],
                    "steps": [
                        "type": "array",
                        "description": "Replacement remaining workflow steps.",
                        "items": ["type": "object"],
                    ],
                ],
                "required": ["operation", "steps"],
            ]
        )
    }

    public func runningSummary(for arguments: JSONValue) -> String { "Updating workflow steps…" }

    public func approvalRequest(for arguments: JSONValue) async -> ToolApprovalRequest? {
        let count = (arguments["steps"]?.arrayValue ?? []).count
        return ToolApprovalRequest(
            question: "Replace the remaining steps of this workflow with \(count) updated step\(count == 1 ? "" : "s")?",
            allowLabel: "Update workflow"
        )
    }

    public func run(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        if let approval = await approvalRequest(for: arguments) {
            throw ToolApprovalRequired(approval)
        }
        return try await runApproved(arguments: arguments, progress: progress)
    }

    public func runApproved(arguments: JSONValue, progress: @escaping @Sendable (String) -> Void) async throws -> ToolOutput {
        guard arguments.optionalString("operation") == "replace_remaining" else {
            throw ToolInputError("operation must be replace_remaining.")
        }
        guard let stepsValue = arguments["steps"] else {
            throw ToolInputError("steps array is required.")
        }
        let data = try JSONEncoder().encode(stepsValue)
        let steps = try JSONDecoder().decode([WorkflowNode].self, from: data)
        let summary = try await replaceHandler(arguments.optionalString("run_id"), steps)
        return ToolOutput(forModel: summary, summary: "Updated workflow steps", detail: summary)
    }
}
