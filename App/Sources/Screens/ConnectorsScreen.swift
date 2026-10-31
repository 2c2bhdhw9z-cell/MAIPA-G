import AgentCore
import SwiftUI
import UIKit

/// Connectors screen covering 100+ curated integrations (Apple iPhone apps, official hosted MCP
/// servers, zero-key public research sources, Keychain API-key services, Custom Webhooks, Custom
/// MCP, and Linux-computer stdio packages) plus the live open MCP Registry in "All".
struct ConnectorsScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case mine = "My apps"
        case discover = "Discover"
        case all = "All"
        var id: String { rawValue }
    }

    enum DiscoverFilter: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case allCurated = "All 107"
        case apple = "Apple"
        case devCloud = "Dev & Cloud"
        case dataStorage = "Data & Files"
        case workDocs = "Work & Docs"
        case chatMeetings = "Chat & Meet"
        case searchMedia = "Search & Media"
        case businessAuto = "Business & Auto"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var tab: Tab = .discover
    @State private var filter: DiscoverFilter = .popular
    @State private var customSheetMode: CustomConnectorMode?
    @State private var connecting: String?
    @State private var notice: String?

    var body: some View {
        @Bindable var connectors = app.connectors
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 4, leading: 18, bottom: 8, trailing: 18))
                    .listRowBackground(Color.clear)
                }

                if let notice {
                    Section { Label(notice, systemImage: "info.circle").foregroundStyle(Theme.secondaryText) }
                }

                switch tab {
                case .mine: myApps
                case .discover: discoverApps
                case .all: allRegistry
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $connectors.query, prompt: "Search 100+ apps & integrations")
            .onSubmit(of: .search) {
                if tab == .all {
                    Task { await connectors.search() }
                }
            }
            .refreshable { await connectors.search() }
            .navigationTitle("Connectors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { customSheetMode = .mcp } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a custom MCP server or webhook")
                }
            }
            .sheet(item: $customSheetMode) { mode in CustomConnectorSheet(initialMode: mode) }
            .task { if connectors.catalog.isEmpty { await connectors.search() } }
        }
    }

    @ViewBuilder
    private var myApps: some View {
        Section("Connected apps (\(app.connectors.connected.count))") {
            if app.connectors.connected.isEmpty {
                Text("Nothing connected yet. Pick an app in Discover to connect in one tap.")
                    .foregroundStyle(Theme.secondaryText)
                    .connectorRow()
            } else {
                ForEach(app.connectors.connected) { connector in
                    Button { app.sheet = .connectorDetail(connector.id) } label: {
                        ConnectorCard(
                            service: IntegrationService.matching(connector.displayName + " " + connector.serverID),
                            name: connector.displayName,
                            detail: connectedStatus(connector),
                            trailing: .chevron,
                            iconURL: app.connectors.catalog.first(where: { $0.name == connector.serverID })?.preferredIconURL
                        )
                    }
                    .buttonStyle(.plain)
                    .connectorRow()
                }
            }
        }
        Section("Quick connect") {
            ForEach(IntegrationService.popular.prefix(8)) { service in
                suggestedCard(service)
            }
        }
    }

    @ViewBuilder
    private var discoverApps: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DiscoverFilter.allCases) { chip in
                        let selected = filter == chip && app.connectors.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button {
                            filter = chip
                            Haptics.selection()
                        } label: {
                            Text(chip.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selected ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(selected ? theme.accent : Theme.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.stroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        Section {
            ForEach(filteredDiscover) { service in
                suggestedCard(service)
            }
        } header: {
            Text(discoverSectionTitle)
        } footer: {
            Text("All API keys and tokens stay exclusively in this iPhone's Keychain. Outside content can never send messages, webhooks, or edits without your confirmation.")
        }
    }

    private var discoverSectionTitle: String {
        let q = app.connectors.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "Matching integrations (\(filteredDiscover.count))" }
        return "\(filter.rawValue) (\(filteredDiscover.count))"
    }

    @ViewBuilder
    private var allRegistry: some View {
        Section {
            ForEach(filteredCatalog) { server in
                Button { connect(server) } label: {
                    ConnectorCard(
                        service: IntegrationService.matching(server.displayName + " " + server.name),
                        name: server.displayName,
                        detail: plainDescription(server),
                        trailing: connectedServer(server) ? .connected : .connect,
                        iconURL: server.preferredIconURL
                    )
                }
                .buttonStyle(.plain)
                .disabled(connecting != nil)
                .connectorRow()
            }
            if app.connectors.isLoading {
                HStack { ProgressView(); Text("Finding integrations…") }.connectorRow()
            }
            if app.connectors.nextCursor != nil {
                Button("Load more") { Task { await app.connectors.search(reset: false) } }
                    .connectorRow()
            }
        } header: {
            Text("Open MCP Registry")
        } footer: {
            Text("Every result here comes live from the official MCP Registry. Remote HTTPS servers run directly on your iPhone; package servers run via your connected Linux computer and Autonomous jobs.")
        }
    }

    private var filteredDiscover: [IntegrationService] {
        let query = app.connectors.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return IntegrationService.all.filter {
                Self.text($0.name, matches: query)
                    || Self.text($0.detail, matches: query)
                    || $0.aliases.contains(where: { Self.text($0, matches: query) })
            }
        }
        switch filter {
        case .popular: return IntegrationService.popular
        case .allCurated: return IntegrationService.all
        case .apple: return IntegrationService.byCategory(.apple)
        case .devCloud: return IntegrationService.byCategory(.devCloud)
        case .dataStorage: return IntegrationService.byCategory(.dataStorage)
        case .workDocs: return IntegrationService.byCategory(.workDocs)
        case .chatMeetings: return IntegrationService.byCategory(.chatMeetings)
        case .searchMedia: return IntegrationService.byCategory(.searchMedia)
        case .businessAuto: return IntegrationService.byCategory(.businessAuto)
        }
    }

    private var filteredCatalog: [RegistryServer] {
        let catalog = app.connectors.catalog
        let query = app.connectors.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            var familiar: [RegistryServer] = []
            var others: [RegistryServer] = []
            for server in catalog {
                if IntegrationService.popular.contains(where: { $0.matches(server.displayName + " " + server.name) }) {
                    familiar.append(server)
                } else {
                    others.append(server)
                }
            }
            return familiar + others
        }
        return catalog.filter {
            Self.text($0.displayName, matches: query)
                || Self.text($0.description, matches: query)
                || Self.text($0.name, matches: query)
        }
    }

    private static func text(_ field: String, matches query: String) -> Bool {
        if field.localizedCaseInsensitiveContains(query) { return true }
        let compactQuery = compacted(query)
        return !compactQuery.isEmpty && compacted(field).contains(compactQuery)
    }

    private static func compacted(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    @ViewBuilder
    private func suggestedCard(_ service: IntegrationService) -> some View {
        let existing = connectedService(service)
        let isReady = existing.map { app.connectors.states[$0.id] == .connected } ?? false
        Button {
            if let existing {
                app.sheet = .connectorDetail(existing.id)
            } else {
                connectCurated(service)
            }
        } label: {
            ConnectorCard(
                service: service,
                name: service.name,
                detail: existing.map(connectedStatus) ?? service.detail,
                trailing: existing != nil ? (isReady ? .connected : .chevron) : (connecting == service.id ? .working : .connect)
            )
        }
        .buttonStyle(.plain)
        .disabled(connecting != nil && connecting != service.id)
        .connectorRow()
    }

    private func connectedService(_ service: IntegrationService) -> ConnectorConfiguration? {
        app.connectors.connected.first { service.matches($0.displayName + " " + $0.serverID) }
    }

    private func connectedServer(_ server: RegistryServer) -> Bool {
        app.connectors.connected.contains { $0.serverID == server.name }
    }

    private func connectCurated(_ service: IntegrationService) {
        if let spec = service.spec {
            switch spec.mode {
            case .customWebhook:
                customSheetMode = .webhook
                return
            case .customMCP:
                customSheetMode = .mcp
                return
            default:
                connecting = service.id
                notice = nil
                Task {
                    let added = await app.connectors.connectCatalogProvider(spec)
                    connecting = nil
                    if let added {
                        // Open setup/detail sheet whenever sign-in or an API key is needed, or let zero-key/Apple show ✓ immediately.
                        if app.connectors.states[added.id] != .connected {
                            app.sheet = .connectorDetail(added.id)
                        } else {
                            Haptics.selection()
                        }
                    }
                }
                return
            }
        }
        // Fallback to live Registry lookup if ever needed.
        connecting = service.id
        notice = nil
        Task {
            do {
                let found = try await app.connectors.lookup(service.search)
                guard let server = found.first(where: { service.matches($0.displayName + " " + $0.name) }) ?? found.first else {
                    notice = "No active \(service.name) connector is listed right now."
                    connecting = nil
                    return
                }
                connect(server)
            } catch {
                notice = "Couldn't reach the connector directory. Try again."
                connecting = nil
            }
        }
    }

    private func connect(_ server: RegistryServer) {
        if let existing = app.connectors.connected.first(where: { $0.serverID == server.name }) {
            connecting = nil
            app.sheet = .connectorDetail(existing.id)
            return
        }
        connecting = server.name
        Task {
            if server.supportsPhone {
                await app.connectors.add(server)
                if let connector = app.connectors.connected.first(where: { $0.serverID == server.name }) {
                    if app.connectors.states[connector.id] == .authorizationNeeded {
                        await app.connectors.authorize(connector)
                    }
                    connecting = nil
                    app.sheet = .connectorDetail(connector.id)
                    return
                }
            }
            connecting = nil
            app.sheet = .connectorCatalogDetail(server.name)
        }
    }

    private func connectedStatus(_ item: ConnectorConfiguration) -> String {
        switch app.connectors.states[item.id] ?? .disconnected {
        case .connected:
            let count = app.connectors.toolDefinitions[item.id]?.count ?? 0
            if item.kind == .stdio {
                return app.connectors.computerConnector() != nil
                    ? "Connected via Linux computer · \(max(count, 1)) tool ready"
                    : "Ready for Linux computer & Autonomous"
            }
            return "Connected · \(count) \(count == 1 ? "tool" : "tools") ready"
        case .connecting: return "Connecting…"
        case .authorizationNeeded: return "Tap to finish sign-in or API key setup"
        case .failed: return "Needs attention · tap to inspect"
        case .disconnected: return item.kind == .stdio ? "Ready for Autonomous" : "Disconnected"
        }
    }

    private func plainDescription(_ server: RegistryServer) -> String {
        let text = server.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if server.supportsPhone && server.supportsAutonomous { return "Use this app on your iPhone and in Autonomous jobs." }
        if server.supportsPhone { return "Use this app in your chats on this iPhone." }
        return "Use this app on your connected Linux computer and in Autonomous jobs."
    }
}

