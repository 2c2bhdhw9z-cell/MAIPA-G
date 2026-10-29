import AgentCore
import SwiftUI
import UIKit

/// Connectors shown like integrations in an ordinary app: familiar services, plain descriptions,
/// recognisable coloured icons and one Connect button. "All" still exposes every result from the
/// official MCP Registry instead of replacing the open ecosystem with a hard-coded list.
struct ConnectorsScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case mine = "My apps"
        case discover = "Discover"
        case all = "All"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .discover
    @State private var showCustom = false
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
                case .discover: popularApps
                case .all: allRegistry
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $connectors.query, prompt: "Search integrations")
            .onSubmit(of: .search) {
                tab = .all
                Task { await connectors.search() }
            }
            .refreshable { await connectors.search() }
            .navigationTitle("Connectors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showCustom = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a custom connector")
                }
            }
            .sheet(isPresented: $showCustom) { CustomConnectorSheet() }
            .task { if connectors.catalog.isEmpty { await connectors.search() } }
        }
    }

    @ViewBuilder
    private var myApps: some View {
        Section("Connected apps") {
            if app.connectors.connected.isEmpty {
                Text("Nothing connected yet.")
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
        Section("Suggested") {
            ForEach(IntegrationService.popular.prefix(6)) { service in
                suggestedCard(service)
            }
        }
    }

    @ViewBuilder
    private var popularApps: some View {
        Section {
            ForEach(filteredPopular) { service in suggestedCard(service) }
        } header: {
            Text("Popular")
        } footer: {
            Text("Connectors come from the official MCP Registry. MAIPA-G shows the sign-in and permissions before an app is connected.")
        }
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
            Text("All integrations")
        } footer: {
            Text("Every result here comes from the official MCP Registry. Some run on your iPhone; others run only during Autonomous jobs.")
        }
    }

    private var filteredPopular: [IntegrationService] {
        let query = app.connectors.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return IntegrationService.popular }
        return IntegrationService.popular.filter { Self.text($0.name, matches: query) || Self.text($0.detail, matches: query) }
    }

    private var filteredCatalog: [RegistryServer] {
        let catalog = app.connectors.catalog
        let query = app.connectors.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            // Familiar apps first, then the rest of the Registry in its usual order.
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

    /// Substring match as typed, or once case, spaces and punctuation are ignored on both sides,
    /// so "Hugging Face" finds "huggingface" and "co.huggingface/hf-mcp-server".
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
        let connected = connectedService(service)
        Button {
            if let connected { app.sheet = .connectorDetail(connected.id) }
            else { findAndConnect(service) }
        } label: {
            ConnectorCard(
                service: service,
                name: service.name,
                detail: service.detail,
                trailing: connected != nil ? .connected : (connecting == service.id ? .working : .connect)
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

    private func findAndConnect(_ service: IntegrationService) {
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
        case .connected: return "Connected · \(app.connectors.toolDefinitions[item.id]?.count ?? 0) tools ready"
        case .connecting: return "Connecting…"
        case .authorizationNeeded: return "Sign in needed"
        case .failed: return "Needs attention"
        case .disconnected: return item.kind == .stdio ? "Ready for Autonomous" : "Disconnected"
        }
    }

    private func plainDescription(_ server: RegistryServer) -> String {
        let text = server.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if server.supportsPhone && server.supportsAutonomous { return "Use this app on your iPhone and in Autonomous jobs." }
        if server.supportsPhone { return "Use this app in your chats on this iPhone." }
        return "Use this app in Autonomous jobs."
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
    var id: String { name }
    let name: String
    let detail: String
    let search: String
    let aliases: [String]
    let symbol: String
    let colour: Color
    let assetName: String?

    init(name: String, detail: String, search: String, aliases: [String], symbol: String, colour: Color, assetName: String? = nil) {
        self.name = name; self.detail = detail; self.search = search; self.aliases = aliases
        self.symbol = symbol; self.colour = colour; self.assetName = assetName
    }

    func matches(_ text: String) -> Bool {
        let value = " " + Self.normalized(text) + " "
        return aliases.contains { value.contains(" " + Self.normalized($0) + " ") }
    }

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ").joined(separator: " "))
    }

    static func matching(_ text: String) -> IntegrationService {
        popular.first(where: { $0.matches(text) })
            ?? IntegrationService(name: text, detail: "Connected tool", search: text, aliases: [], symbol: "puzzlepiece.extension.fill", colour: colour(for: text))
    }

    private static func colour(for text: String) -> Color {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        let choices: [Color] = [.mint, .cyan, .blue, .indigo, .purple, .pink, .orange, .green]
        return choices[Int(value % UInt64(choices.count))]
    }

    static let popular: [IntegrationService] = [
        .init(name: "GitHub", detail: "Search repositories, manage issues and review changes", search: "github", aliases: ["github"], symbol: "chevron.left.forwardslash.chevron.right", colour: .primary, assetName: "IntegrationGitHub"),
        .init(name: "Gmail", detail: "Read, search and draft email", search: "gmail", aliases: ["gmail", "google mail"], symbol: "envelope.fill", colour: .red, assetName: "IntegrationGmail"),
        .init(name: "Google Calendar", detail: "Read and manage your calendar events", search: "calendar", aliases: ["google calendar", "gcalendar", "google agenda"], symbol: "calendar", colour: .blue, assetName: "IntegrationGoogleCalendar"),
        .init(name: "Google Drive", detail: "Search, read and upload your files", search: "drive", aliases: ["google drive", "gdrive"], symbol: "externaldrive.fill", colour: .green, assetName: "IntegrationGoogleDrive"),
        .init(name: "Google Docs", detail: "Read, edit and create documents", search: "docs", aliases: ["google docs", "gdocs"], symbol: "doc.text.fill", colour: .blue, assetName: "IntegrationGoogleDocs"),
        .init(name: "Google Sheets", detail: "Read, analyse and update spreadsheets", search: "sheets", aliases: ["google sheets", "gsheets"], symbol: "tablecells.fill", colour: .green, assetName: "IntegrationGoogleSheets"),
        .init(name: "Google Slides", detail: "Read and create presentations", search: "slides", aliases: ["google slides", "gslides"], symbol: "rectangle.on.rectangle.angled", colour: .orange, assetName: "IntegrationGoogleSlides"),
        .init(name: "Microsoft 365", detail: "Use Outlook, OneDrive, Teams and SharePoint", search: "microsoft", aliases: ["microsoft 365", "office 365", "m365", "m365 copilot"], symbol: "square.grid.2x2.fill", colour: .blue, assetName: "IntegrationMicrosoft"),
        .init(name: "Slack", detail: "Search channels and send messages", search: "slack", aliases: ["slack"], symbol: "number", colour: .purple, assetName: "IntegrationSlack"),
        .init(name: "Notion", detail: "Search, read and update your workspace", search: "notion", aliases: ["notion"], symbol: "doc.text", colour: .primary, assetName: "IntegrationNotion"),
        .init(name: "Linear", detail: "Search and manage issues and projects", search: "linear", aliases: ["linear"], symbol: "circle.lefthalf.filled", colour: .indigo, assetName: "IntegrationLinear"),
        .init(name: "Hugging Face", detail: "Search models, datasets and Spaces", search: "huggingface", aliases: ["hugging face", "huggingface", "hf mcp server"], symbol: "face.smiling", colour: .yellow, assetName: "IntegrationHuggingFace"),
        .init(name: "Figma", detail: "Read designs, comments and project details", search: "figma", aliases: ["figma"], symbol: "paintbrush.pointed.fill", colour: .pink, assetName: "IntegrationFigma"),
        .init(name: "Dropbox", detail: "Search, read and manage cloud files", search: "dropbox", aliases: ["dropbox"], symbol: "shippingbox.fill", colour: .blue, assetName: "IntegrationDropbox"),
        .init(name: "Atlassian", detail: "Use Jira and Confluence projects", search: "atlassian", aliases: ["atlassian", "jira", "confluence"], symbol: "triangle.fill", colour: .blue, assetName: "IntegrationAtlassian"),
        .init(name: "Box", detail: "Search and work with company files", search: "box", aliases: ["box", "box mcp"], symbol: "archivebox.fill", colour: .blue, assetName: "IntegrationBox"),
        .init(name: "Asana", detail: "Read and manage tasks and projects", search: "asana", aliases: ["asana"], symbol: "circle.grid.3x3.fill", colour: .pink, assetName: "IntegrationAsana"),
        .init(name: "Canva", detail: "Search and work with Canva designs", search: "canva", aliases: ["canva"], symbol: "wand.and.stars", colour: .cyan, assetName: "IntegrationCanva"),
        .init(name: "YouTube", detail: "Search videos and work with channel information", search: "youtube", aliases: ["youtube"], symbol: "play.rectangle.fill", colour: .red, assetName: "IntegrationYouTube"),
    ]
}

private extension View {
    func connectorRow() -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
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
                TextField("https://example.com/mcp", text: $url)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Text("Use the secure MCP web address the app gives you.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Custom connector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do { try await app.connectors.addCustom(name: name, urlText: url); dismiss() }
                            catch { self.error = "That secure connector address didn't work." }
                        }
                    }
                }
            }
        }
    }
}
