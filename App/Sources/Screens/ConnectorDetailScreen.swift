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
    @State private var apiSecret = ""
    @State private var extraFieldValue = ""
    @State private var customHeaderName = ""
    @State private var savedConfirmation = false

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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(connector?.displayName ?? server?.displayName ?? "Connector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("Remove this connector?", isPresented: $showingDelete) {
                if let connector {
                    Button("Remove", role: .destructive) { Task { await app.connectors.remove(connector); dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                if let connector {
                    extraFieldValue = connector.launchValues["extra_value"] ?? ""
                    customHeaderName = connector.authHeaderName ?? ""
                    launchValues = connector.launchValues
                }
            }
        }
    }

    @ViewBuilder
    private func savedSections(_ connector: ConnectorConfiguration) -> some View {
        let providerSpec = IntegrationCatalog.byServerID(connector.serverID) ?? IntegrationCatalog.matching(connector.displayName)
        Section {
            HStack(spacing: 12) {
                IntegrationIcon(
                    service: IntegrationService.forConnector(connector),
                    name: connector.displayName,
                    remoteURL: app.connectors.catalog.first(where: { $0.name == connector.serverID })?.preferredIconURL
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(connector.displayName).font(.headline)
                    Text(stateText(for: connector)).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            }
            if let note = platformNote(for: providerSpec) {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }

        if let error = app.connectors.errors[connector.id] {
            Section("What happened") { Text(error).foregroundStyle(Theme.danger) }
        }

        // Credentials / Sign-In Section tailored to the connector's engine
        credentialsSection(connector: connector, spec: providerSpec)

        if let tools = app.connectors.toolDefinitions[connector.id], !tools.isEmpty {
            Section("Tools (\(tools.count))") {
                ForEach(tools) { tool in ConnectorToolRow(tool: tool, connector: connector) }
            }
        }

        Section {
            if connector.kind == .remote {
                if app.connectors.states[connector.id] == .connected {
                    Button("Reauthorize OAuth permissions") { Task { await app.connectors.reauthorize(connector, scopes: connector.scopes) } }
                }
                Button("Retry connection") { Task { await app.connectors.recheck(connector) } }
            } else if connector.kind == .apple {
                Button("Request iOS permission again") { Task { await app.connectors.authorize(connector) } }
            }
            Button("Disconnect") { Task { await app.connectors.disconnect(connector) } }
            Button("Remove connector", role: .destructive) { showingDelete = true }
        }

        Section {
            DisclosureGroup("Technical details") {
                LabeledContent("Runs on", value: runsOnDescription(connector))
                if let endpoint = connector.endpoint { LabeledContent("Endpoint", value: endpoint.host ?? endpoint.absoluteString) }
                if let pkg = connector.package { LabeledContent("Package", value: "\(pkg.registryType): \(pkg.identifier)") }
            }
        }
    }

    @ViewBuilder
    private func credentialsSection(connector: ConnectorConfiguration, spec: IntegrationProviderSpec?) -> some View {
        switch connector.kind {
        case .remote:
            Section {
                if app.connectors.states[connector.id] != .connected {
                    Button("Sign in with OAuth") { Task { await app.connectors.authorize(connector) } }
                        .buttonStyle(.borderedProminent)
                    Button("Use OAuth dynamic registration") { Task { await app.connectors.authorize(connector, dynamicRegistration: true) } }
                }
                SecureField("Or paste Bearer token / API key", text: $apiSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Header name (default: Authorization)", text: $customHeaderName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Save token & connect") {
                        Task {
                            await app.connectors.saveRemoteToken(apiSecret, headerName: customHeaderName, for: connector)
                            apiSecret = ""
                            savedConfirmation = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Sign in or API token")
            } footer: {
                Text(setupHint(for: spec) ?? "Sign in with OAuth or paste a Personal Access Token / API key stored only in Keychain.")
            }

        case .builtin:
            if spec?.id == "github" || connector.launchValues["provider"] == "github" {
                Section {
                    if app.github.isConnected {
                        Label(
                            "Connected with your signed-in GitHub account\(app.github.login.map { " (@\($0))" } ?? "")",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.green)

                        if app.connectors.hasStoredBuiltinSecret(connector) {
                            Label("Custom Personal Access Token override active", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                            Button("Use signed-in GitHub account instead") {
                                Task {
                                    await app.connectors.clearBuiltinSecret(for: connector)
                                    savedConfirmation = true
                                }
                            }
                        } else if app.connectors.states[connector.id] != .connected {
                            Button("Activate with signed-in GitHub account") {
                                Task { await app.connectors.recheck(connector) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button("Connect GitHub account") {
                            Task {
                                await app.github.connect()
                                await app.connectors.recheck(connector)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    SecureField("Optional: GitHub Personal Access Token (ghp_...)", text: $apiSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Save Personal Access Token") {
                            Task {
                                await app.connectors.saveBuiltinCredentials(
                                    secret: apiSecret,
                                    extraKey: nil,
                                    extraValue: nil,
                                    for: connector
                                )
                                apiSecret = ""
                                savedConfirmation = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("GitHub Connection")
                } footer: {
                    Text("Uses your signed-in GitHub account automatically on api.github.com, or an optional Personal Access Token stored only in Keychain.")
                }
            } else if connector.secretNames.contains("api_key") || (spec != nil && hasOptionalBuiltinKey(spec!)) {
                let extraMeta = extraFieldMeta(for: spec)
                Section {
                    if app.connectors.hasStoredBuiltinSecret(connector) {
                        Label("API key saved securely in Keychain", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    SecureField(secretPlaceholder(for: spec), text: $apiSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let extraMeta {
                        TextField(extraMeta.label, text: $extraFieldValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Button(savedConfirmation ? "Saved" : "Save credentials") {
                        Task {
                            await app.connectors.saveBuiltinCredentials(
                                secret: apiSecret,
                                extraKey: extraMeta?.key ?? connector.launchValues["extra_key"],
                                extraValue: extraFieldValue,
                                for: connector
                            )
                            apiSecret = ""
                            savedConfirmation = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && extraFieldValue == (connector.launchValues["extra_value"] ?? ""))
                } header: {
                    Text("Credentials (Keychain)")
                } footer: {
                    Text(setupHint(for: spec) ?? "Stored in this iPhone's Keychain only and sent exclusively to this service's HTTPS endpoint.")
                }
            }

        case .stdio:
            if let package = connector.package, !package.launchInputs.isEmpty {
                Section {
                    ForEach(package.launchInputs) { input in
                        if input.isSecret {
                            HStack {
                                SecureField(input.name, text: stdioBinding(input.name, secret: true))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                if app.connectors.hasStoredStdioSecret(connector, name: input.name) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        } else {
                            TextField(input.name, text: stdioBinding(input.name, secret: false))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    Button("Save setup") {
                        Task {
                            await app.connectors.saveStdioInputs(launchValues: launchValues, secretValues: secretValues, for: connector)
                            secretValues.removeAll()
                            savedConfirmation = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("Environment variables")
                } footer: {
                    Text(setupHint(for: spec) ?? "Secrets stay in Keychain and are passed securely when running on your connected Linux computer (`mcp-maipa-g`) or Autonomous jobs.")
                }
            }

        case .webhook:
            Section {
                SecureField("Update secret header value (optional)", text: $apiSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !apiSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Update webhook secret") {
                        Task {
                            await app.connectors.saveBuiltinCredentials(secret: apiSecret, extraKey: nil, extraValue: nil, for: connector)
                            apiSecret = ""
                        }
                    }
                }
            } header: {
                Text("Webhook security")
            }

        case .apple:
            EmptyView()
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
            if server.supportsPhone { Label("Works directly on this iPhone", systemImage: "iphone") }
            if server.supportsAutonomous { Label("Works on your connected Linux computer & Autonomous", systemImage: "terminal") }
        }
        if let package = autonomousPackage, !package.launchInputs.isEmpty {
            Section {
                ForEach(package.launchInputs) { input in launchInputField(input) }
            } header: {
                Text("Setup")
            } footer: {
                Text("Secret values stay in this iPhone's Keychain.")
            }
        }
        Section {
            if server.supportsPhone {
                Button("Connect on iPhone") { Task { await connectOnPhone(server) } }
                    .buttonStyle(.borderedProminent)
            }
            if server.supportsAutonomous {
                Button("Connect package") {
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
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            TextField(input.name, text: valueBinding(input.name, secret: false))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
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
        } ?? true
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

    private func stdioBinding(_ name: String, secret: Bool) -> Binding<String> {
        Binding(
            get: { secret ? (secretValues[name] ?? "") : (launchValues[name] ?? "") },
            set: { if secret { secretValues[name] = $0 } else { launchValues[name] = $0 } }
        )
    }

    private func stateText(for item: ConnectorConfiguration) -> String {
        switch app.connectors.states[item.id] ?? .disconnected {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .authorizationNeeded: return "Sign in or API key needed"
        case .failed: return "Connection error"
        case .disconnected: return "Disconnected"
        }
    }

    private func runsOnDescription(_ item: ConnectorConfiguration) -> String {
        switch item.kind {
        case .remote, .builtin, .webhook, .apple: return "This iPhone"
        case .stdio: return "Connected Linux computer & Autonomous"
        }
    }

    private func platformNote(for spec: IntegrationProviderSpec?) -> String? {
        guard case .appleNative(_, let note) = spec?.mode else { return nil }
        return note
    }

    private func setupHint(for spec: IntegrationProviderSpec?) -> String? {
        switch spec?.mode {
        case .remoteMCP(_, _, _, let hint): return hint
        case .apiKeyREST(_, _, _, _, _, _, _, let hint): return hint
        case .stdioPackage(_, _, _, _, let hint): return hint
        default: return nil
        }
    }

    private func secretPlaceholder(for spec: IntegrationProviderSpec?) -> String {
        if case .apiKeyREST(_, _, _, _, let label, _, _, _) = spec?.mode { return label }
        return "API key or access token"
    }

    private func extraFieldMeta(for spec: IntegrationProviderSpec?) -> (key: String, label: String)? {
        if case .apiKeyREST(_, _, _, _, _, let key?, let label?, _) = spec?.mode { return (key, label) }
        return nil
    }

    private func hasOptionalBuiltinKey(_ spec: IntegrationProviderSpec) -> Bool {
        spec.id == "jina_reader"
    }

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
