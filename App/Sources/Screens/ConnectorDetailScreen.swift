import AgentCore
import SwiftUI

struct ConnectorDetailScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let connectorID: UUID?
    let serverID: String?
    @State private var showingDelete = false

    var body: some View {
        NavigationStack {
            List {
                if let connector {
                    Section {
                        LabeledContent("Runs on", value: connector.kind == .remote ? "iPhone" : "Autonomous")
                        if let endpoint = connector.endpoint { LabeledContent("Server", value: endpoint.host ?? endpoint.absoluteString) }
                        LabeledContent("Status", value: stateText)
                    }
                    if let error = app.connectors.errors[connector.id] { Section("What happened") { Text(error).foregroundStyle(Theme.danger) } }
                    if let tools = app.connectors.toolDefinitions[connector.id], !tools.isEmpty {
                        Section("Tools") { ForEach(tools) { tool in VStack(alignment: .leading) { Text(tool.title); Text(tool.description).font(.caption).foregroundStyle(.secondary) } } }
                    }
                    Section {
                        if app.connectors.states[connector.id] != .connected, connector.kind == .remote {
                            Button("Sign in and connect") { Task { await app.connectors.authorize(connector) } }.buttonStyle(.borderedProminent)
                            Button("Use dynamic registration") { Task { await app.connectors.authorize(connector, dynamicRegistration: true) } }
                        }
                        if app.connectors.states[connector.id] == .connected { Button("Reauthorize permissions") { Task { await app.connectors.reauthorize(connector, scopes: connector.scopes) } } }
                        Button("Disconnect") { Task { await app.connectors.disconnect(connector) } }
                        Button("Remove connector", role: .destructive) { showingDelete = true }
                    }
                } else if let server {
                    Section { Text(server.description); LabeledContent("Version", value: server.version); LabeledContent("Phone", value: server.supportsPhone ? "Yes" : "No"); LabeledContent("Autonomous", value: server.supportsAutonomous ? "Yes" : "No") }
                    Section {
                        if server.supportsPhone { Button("Add to iPhone") { Task { await app.connectors.add(server); moveToSaved(server) } }.buttonStyle(.borderedProminent) }
                        if server.supportsAutonomous { Button("Add for Autonomous") { Task { await app.connectors.add(server, preferPhone: false); moveToSaved(server) } } }
                    }
                } else { ContentUnavailableView("Connector not found", systemImage: "puzzlepiece.extension") }
            }
            .navigationTitle(connector?.displayName ?? server?.displayName ?? "Connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove this connector?", isPresented: $showingDelete) { if let connector { Button("Remove", role: .destructive) { Task { await app.connectors.remove(connector); dismiss() } } } }
        }
    }

    private var connector: ConnectorConfiguration? { connectorID.flatMap { id in app.connectors.connected.first { $0.id == id } } }
    private var server: RegistryServer? { serverID.flatMap { id in app.connectors.catalog.first { $0.name == id } } }
    private var stateText: String { String(describing: connector.flatMap { app.connectors.states[$0.id] } ?? .disconnected).replacingOccurrences(of: "authorizationNeeded", with: "Sign in needed") }
    private func moveToSaved(_ server: RegistryServer) { if let item = app.connectors.connected.last { app.sheet = .connectorDetail(item.id) } }
}
