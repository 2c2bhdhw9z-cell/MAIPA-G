import Foundation

public enum BuiltInAgents {
    public static let inspectToolNames = [
        "list_files", "search_code", "read_file", "read_repo_file", "read_other_repo_file",
        "load_repo_rules", "inspect_workspace", "read_attachment",
        "list_workstation_files", "read_workstation_file",
        "web_search", "read_web_page", "introspect", "inspect_workflow", "ask_user",
    ]
    public static let generalExecutionToolNames = inspectToolNames + [
        "create_file", "edit_file", "append_file", "delete_file", "save_changes",
        "write_workstation_file", "run_command", "run_shell", "computer_task", "sync_staged_to_computer",
        "mcp_*",
    ]

    private static let inspect = ["list_files", "search_code", "read_file", "read_repo_file", "inspect_workspace", "read_attachment", "web_search", "read_web_page", "ask_user"]
    private static let change = inspect + ["create_file", "edit_file", "append_file", "delete_file", "save_changes", "run_shell", "run_command"]
    private static let review = inspect + ["read_pull_request", "read_pull_request_comments", "read_checks", "read_workflow_logs"]
    private static let build = change + ["list_workflows", "dispatch_workflow", "read_checks", "read_workflow_logs", "list_artifacts", "inspect_ipa", "read_releases"]

    /// Core 13 workflow/product agents (count and IDs preserved for existing workflow & regression contracts).
    public static let all: [AgentDefinition] = [
        agent("planner", "Planner", "Turns a request into checked requirements and an ordered plan.", "Clarify only consequential unknowns, inspect the project, state requirements, dependencies, acceptance checks, and a practical implementation order. Do not implement.", inspect, .hard, .strong, .reportOnly, 3),
        agent("designer", "Designer", "Designs product behavior and technical structure before implementation.", "Produce a concrete design that fits the existing product and code. Cover user-visible states, data flow, failure behavior, accessibility, and test strategy. Do not implement.", inspect, .hard, .strong, .reportOnly, 3),
        agent("design-checker", "Design checker", "Checks a design for omissions, conflicts, and unsafe assumptions.", "Independently compare the design with the request, repository rules, and current code. Report specific findings and required corrections. Do not rewrite or implement it.", review, .hard, .differentFromPrimary, .review, 2),
        agent("coder", "Coder", "Implements an approved plan and verifies the result.", "Read the relevant code, make the smallest complete production change, preserve existing behavior, and run the required checks. Ask before destructive or build-setup changes unless already authorized.", change, .normal, .automatic, .changesAllowed, 4),
        agent("code-checker", "Code checker", "Reviews implemented code and verification evidence.", "Review the actual diff and surrounding code for correctness, regressions, security, missing requirements, and missing tests. Report actionable findings with file locations. Do not edit.", review, .hard, .strong, .review, 3),
        agent("second-opinion", "Second opinion", "Performs an independent review with a different AI.", "Review independently without seeing another review's conclusions first. Look for requirement gaps, incorrect assumptions, regressions, and untested behavior. Report only.", review, .hard, .differentFromPrimary, .review, 2),
        agent("review-combiner", "Review combiner", "Combines independent reviews without losing disagreements.", "Deduplicate findings, preserve disagreements, rank issues by impact, reject unsupported claims, and produce one checked action list. Do not edit code.", inspect, .hard, .strong, .reportOnly, 2),
        agent("investigator", "Investigator", "Finds root causes and reports evidence without changing anything.", "Reproduce or trace the problem, inspect relevant code and logs, distinguish facts from hypotheses, and report the root cause and viable fixes. Never mutate the repo.", review, .hard, .strong, .reportOnly, 4),
        agent("researcher", "Researcher", "Runs bounded experiments and keeps only improvements that work.", "Establish a baseline, try one measurable change at a time, verify it, keep successful changes, revert unsuccessful staged experiments, and report evidence. Never claim improvement without a comparison.", change, .hard, .automatic, .changesAllowed, 4),
        agent("builder", "Builder", "Starts requested builds and checks their real artifacts.", "Inspect existing workflows first. Dispatch a build only when the user's request explicitly asks for one. Watch checks, read failures, inspect the produced IPA contents, and report exact evidence.", build, .normal, .automatic, .build, 2),
        agent("workflow-maker", "Workflow maker", "Turns a plain-language goal into an editable workflow draft.", "Translate the request into typed agent, repeat, stop-and-ask, and parallel steps. Set finite repeat limits. Return a draft for explicit user approval; never run it before approval.", inspect, .hard, .strong, .reportOnly, 2),
        agent("request-sender", "Request sender", "Opens the side-copy request after checks pass.", "Confirm the intended base and head, summarize verified changes plainly, open or update the pull request, and return its link. Never merge it.", review + ["create_pull_request"], .normal, .automatic, .pullRequest, 0),
        agent("feedback-answerer", "Feedback answerer", "Handles review comments and verifies each resulting change.", "Read every unresolved review comment, determine whether it is valid, make focused fixes when needed, rerun relevant checks, reply with evidence, and leave disputed feedback clearly explained.", change + ["read_pull_request_comments", "reply_to_review_comment"], .hard, .automatic, .feedback, 3),
    ]

