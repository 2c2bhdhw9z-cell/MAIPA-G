import AgentCore
import SwiftUI

struct ConnectorsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showCustom = false

    var body: some View {
        @Bindable var connectors = app.connectors
        NavigationStack {
            List {
                if !connectors.connected.isEmpty {
                    Section("Connected") {
                        ForEach(connectors.connected) { connector in
                            Button { app.sheet = .connectorDetail(connector.id) } label: {
                                HStack {
                                    VStack(alignment: .leading) { Text(connector.displayName); Text(status(connector)).font(.caption).foregroundStyle(.secondary) }
                                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section("Official Registry") {
                    ForEach(connectors.catalog) { server in
                        Button { app.sheet = .connectorCatalogDetail(server.name) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(server.displayName).font(.body.weight(.semibold)); Spacer(); if server.supportsPhone { Image(systemName: "iphone") }; if server.supportsAutonomous { Image(systemName: "gearshape.2") } }
                                Text(server.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                    if connectors.isLoading { HStack { ProgressView(); Text("Searching the official Registry…") } }
                    if connectors.nextCursor != nil { Button("Load more") { Task { await connectors.search(reset: false) } } }
                }
            }
            .searchable(text: $connectors.query, prompt: "Search all connectors")
            .onSubmit(of: .search) { Task { await connectors.search() } }
            .refreshable { await connectors.search() }
            .navigationTitle("Connectors")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { showCustom = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $showCustom) { CustomConnectorSheet() }
            .task { if connectors.catalog.isEmpty { await connectors.search() } }
        }
    }

    private func status(_ item: ConnectorConfiguration) -> String {
        switch app.connectors.states[item.id] ?? .disconnected {
        case .connected: return "\(app.connectors.toolDefinitions[item.id]?.count ?? 0) tools ready"
        case .connecting: return "Connecting…"
        case .authorizationNeeded: return "Sign in needed"
        case .failed: return "Needs attention"
        case .disconnected: return item.kind == .stdio ? "Autonomous only" : "Disconnected"
        }
    }
}

private struct CustomConnectorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("https://example.com/mcp", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }.navigationTitle("Custom connector").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { Task { do { try await app.connectors.addCustom(name: name, urlText: url); dismiss() } catch { self.error = String(describing: error) } } } }
            }
        }
    }
}