private enum ConnectorTrailing {
    case connect, connected, working, chevron
}

private struct ConnectorCard: View {
    let service: IntegrationService
    let name: String
    let detail: String
    let trailing: ConnectorTrailing
    var iconURL: URL? = nil

    var body: some View {
        HStack(spacing: 12) {
            IntegrationIcon(service: service, name: name, remoteURL: iconURL)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 8)
            switch trailing {
            case .connect:
                Text("Connect").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 7).background(Theme.raised, in: Capsule())
            case .connected:
                Image(systemName: "checkmark").foregroundStyle(.green).fontWeight(.bold)
            case .working:
                ProgressView().controlSize(.small)
            case .chevron:
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        .contentShape(Rectangle())
    }
}

struct IntegrationIcon: View {
    let service: IntegrationService
    var name: String? = nil
    var remoteURL: URL? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised)
            if let assetName = service.assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            } else if let remoteURL {
                RemoteConnectorLogo(url: remoteURL, fallback: initials)
            } else if service.spec != nil {
                Image(systemName: service.symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(service.colour)
            } else {
                Text(initials)
                    .font(.system(size: initials.count > 1 ? 13 : 18, weight: .bold, design: .rounded))
                    .foregroundStyle(service.colour)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = (name ?? service.name).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }
}

