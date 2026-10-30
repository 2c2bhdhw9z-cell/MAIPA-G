import AgentCore
import SwiftUI

struct HealthCheckScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var running = false

    private struct Item: Identifiable {
        enum State { case good, warning, failed }
        let id: String
        var title: String
        var detail: String
        var nextStep: String?
        var state: State
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
        }
    }

    private func run() async {
        guard !running else { return }
        running = true
        items = []

        await app.github.refresh()
        if app.github.isConnected, app.github.reposError == nil {
            items.append(Item(id: "github", title: "GitHub", detail: "Connected as \(app.github.login ?? "your account").", state: .good))
        } else {
            items.append(Item(id: "github", title: "GitHub", detail: app.github.reposError ?? "Not connected.", nextStep: "Connect or sign in again in Settings.", state: .failed))
        }

        await app.openRouter.refreshKeyInfo()
        if app.openRouter.isSignedIn, app.openRouter.keyInfo != nil {
            let balance = app.openRouter.balance.map { " Balance \($0.dollars)." } ?? ""
            items.append(Item(id: "openrouter", title: "OpenRouter", detail: "Signed in.\(balance)", state: .good))
        } else {
            items.append(Item(id: "openrouter", title: "OpenRouter", detail: app.openRouter.lastError ?? "Not signed in.", nextStep: "Sign in to OpenRouter in Settings.", state: .failed))
        }

        await app.sync.syncNow()
        switch app.sync.status {
        case .idle:
            items.append(Item(id: "saving", title: "Saving", detail: app.sync.lastSaved.map { "Saved \($0.friendlyAgo)." } ?? "Ready.", state: .good))
        case .failed(let message):
            items.append(Item(id: "saving", title: "Saving", detail: message, nextStep: "Tap Save now in Settings after fixing the named cause.", state: .failed))
        case .off:
            items.append(Item(id: "saving", title: "Saving", detail: "On this phone only.", nextStep: "Connect GitHub to back up data.", state: .warning))
        case .saving:
            items.append(Item(id: "saving", title: "Saving", detail: "Still saving.", state: .warning))
        }

        for connector in app.connectors.connected {
            let state = app.connectors.states[connector.id] ?? .disconnected
            let detail = app.connectors.errors[connector.id] ?? state.rawValue
            items.append(Item(
                id: "connector-\(connector.id)", title: connector.displayName, detail: detail,
                nextStep: state == .connected ? nil : "Open Connectors and reconnect this service.",
                state: state == .connected ? .good : (state == .connecting ? .warning : .failed)
            ))
        }
        if app.connectors.connected.isEmpty {
            items.append(Item(id: "connectors", title: "Connectors", detail: "None configured.", state: .good))
        }

        if app.settings.chatComputerOff {
            items.append(Item(id: "computer", title: "Chat computer", detail: "Turned off.", nextStep: "Turn it on in Settings if chats need commands.", state: .warning))
        } else {
            let ready = app.connectors.connected.contains { configuration in
                app.connectors.states[configuration.id] == .connected &&
                    (app.settings.chatComputerServer == nil || app.settings.chatComputerServer == configuration.serverID)
            }
            items.append(Item(id: "computer", title: "Chat computer", detail: ready ? "Connector is ready." : "No selected computer connector is connected.", nextStep: ready ? nil : "Connect the selected computer service.", state: ready ? .good : .failed))
        }

        await app.jobs.refresh()
        items.append(Item(
            id: "actions", title: "GitHub Actions",
            detail: app.jobs.lastError ?? "Job status refreshed.",
            nextStep: app.jobs.lastError == nil ? nil : "Open Jobs, fix the shown GitHub error, and retry.",
            state: app.jobs.lastError == nil ? .good : .failed
        ))
        running = false
    }

    private func icon(_ state: Item.State) -> String {
        switch state { case .good: "checkmark.circle.fill"; case .warning: "exclamationmark.circle.fill"; case .failed: "xmark.circle.fill" }
    }

    private func color(_ state: Item.State) -> Color {
        switch state { case .good: .green; case .warning: .orange; case .failed: Theme.danger }
    }
}
