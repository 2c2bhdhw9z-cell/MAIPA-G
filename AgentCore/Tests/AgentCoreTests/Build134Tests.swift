import Foundation
import Testing
@testable import AgentCore

@Suite("Build 134 — what the person asks for decides how a save lands")
struct Build134Tests {
    @Test("Saying main-only in the chat turns on direct saving")
    func requestTextTurnsOnDirectSave() {
        for phrase in [
            "fix the bug and only push to main",
            "just commit to main please",
            "push directly to main when done",
            "always save straight to main",
            "do it with no pull request",
            "no PRs, just main",
            "commit to the master branch directly",
        ] {
            #expect(RepoWriteRules.requestsDirectSave(phrase), "should match: \(phrase)")
        }
    }

    @Test("Ordinary mentions of main do not silently turn direct saves on")
    func ordinaryTextDoesNotTurnOnDirectSave() {
        for phrase in [
            "what does main do",
            "read main.swift",
            "the main screen is broken",
            "explain the master branch layout",
            "fix the login bug",
            "push the button on the main screen",
            "",
        ] {
            #expect(!RepoWriteRules.requestsDirectSave(phrase), "should not match: \(phrase)")
        }
    }

    @Test("The request outranks a settings switch that is off")
    func requestBeatsOffSetting() {
        let rules = RepoWriteRules.resolve(documents: [], directSaveSetting: false, requestText: "only push to main")
        #expect(rules.directSave)
        #expect(rules.reason?.contains("You asked") == true)
    }

    @Test("A plain request leaves the existing rules alone")
    func plainRequestKeepsRules() {
        let rules = RepoWriteRules.resolve(documents: [], directSaveSetting: false, requestText: "fix the login bug")
        #expect(!rules.directSave)

        let fromFile = RepoWriteRules.resolve(
            documents: [(".kiro/steering/owner-rules.md", "No pull requests.")],
            directSaveSetting: false,
            requestText: "fix the login bug"
        )
        #expect(fromFile.directSave)
    }
}