private struct RemoteConnectorLogo: View {
    let url: URL
    let fallback: String
    @State private var data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 26, height: 26)
            } else {
                Text(fallback).font(.system(size: fallback.count > 1 ? 13 : 18, weight: .bold, design: .rounded))
                    .padding(8)
            }
        }
        .task(id: url) { data = await ConnectorLogoLoader.shared.data(for: url) }
    }
}

private actor ConnectorLogoLoader {
    static let shared = ConnectorLogoLoader()
    private var cache: [URL: Data] = [:]
    private var order: [URL] = []

    func data(for url: URL) async -> Data? {
        if let cached = cache[url] { return cached }
        guard url.scheme == "https" else { return nil }
        do {
            let response = try await URLSessionTransport().stream(HTTPRequest(url: url, headers: ["Accept": "image/png,image/jpeg,image/webp,*/*;q=0.2"], idleTimeout: 15))
            guard response.isSuccess else { return nil }
            if let length = response.header("content-length").flatMap(Int.init), length > 512_000 { return nil }
            let data = try await response.collect(limit: 512_001)
            guard data.count <= 512_000, Self.looksLikeImage(data) else { return nil }
            if cache.count >= 80, let oldest = order.first {
                cache[oldest] = nil
                order.removeFirst()
            }
            cache[url] = data
            order.append(url)
            return data
        } catch { return nil }
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || (data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.dropFirst(8).prefix(4) == Data("WEBP".utf8))
    }
}

