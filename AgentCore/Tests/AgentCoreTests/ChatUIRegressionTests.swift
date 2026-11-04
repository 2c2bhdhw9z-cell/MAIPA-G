import Foundation
import Testing

/// Source-level wiring checks: AgentCore's Linux tests cannot render SwiftUI.
/// Brand resolution and bundled artwork are covered separately by AIModelBrandTests.
@Suite("Chat UI regression wiring")
struct ChatUIRegressionTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func section(_ text: String, from start: String, to end: String) throws -> String {
        let first = try #require(text.range(of: start))
        let last = try #require(text.range(of: end, range: first.upperBound..<text.endIndex))
        return String(text[first.lowerBound..<last.lowerBound])
    }

    private func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    @Test("Chat has one floating review entry, not inline save actions")
    func floatingReviewEntry() throws {
        let chat = try source("App/Sources/Screens/ChatScreen.swift")
        #expect(chat.components(separatedBy: "\"Review Changes\"").count - 1 == 1)
        let visibility = compact(try section(chat, from: "private var hasPendingSave", to: "private func bottomInset"))
        #expect(visibility.contains("ifsession.hasStagedChanges{returntrue}"))
        #expect(visibility.contains("receipt.resolution==nil&&(receipt.pullRequest!=nil||receipt.undoneAt==nil)"))
        let bottom = try section(chat, from: "private func bottomInset", to: "private func messageRows")
        let label = try #require(bottom.range(of: "Label(\"Review Changes\""))
        let button = try #require(bottom.range(of: "Button {", options: .backwards,
                                              range: bottom.startIndex..<label.lowerBound))
        let action = compact(String(bottom[button.lowerBound..<label.lowerBound]))
        #expect(action.contains("app.sheet=.workstation(.chat(session.id),.changes)"))
        let floating = try section(String(bottom[button.lowerBound...]), from: "Button {", to: "Composer(")
        #expect(floating.contains(".glassPanel("))
        #expect(floating.contains(".contentShape(Capsule())"))
        #expect(floating.contains(".shadow("))
        #expect(compact(floating).contains(".frame(minHeight:44)"))
        #expect(compact(chat).contains(".safeAreaInset(edge:.bottom,spacing:0){bottomInset(proxy:proxy)}"))
        for title in ["Add it", "Throw away", "Undo"] {
            #expect(!bottom.contains("\"\(title)\""))
        }
        for action in ["addLastSave(", "throwAwayLastSave(", "undoLastSave("] {
            #expect(!bottom.contains(action))
        }
    }

    @Test("Workstation Changes retains diff review and save actions")
    func workstationReviewActions() throws {
        let workstation = try source("App/Sources/Screens/WorkstationScreen.swift")
        #expect(workstation.contains("tab = initialTab"))
        #expect(compact(workstation).contains("case.changes:changesWorkspace"))
        let changes = compact(try section(workstation, from: "private var changesWorkspace", to: "private var workflowsWorkspace"))
        for (title, action) in [("Add it", "addLastSave"), ("Throw away", "throwAwayLastSave"), ("Undo", "undoLastSave")] {
            let role = title == "Throw away" ? ",role:.destructive" : ""
            let expected = "Button(\"\(title)\"\(role)){Task{awaitsession.\(action)()}}"
            #expect(changes.contains(compact(expected)))
        }
        #expect(changes.contains("CodeBlockView(language:\"diff\",code:diffText)"))
        #expect(changes.contains("awaitsession.stagedDiff()"))
        #expect(changes.contains("awaitsession.branchDiff()"))
    }

    @Test("Model controls pass stored IDs into bundled brand icons without CPU placeholders")
    func modelIconWiring() throws {
        let wiring = [
            ("Screens/HomeScreen.swift", "modelID: home.model.storedValue,"),
            ("Screens/ChatScreen.swift", "modelID: session.chat.model.storedValue,"),
            ("Screens/Composer.swift", "AIModelIcon(modelID: modelID,"),
            ("Screens/Pickers.swift", "AIModelIcon(modelID: model.id,"),
            ("Screens/WorkstationScreen.swift", "AIModelIcon(modelID: run.checkpoint.defaultModelID ?? ModelChoice.autoID,"),
            ("Design/AIModelIcon.swift", "AIModelBrand(modelID: modelID)")
        ]
        for (path, expected) in wiring {
            let text = try source("App/Sources/" + path)
            #expect(compact(text).contains(compact(expected)))
            #expect(!text.lowercased().contains("cpu"))
        }
        let icon = try source("App/Sources/Design/AIModelIcon.swift")
        #expect(icon.contains("if let assetName = brand.assetName"))
        #expect(icon.contains("Image(assetName)"))
        #expect(icon.contains("AIModelBrand.initials(for: modelID)"))
    }
}
