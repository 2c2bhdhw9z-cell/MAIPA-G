import AgentCore
import SwiftUI

struct HealthCheckScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var running = false
    @State private var confirmReplace = false

    private struct Item: Identifiable {
        enum State { case good, warning, failed }
        enum Action { case github, openRouter, save, connector(UUID), computer, replaceComputer, jobs }
        let id: String
        var title: String
        var detail: String
        var nextStep: String?
        var state: State
        var action: Action? = nil
    }

    var body: some View {
        NavigationStack {
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
                                Button("Fix") { fix(action) }.font(.footnote.weight(.semibold))
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await run() }
            .confirmationDialog("Replace the chat computer?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace \(app.settings.chatComputerMachineName)", role: .destructive) {
                    Task { await replaceComputer() }
                }
            } message: {
                Text("MAIPA-G deletes the machine that isn't answering and creates a new one with the same name. Files on it are lost; your repos on GitHub and the phone's staged changes are not.")
            }
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
            items.append(Item(id: "github", title: "GitHub", detail: "Connected as \(app.github.login ?? "your account").", state: .good))
        } else {
            items.append(Item(id: "github", title: "GitHub", detail: app.github.reposError ?? "Not connected.", nextStep: "Connect or sign in again in Settings.", state: .failed, action: .github))
        }

        await app.openRouter.refreshKeyInfo()
        if app.openRouter.isSignedIn, app.openRouter.keyInfo != nil {
            let balance = app.openRouter.balance.map { " Balance \($0.dollars)." } ?? ""
            items.append(Item(id: "openrouter", title: "OpenRouter", detail: "Signed in.\(balance)", state: .good))
        } else {
            items.append(Item(id: "openrouter", title: "OpenRouter", detail: app.openRouter.lastError ?? "Not signed in.", nextStep: "Sign in to OpenRouter in Settings.", state: .failed, action: .openRouter))
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
            items.append(Item(
                id: "connector-\(connector.id)", title: connector.displayName, detail: detail,
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
                    items.append(Item(id: "computer", title: "Chat computer", detail: "\(control.machine) ran a command: \(Self.firstLine(output, skipping: "maipa-g-health-ok"))", state: .good))
                case .recreated(let output):
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
        case .jobs: app.jobs.show()
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