    /// Kiro's 5 first-class sub-agents for parallel and thorough delegation inside chat and workflows.
    public static let kiroSubagents: [AgentDefinition] = [
        agent(
            "context-gatherer",
            "Context Gatherer",
            "Explores repositories, files, attachments, and web docs thoroughly in parallel to gather exact context.",
            "Explore repositories, files, attachments, and web docs thoroughly to gather exact, verified context for the assigned task. Match the depth requested: for targeted questions, batch search/read calls in parallel and cite exact `path:line` locations; when asked to read an entire file, directory, module, or every single line of code, first enumerate every file with `list_files` and read every assigned file completely from line 1 to its final line (continuing with `start_line` whenever a file has remaining lines) — never skim, sample, or stop early. Return a complete, structured report with exact `path:line` citations. Never modify files or run mutating commands.",
            inspectToolNames,
            .hard,
            .automatic,
            .reportOnly,
            0
        ),
        agent(
            "general-task-execution",
            "General Task Execution",
            "Executes a self-contained implementation, analysis, or verification task end to end.",
            "Complete the assigned task thoroughly in your isolated context window. Read relevant files completely first, make surgical edits or run needed checks when permitted by the parent chat, verify your work, and return a clear summary of what changed and what was verified.",
            generalExecutionToolNames,
            .hard,
            .automatic,
            .changesAllowed,
            0
        ),
        agent(
            "semantic-reviewer",
            "Semantic Reviewer",
            "Audits code, diffs, security boundaries, concurrency, and edge cases independently.",
            "Perform a deep semantic review of the target code or staged changes. Check logic bugs, race conditions, security boundaries, error handling, UI layout traps, and test coverage. Cite exact file:line locations and concrete fixes. Never edit files.",
            inspectToolNames + ["read_pull_request", "read_pull_request_comments", "read_checks", "read_workflow_logs"],
            .hard,
            .strong,
            .review,
            0
        ),
        agent(
            "introspect",
            "Introspect",
            "Inspects MAIPA-G's live model, provider balances, repo, computer, connectors, and active jobs.",
            "Call `introspect` (and `inspect_workflow` when relevant) to check MAIPA-G's exact live state — selected AI model, provider, thinking effort, limits, USD balances across connected providers, GitHub repo/branch/commit, Linux computer status, connectors, and jobs — and report clearly without exposing secrets.",
            ["introspect", "inspect_workflow", "list_workstation_files"],
            .normal,
            .automatic,
            .reportOnly,
            0
        ),
        agent(
            "custom-agent-creator",
            "Custom Agent Creator",
            "Designs and saves reusable custom sub-agents or repository .kiro/agents definitions.",
            "Design a focused, well-scoped sub-agent for the user's goal with clear instructions, minimal necessary tool permissions, and safe read-only vs. changes-allowed behavior. Save it with `create_custom_agent` (or stage `.kiro/agents/<name>.json` when asked to add a repo agent) and summarize its capabilities.",
            inspectToolNames + ["create_custom_agent", "create_file", "edit_file"],
            .normal,
            .strong,
            .changesAllowed,
            0
        ),
    ]

    public static var allIncludingKiroSubagents: [AgentDefinition] {
        kiroSubagents + all
    }

    public static var byID: [String: AgentDefinition] { Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }) }
    public static var kiroByID: [String: AgentDefinition] { Dictionary(uniqueKeysWithValues: kiroSubagents.map { ($0.id, $0) }) }

    public static func named(_ id: String) -> AgentDefinition? {
        byID[id] ?? kiroByID[id]
    }

    private static func agent(
        _ id: String, _ name: String, _ summary: String, _ instructions: String,
        _ tools: [String], _ difficulty: TaskDifficulty, _ model: AgentModelPolicy,
        _ behavior: AgentBehavior, _ helpers: Int
    ) -> AgentDefinition {
        AgentDefinition(id: id, name: name, summary: summary, instructions: instructions, allowedTools: tools, difficulty: difficulty, modelPolicy: model, behavior: behavior, maximumHelpers: helpers, isBuiltIn: true)
    }
}