struct IntegrationService: Identifiable {
    var id: String { spec?.id ?? name }
    let name: String
    let detail: String
    let search: String
    let aliases: [String]
    let symbol: String
    let colour: Color
    let assetName: String?
    let spec: IntegrationProviderSpec?

    init(name: String, detail: String, search: String, aliases: [String], symbol: String, colour: Color, assetName: String? = nil, spec: IntegrationProviderSpec? = nil) {
        self.name = name; self.detail = detail; self.search = search; self.aliases = aliases
        self.symbol = symbol; self.colour = colour; self.assetName = assetName; self.spec = spec
    }

    init(spec: IntegrationProviderSpec) {
        self.name = spec.name
        self.detail = spec.detail
        self.search = spec.search
        self.aliases = spec.aliases
        self.symbol = spec.symbol
        self.colour = Self.colour(for: spec)
        self.assetName = spec.assetName
        self.spec = spec
    }

    func matches(_ text: String) -> Bool {
        if let spec { return spec.matches(text) }
        let value = " " + Self.normalized(text) + " "
        return aliases.contains { value.contains(" " + Self.normalized($0) + " ") }
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ").joined(separator: " "))
    }

    static func matching(_ text: String) -> IntegrationService {
        all.first(where: { $0.matches(text) })
            ?? IntegrationService(name: text, detail: "Connected tool", search: text, aliases: [], symbol: "puzzlepiece.extension.fill", colour: colour(forText: text))
    }

    private static func colour(for spec: IntegrationProviderSpec) -> Color {
        switch spec.category {
        case .apple: return .cyan
        case .devCloud: return .indigo
        case .dataStorage: return .green
        case .workDocs: return .blue
        case .chatMeetings: return .purple
        case .searchMedia: return .orange
        case .businessAuto: return .mint
        case .popular: return .blue
        }
    }

    private static func colour(forText text: String) -> Color {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        let choices: [Color] = [.mint, .cyan, .blue, .indigo, .purple, .pink, .orange, .green]
        return choices[Int(value % UInt64(choices.count))]
    }

    static let all: [IntegrationService] = IntegrationCatalog.all.map(IntegrationService.init(spec:))

    static let popular: [IntegrationService] = all.filter { $0.spec?.isPopular == true }

    static func byCategory(_ category: IntegrationCategory) -> [IntegrationService] {
        all.filter { $0.spec?.category == category }
    }
}

private extension View {
    func connectorRow() -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

enum CustomConnectorMode: String, CaseIterable, Identifiable {
    case mcp = "Custom MCP"
    case webhook = "Webhook"
    var id: String { rawValue }
}

private struct CustomConnectorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let initialMode: CustomConnectorMode

    @State private var mode: CustomConnectorMode = .mcp
    @State private var name = ""
    @State private var url = ""
    @State private var method = "POST"
    @State private var headerName = ""
    @State private var secret = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $mode) {
                        ForEach(CustomConnectorMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField(mode == .mcp ? "Server name (e.g. Internal Tools)" : "Webhook name (e.g. Deploy Hook)", text: $name)
                    TextField(mode == .mcp ? "https://example.com/mcp" : "https://hooks.example.com/trigger", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if mode == .webhook {
                        Picker("HTTP Method", selection: $method) {
                            Text("POST").tag("POST")
                            Text("PUT").tag("PUT")
                            Text("GET").tag("GET")
                        }
                    }
                } header: {
                    Text("Endpoint")
                }

                Section {
                    SecureField(mode == .mcp ? "Bearer token / API key (optional)" : "Secret token (optional)", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Custom header name (default: Authorization)", text: $headerName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Authentication (Keychain only)")
                } footer: {
                    Text(mode == .mcp
                        ? "Leave the token blank if this MCP server signs you in with OAuth."
                        : "Secrets stay exclusively in this iPhone's Keychain and are never sent anywhere except this exact HTTPS host.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(mode == .mcp ? "Custom MCP" : "Custom Webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                if mode == .mcp {
                                    try await app.connectors.addCustom(name: name, urlText: url, token: secret, headerName: headerName)
                                } else {
                                    try await app.connectors.addWebhook(name: name, urlText: url, method: method, headerName: headerName, secret: secret)
                                }
                                dismiss()
                            } catch {
                                self.error = "Enter a valid public https:// address."
                            }
                        }
                    }
                }
            }
            .onAppear { mode = initialMode }
        }
    }
}
