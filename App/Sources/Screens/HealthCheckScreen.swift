import AgentCore
import SwiftUI

struct HealthCheckScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Pushed inside Settings: no stack of its own and no Done button (Back returns to Settings).
    var embedded = false
    @State private var items: [Item] = []
    @State private var running = false
    @State private var confirmReplace = false
    @State private var toolsInstalling = false

    private struct Item: Identifiable {
        enum State { case good, warning, failed }
        enum Action { case github, openRouter, save, connector(UUID), computer, replaceComputer, setupTools, jobs }
        let id: String
        var title: String
        var detail: String
        var nextStep: String?
        var state: State
        var action: Action? = nil
    }

    var body: some View {
        OwnNavigationStack(embedded: embedded) {
            List {
                if running {
                    HStack { ProgressView(); Text("Checking everything…") }
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(item.state))
                            .foregroundStyle(color(item.state))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.body.weight(.medium))
                            Text(item.detail).font(.footnote).foregroundStyle(Theme.secondaryText)
                            if let next = item.nextStep {
                                Text(next).font(.footnote).foregroundStyle(item.state == .failed ? Theme.danger : .orange)
                            }
                            if let action = item.action {
                                Button(Self.label(for: action)) { fix(action) }.font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }
                if !running {
                    Button("Check again") { Task { await run() } }
                }
            }
            .navigationTitle("Check everything")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .task { await run() }
            .task(id: toolsInstalling) {
                guard toolsInstalling, !PreviewScenes.isActive else { return }
                while !Task.isCancelled, toolsInstalling {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled, toolsInstalling else { break }
                    await refreshComputerItemOnly()
                }
            }
            .alert("Replace the chat computer?", isPresented: $confirmReplace) {
                Button("Replace \(app.settings.chatComputerMachineName)", role: .destructive) {
                    Task { await replaceComputer() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MAIPA-G deletes the machine that isn't answering and creates a new one with the same name. Files on it are lost; your repos on GitHub and the phone's staged changes are not.")
            }
        }
    }

    private func setupTools() async {
        guard let control = app.connectors.computerControl() else { return }
        let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
        do {
            let message = try await control.startVerifiedSetup(revision: revision)
            toolsInstalling = true
            app.connectors.keepComputerAwakeDuringSetup(resetReadyCache: true)
            items.append(Item(id: "computer-setup", title: "Tool setup", detail: message, state: .good))
        } catch {
            items.append(Item(id: "computer-setup", title: "Tool setup", detail: ErrorExplainer.explain(error).message, nextStep: "Check the computer service, then try Set up tools again.", state: .failed, action: .setupTools))
        }
    }

    private func refreshComputerItemOnly() async {
        guard !running, !app.settings.chatComputerOff, let control = app.connectors.computerControl() else {
            toolsInstalling = false
            return
        }
        guard let output = try? await control.healthCheck() else { return }
        let updated = computerItem(for: control.machine, output: output)
        if let index = items.firstIndex(where: { $0.id == "computer" }) {
            items[index] = updated
        }
    }

    private func computerItem(for machine: String, output: String) -> Item {
        switch ComputerControl.toolState(output) {
        case .ready:
            toolsInstalling = false
            if let failed = ComputerControl.failedTools(output) {
                return Item(id: "computer", title: "Chat computer", detail: "\(machine) ran a command. Its tools are installed except these, which failed: \(failed).", nextStep: "Set up tools tries those again.", state: .warning, action: .setupTools)
            }
            UserDefaults.standard.set(true, forKey: ConnectorLibrary.toolsReadyDefaultsKey(machine))
            return Item(id: "computer", title: "Chat computer", detail: "\(machine) ran a command and its tools are installed.", state: .good)
        case .installing:
            toolsInstalling = true
            app.connectors.keepComputerAwakeDuringSetup()
            let step = ComputerControl.setupStep(output).map { " Now: \($0)." } ?? ""
            if ComputerControl.setupPausesWhenIdle(output) {
                return Item(id: "computer", title: "Chat computer", detail: "\(machine) runs commands. Its developer tools are finishing their one-time background install — MAIPA-G is keeping this computer awake while the app is open so setup can finish.\(step)", state: .good)
            }
            return Item(id: "computer", title: "Chat computer", detail: "\(machine) runs commands. Its developer tools are installing in the background (about 15 to 30 minutes the first time).\(step)", state: .good)
        case .missing:
            toolsInstalling = false
            return Item(id: "computer", title: "Chat computer", detail: "\(machine) runs commands, and its developer tools haven't been installed yet.", nextStep: "Tap Set up tools to start.", state: .warning, action: .setupTools)
        }
    }

    private func replaceComputer() async {
        guard let control = app.connectors.computerControl() else { return }
        running = true
        do {
            _ = try await control.ensureMachine(allowCreate: true, replaceBroken: true)
        } catch {
            items.append(Item(id: "computer-replace", title: "Replacing the computer", detail: ErrorExplainer.explain(error).message, nextStep: "Open the computer service's connector and check its sign-in and limits.", state: .failed, action: .computer))
        }
        running = false
        await run()
    }

    private func run() async {
        guard !running else { return }
        running = true
        items = []

        await app.github.refresh()
        if app.github.isConnected, app.github.reposError == nil {
            items.append(Item(id: "github", title: "GitHub App", detail: "Connected as \(app.github.login ?? "your account").", state: .good))
        } else {
            items.append(Item(id: "github", title: "GitHub App", detail: app.github.reposError ?? "Not connected.", nextStep: "Connect or sign in again in Settings.", state: .failed, action: .github))
        }

        await app.openRouter.refreshKeyInfo(force: true)
        if app.openRouter.hasOpenRouterKey, app.openRouter.keyInfo != nil {
            let balance = app.openRouter.balance.map { " Balance \($0.dollars)." } ?? ""
            let extras = app.openRouter.readyExternalProviders.isEmpty ? "" : " Extra gateways: \(app.openRouter.readyExternalProviders.map(\.name).joined(separator: ", "))."
            items.append(Item(id: "openrouter", title: "AI Providers", detail: "OpenRouter signed in.\(balance)\(extras)", state: .good))
        } else if !app.openRouter.readyExternalProviders.isEmpty {
            let names = app.openRouter.readyExternalProviders.map(\.name).joined(separator: ", ")
            items.append(Item(id: "openrouter", title: "AI Providers", detail: "Connected to \(names) (\(app.openRouter.allSelectableModels.count) models ready).", state: .good))
        } else {
            items.append(Item(id: "openrouter", title: "AI Providers", detail: app.openRouter.lastError ?? "No AI provider connected.", nextStep: "Connect OpenRouter, OneProvider, SayGM, TeamoRouter, or OmniRoute in Settings.", state: .failed, action: .openRouter))
        }

        await app.sync.syncNow()
        switch app.sync.status {
        case .idle:
            items.append(Item(id: "saving", title: "Saving", detail: app.sync.lastSaved.map { "Saved \($0.friendlyAgo)." } ?? "Ready.", state: .good))
        case .failed(let message):
            items.append(Item(id: "saving", title: "Saving", detail: message, nextStep: "Retry after fixing the named cause.", state: .failed, action: .save))
        case .off:
            items.append(Item(id: "saving", title: "Saving", detail: "On this phone only.", nextStep: "Connect GitHub to back up data.", state: .warning, action: .github))
        case .saving:
            items.append(Item(id: "saving", title: "Saving", detail: "Still saving.", state: .warning))
        }

        for connector in app.connectors.connected {
            await app.connectors.recheck(connector)
            let state = app.connectors.states[connector.id] ?? .disconnected
            let detail = app.connectors.errors[connector.id] ?? state.rawValue
            let isGitHubMCP = connector.displayName.caseInsensitiveCompare("GitHub") == .orderedSame
                || connector.serverID.lowercased().contains("github")
            let connectorTitle = isGitHubMCP ? "GitHub MCP Connector" : "\(connector.displayName) MCP Connector"
            items.append(Item(
                id: "connector-\(connector.id)", title: connectorTitle, detail: detail,
                nextStep: state == .connected ? nil : "Open Connectors and reconnect this service.",
                state: state == .connected ? .good : (state == .connecting ? .warning : .failed),
                action: state == .connected ? nil : .connector(connector.id)
            ))
        }
        if app.connectors.connected.isEmpty {
            items.append(Item(id: "connectors", title: "Connectors", detail: "None configured.", state: .good))
        }

        if app.settings.chatComputerOff {
            items.append(Item(id: "computer", title: "Chat computer", detail: "Turned off.", nextStep: "Turn it on in Settings if chats need commands.", state: .warning, action: .computer))
        } else if let control = app.connectors.computerControl() {
            // A real command on the real machine, not just "the connector is signed in".
            do {
                switch try await control.ensureMachine(allowCreate: true) {
                case .healthy(let output):
                    switch ComputerControl.toolState(output) {
                    case .ready, .installing:
                        items.append(computerItem(for: control.machine, output: output))
                    case .missing:
                        // Nothing to tap: the checked tool setup starts by itself.
                        let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                        do {
                            _ = try await control.startVerifiedSetup(revision: revision)
                            toolsInstalling = true
                            app.connectors.keepComputerAwakeDuringSetup(resetReadyCache: true)
                            items.append(Item(id: "computer", title: "Chat computer", detail: "\(control.machine) runs commands. MAIPA-G started installing its developer tools in the background (about 15 to 30 minutes the first time).", state: .good))
                        } catch {
                            toolsInstalling = false
                            items.append(Item(id: "computer", title: "Chat computer", detail: "\(control.machine) runs commands, but installing its tools didn't start: \(ErrorExplainer.explain(error).message)", nextStep: "Try again.", state: .warning, action: .setupTools))
                        }
                    }
                case .recreated(let output):
                    let revision = Bundle.main.object(forInfoDictionaryKey: "MAIPAGReviewedRevision") as? String ?? ""
                    if let _ = try? await control.startVerifiedSetup(revision: revision) {
                        toolsInstalling = true
                        app.connectors.keepComputerAwakeDuringSetup(resetReadyCache: true)
                    }
                    items.append(Item(id: "computer", title: "Chat computer", detail: "\(control.machine) was missing, so MAIPA-G created it again. It ran a command: \(Self.firstLine(output, skipping: "maipa-g-health-ok"))", state: .good))
                }
            } catch {
                let broken = Self.isBrokenMachine(error)
                items.append(Item(
                    id: "computer", title: "Chat computer", detail: ErrorExplainer.explain(error).message,
                    nextStep: broken ? "Replace the machine, or open its connector to check the service." : "Open the computer service's connector and reconnect it.",
                    state: .failed, action: broken ? .replaceComputer : .computer
                ))
            }
        } else {
            items.append(Item(id: "computer", title: "Chat computer", detail: "No selected computer connector is connected.", nextStep: "Connect the selected computer service.", state: .failed, action: .computer))
        }

        await app.jobs.refresh()
        var actionsError = app.jobs.lastError
        var probed: [String] = []
        if actionsError == nil, let github = app.github.client {
            // With no jobs yet, Actions is still checked against the data repo or the open repo.
            var repos = Array(Set(app.jobs.jobs.compactMap(\.targetRepo))).sorted { $0.fullName < $1.fullName }
            if repos.isEmpty { repos = [app.sync.repo, app.repo(for: .home)?.ref].compactMap { $0 } }
            for repo in repos.prefix(5) {
                do { _ = try await github.workflowRuns(repo, limit: 1); probed.append(repo.fullName) }
                catch { actionsError = ErrorExplainer.explain(error).message; break }
            }
            if repos.isEmpty, actionsError == nil {
                actionsError = "There is no repo to check Actions against yet."
            }
        } else if actionsError == nil {
            actionsError = "GitHub isn't connected, so Actions can't be checked."
        }
        items.append(Item(
            id: "actions", title: "GitHub Actions",
            detail: actionsError ?? "Actions answered for \(probed.joined(separator: ", ")) and job status refreshed.",
            nextStep: actionsError == nil ? nil : "Open Jobs, fix the shown GitHub error, and retry.",
            state: actionsError == nil ? .good : .failed,
            action: actionsError == nil ? nil : .jobs
        ))
        running = false
    }

    private func fix(_ action: Item.Action) {
        switch action {
        case .github: app.sheet = .connectGitHub
        case .openRouter: app.sheet = .signInOpenRouter
        case .save: Task { await app.sync.syncNow(); await run() }
        case .connector(let id): app.sheet = .connectorDetail(id)
        case .computer: app.sheet = .connectors
        case .replaceComputer: confirmReplace = true
        case .setupTools: Task { await setupTools() }
        case .jobs: app.jobs.show()
        }
    }

    private static func label(for action: Item.Action) -> String {
        switch action {
        case .setupTools: "Set up tools"
        case .replaceComputer: "Replace machine"
        default: "Fix"
        }
    }

    static func isBrokenMachine(_ error: Error) -> Bool {
        guard let failure = error as? ComputerControl.Failure, case .machineUnavailable = failure else { return false }
        return true
    }

    static func firstLine(_ text: String, skipping marker: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && $0 != marker }
        return String((line ?? "ok").prefix(120))
    }

    private func icon(_ state: Item.State) -> String {
        switch state { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.circle.fill"; case .failed: "xmark.circle.fill" }
    }

    private func color(_ state: Item.State) -> Color {
        switch state { case .good: .green; case .warning: .orange; case .failed: Theme.danger }
    }
}
