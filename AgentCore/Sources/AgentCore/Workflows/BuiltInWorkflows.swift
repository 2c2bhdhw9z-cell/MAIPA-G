import Foundation

public enum BuiltInWorkflows {
    public static let all: [WorkflowDefinition] = [
        workflow("look-into-something", "Look into something", "Investigate a question and return an evidence-based report.", [
            .agent("look.investigate", title: "Investigate", agent: "investigator", instruction: "Find the answer or root cause and report the evidence."),
        ]),
        workflow("keep-going", "Keep going until a goal is met", "Repeat checked work in bounded rounds and pause at the limit.", [
            .repeatUntil("keep.repeat", title: "Work toward the goal", maximum: 5, goal: "The user's stated goal is met and verified.", steps: [
                .agent("keep.work", title: "Make the next improvement", agent: "coder", instruction: "Take the next useful step toward the goal and verify it."),
                .agent("keep.check", title: "Check the goal", agent: "code-checker", instruction: "Check whether the goal is fully met. Mark it met only with evidence."),
            ]),
        ]),
        workflow("checklist", "Work through a checklist", "Complete an ordered checklist with a final independent check.", [
            .agent("checklist.plan", title: "Read the checklist", agent: "planner", instruction: "Turn the supplied checklist into an exact ordered work plan."),
            .agent("checklist.work", title: "Complete the checklist", agent: "coder", instruction: "Complete every checklist item in order and run its checks."),
            .agent("checklist.review", title: "Check every item", agent: "code-checker", instruction: "Verify every checklist item against the resulting work."),
        ]),
        workflow("full-feature", "Full feature", "Requirements, design, checked design, plan, build, independent two-AI review, and final check.", [
            .agent("full.requirements", title: "Requirements", agent: "planner", instruction: "Write complete, testable requirements and resolve consequential unknowns."),
            .ask("full.requirements-approval", title: "Approve requirements", question: "Are these requirements approved?", options: ["Approve", "Stop"]),
            .agent("full.design", title: "Design", agent: "designer", instruction: "Design the feature from the approved requirements."),
            .ask("full.design-approval", title: "Approve design", question: "Is this design approved?", options: ["Approve", "Stop"]),
            .agent("full.design-check", title: "Checked design", agent: "design-checker", instruction: "Check the design against every approved requirement."),
            .ask("full.design-check-approval", title: "Approve checked design", question: "Is the checked design approved?", options: ["Approve", "Stop"]),
            .agent("full.plan", title: "Implementation plan", agent: "planner", instruction: "Produce an ordered implementation and verification plan from the checked design."),
            .ask("full.plan-approval", title: "Approve implementation plan", question: "Is this implementation plan approved and ready to build?", options: ["Approve", "Stop"]),
            .agent("full.build", title: "Implementation", agent: "coder", instruction: "Implement the approved plan completely and run its checks."),
            .parallel("full.reviews", title: "Independent two-AI review", agents: [
                .agent("full.review-one", title: "Code checker", agent: "code-checker", instruction: "Review the implementation independently."),
                .agent("full.review-two", title: "Second opinion", agent: "second-opinion", instruction: "Use a different model and review independently."),
            ]),
            .agent("full.combine", title: "Combine reviews", agent: "review-combiner", instruction: "Combine both independent reviews into one checked finding list."),
            .agent("full.final", title: "Final check", agent: "code-checker", instruction: "Perform the final requirement-by-requirement check after review findings are resolved."),
        ]),
        workflow("two-ai-review", "Two-AI review", "Run independent reviews with different AIs, then combine them.", [
            .parallel("review.parallel", title: "Two independent reviews", agents: [
                .agent("review.primary", title: "Code checker", agent: "code-checker", instruction: "Review the work independently."),
                .agent("review.second", title: "Second opinion", agent: "second-opinion", instruction: "Review independently with a different model."),
            ]),
            .agent("review.combine", title: "Combine findings", agent: "review-combiner", instruction: "Combine both reviews and preserve disagreements."),
        ]),
        workflow("experiment", "Experiment until it's better", "Run measured experiments in bounded rounds and keep only verified improvements.", [
            .repeatUntil("experiment.repeat", title: "Measure and improve", maximum: 5, goal: "The agreed measurement has improved and the result passes its checks.", steps: [
                .agent("experiment.try", title: "Run an experiment", agent: "researcher", instruction: "Measure the baseline, try one change, and keep it only if it improves the result."),
                .agent("experiment.check", title: "Check the result", agent: "code-checker", instruction: "Independently check the measurement and regression tests."),
            ]),
        ]),
        workflow("side-copy-review", "Send a side copy for review", "Check work, open its pull request, and handle review feedback.", [
            .agent("side.check", title: "Check the work", agent: "code-checker", instruction: "Review the side copy and confirm it is ready to send."),
            .agent("side.send", title: "Send the request", agent: "request-sender", instruction: "Open or update the pull request with verified details."),
            .ask("side.wait", title: "Wait for review", question: "Review feedback is ready. What should MAIPA-G do?", options: ["Handle the feedback", "Stop here"]),
            .agent("side.feedback", title: "Handle feedback", agent: "feedback-answerer", instruction: "Handle every unresolved review comment and verify any fixes."),
        ]),
        workflow("build-ipa", "Build and check the IPA", "Start the requested iPhone build and inspect its produced IPA.", [
            .agent("ipa.build", title: "Build and inspect", agent: "builder", instruction: "The user explicitly requested this build. Start it, wait for completion, and inspect the IPA contents."),
            .agent("ipa.check", title: "Final build check", agent: "code-checker", instruction: "Check the build evidence and IPA inspection against the request."),
        ]),
    ]

    public static var byID: [String: WorkflowDefinition] { Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }) }
    public static func named(_ id: String) -> WorkflowDefinition? { byID[id] }

    private static func workflow(_ id: String, _ name: String, _ summary: String, _ steps: [WorkflowNode]) -> WorkflowDefinition {
        WorkflowDefinition(id: id, name: name, summary: summary, steps: steps, isBuiltIn: true)
    }
}
