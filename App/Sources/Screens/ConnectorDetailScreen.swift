import AgentCore
import SwiftUI

struct ConnectorDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let connectorID: UUID?
    let serverID: String?
    @State private var showingDelete = false
    @State private var launchValues: [String: String] = [:]
    @State private var secretValues: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                if let connector {
                    savedSections(connector)
                } else if let server {
                    registrySections(server)
                } else {
                    ContentUnavailableView("Connector not found", systemImage: "puzzlepiece.extension")
                }
            }
            .navigationTitle(connector?.displayName ?? server?.displayName ?? "Connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove this connector?", isPresented: $showingDelete) { if let connector { Button("Remove", role: .destructive) { Task { await app.connectors.remove(connector); dismiss() } } } }
        }
    }

    // Split into pieces so the compiler can check each one quickly.

    @ViewBuilder
    private func savedSections(_ connector: ConnectorConfiguration) -> some View {
        Section {
            HStack(spacing: 12) {
                IntegrationIcon(
                    service: IntegrationService.matching(connector.displayName + " " + connector.serverID),
                    name: connector.displayName,
                    remoteURL: app.connectors.catalog.first(where: { $0.name == connector.serverID })?.preferredIconURL
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.displayName).font(.headline)
                    Text(stateText).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        if let error = app.connectors.errors[connector.id] {
            Section("What happened") { Text(error).foregroundStyle(Theme.danger) }
        }
        if let tools = app.connectors.toolDefinitions[connector.id], !tools.isEmpty {
            Section("Tools") {
                ForEach(tools) { tool in ConnectorToolRow(tool: tool, connector: connector) }
            }
        }
        Section {
            if app.connectors.states[connector.id] != .connected, connector.kind == .remote {
                Button("Sign in and connect") { Task { await app.connectors.authorize(connector) } }
                    .buttonStyle(.borderedProminent)
                Button("Use dynamic registration") { Task { await app.connectors.authorize(connector, dynamicRegistration: true) } }
            }
            if app.connectors.states[connector.id] == .connected {
                Button("Reauthorize permissions") { Task { await app.connectors.reauthorize(connector, scopes: connector.scopes) } }
            }
            Button("Disconnect") { Task { await app.connectors.disconnect(connector) } }
            Button("Remove connector", role: .destructive) { showingDelete = true }
        }
        Section {
            DisclosureGroup("Technical details") {
                LabeledContent("Runs on", value: connector.kind == .remote ? "This iPhone" : "Autonomous")
                if let endpoint = connector.endpoint { LabeledContent("Server", value: endpoint.host ?? endpoint.absoluteString) }
            }
        }
    }

    @ViewBuilder
    private func registrySections(_ server: RegistryServer) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                IntegrationIcon(
                    service: IntegrationService.matching(server.displayName + " " + server.name),
                    name: server.displayName,
                    remoteURL: server.preferredIconURL
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.displayName).font(.headline)
                    Text(server.description.isEmpty ? "Connect this app to use its tools in MAIPA-G." : server.description)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            if server.supportsPhone { Label("Works in chats on this iPhone", systemImage: "iphone") }
            if server.supportsAutonomous { Label("Works in Autonomous jobs", systemImage: "gearshape.2") }
        }
        if let package = autonomousPackage, !package.launchInputs.isEmpty {
            Section {
                ForEach(package.launchInputs) { input in launchInputField(input) }
            } header: {
                Text("Autonomous setup")
            } footer: {
                Text("Secret values stay in this iPhone's Keychain and are encrypted before GitHub receives them. Other setup values sync with the connector.")
            }
        }
        Section {
            if server.supportsPhone {
                Button("Connect") { Task { await connectOnPhone(server) } }
                    .buttonStyle(.borderedProminent)
            }
            if server.supportsAutonomous {
                Button("Use in Autonomous") {
                    Task { await app.connectors.add(server, preferPhone: false, launchValues: launchValues, secretValues: secretValues); moveToSaved(server) }
                }
                .disabled(!autonomousInputsComplete)
            }
        }
    }

    @ViewBuilder
    private func launchInputField(_ input: RegistryServer.LaunchInput) -> some View {
        if !input.choices.isEmpty {
            Picker(input.name, selection: valueBinding(input.name, secret: input.isSecret)) {
                Text("Choose…").tag("")
                ForEach(input.choices, id: \.self) { Text($0).tag($0) }
            }
        } else if input.isSecret {
            SecureField(input.name, text: valueBinding(input.name, secret: true))
        } else {
            TextField(input.name, text: valueBinding(input.name, secret: false))
        }
        if !input.description.isEmpty {
            Text(input.description).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var connector: ConnectorConfiguration? { connectorID.flatMap { id in app.connectors.connected.first { $0.id == id } } }
    private var server: RegistryServer? { serverID.flatMap { id in app.connectors.catalog.first { $0.name == id } } }
    private var autonomousPackage: RegistryServer.Package? { server?.packages.first(where: \.isAutonomousCompatible) }
    private var autonomousInputsComplete: Bool {
        autonomousPackage?.launchInputs.filter(\.isRequired).allSatisfy { input in
            let value = input.isSecret ? secretValues[input.name] : launchValues[input.name]
            return value?.isEmpty == false || input.defaultValue != nil
        } ?? false
    }
    private func valueBinding(_ name: String, secret: Bool) -> Binding<String> {
        Binding(
            get: {
                let fallback = autonomousPackage?.launchInputs.first { $0.name == name }?.defaultValue ?? ""
                return secret ? secretValues[name] ?? fallback : launchValues[name] ?? fallback
            },
            set: { if secret { secretValues[name] = $0 } else { launchValues[name] = $0 } }
        )
    }
    private var stateText: String { String(describing: connector.flatMap { app.connectors.states[$0.id] } ?? .disconnected).replacingOccurrences(of: "authorizationNeeded", with: "Sign in needed") }
    private func connectOnPhone(_ server: RegistryServer) async {
        await app.connectors.add(server)
        guard let item = app.connectors.connected.first(where: { $0.serverID == server.name }) else { return }
        if app.connectors.states[item.id] == .authorizationNeeded { await app.connectors.authorize(item) }
        app.sheet = .connectorDetail(item.id)
    }
    private func moveToSaved(_ server: RegistryServer) {
        if let item = app.connectors.connected.first(where: { $0.serverID == server.name }) { app.sheet = .connectorDetail(item.id) }
    }
}

/// One tool a connected connector offers: its name and what it does.
private struct ConnectorToolRow: View {
    @Environment(AppModel.self) private var app
    let tool: ConnectorToolDefinition
    let connector: ConnectorConfiguration

    var body: some View {
        Toggle(isOn: Binding(
            get: { !connector.disabledTools.contains(tool.originalName) },
            set: { enabled in Task { await app.connectors.setTool(tool.originalName, enabled: enabled, for: connector) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Controls whether this tool is sent to the AI")
    }
}
