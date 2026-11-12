import AgentCore
import SwiftUI

/// Settings, cleaned right down (owner, 11 November 2026: "I meant actually cleaned the fuck up").
/// Six rows and a switch: Accounts, AI, Computer, Memories, Appearance, Notifications and About.
/// Things the AI decides from what the person says (how changes are saved, workflows, which
/// websites a preview may reach) and machine details are not settings any more.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var confirmDisconnect = false
    @State private var confirmDisconnectGitLab = false
    @State private var gitlabHost = ""
    @State private var gitlabToken = ""
    @State private var copiesSize: Int64?
    @State private var freeSpace: Int64?
    /// The controls edit this copy; every change is saved straight away.
    @State private var draft = AppSettings()
    @State private var loaded = false
    @State private var exportURL: URL?
    @State private var movingExport = false
    @State private var exporting = false
    @State private var exportMessage: String?
    @State private var confirmUnsafeUpdate = false
    @State private var providerConnectSheet: AIProviderConnectSheet?

    var body: some View {
        NavigationStack {
            Form {
                header
                if let newer = app.updates.newerBuildNumber {
                    Section {
                        Button {
                            if app.sync.isEverythingBackedUp { openURL(app.updates.downloadURL) }
                            else { confirmUnsafeUpdate = true }
                        } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(systemImage: "arrow.down.app.fill", tint: theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Build \(newer) is out").font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(app.sync.isEverythingBackedUp
                                         ? "Everything is backed up. Install it over the top."
                                         : "Don’t delete MAIPA-G yet. Some data is not backed up.")
                                        .font(.footnote)
                                        .foregroundStyle(app.sync.isEverythingBackedUp ? Theme.secondaryText : .orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    page("Accounts", icon: "person.crop.circle.fill", tint: Color(white: 0.25), value: accountsSummary) { accounts }
                    page("AI", icon: "sparkles", tint: .purple, value: aiSummary) { aiPage }
                    page("Computer", icon: "desktopcomputer", tint: .blue, value: computerSummary) { computer }
                }

                Section {
                    page("Memories", icon: "brain.head.profile", tint: .pink, value: draft.memoriesOn ? "On" : "Off") { memories }
                    page("Appearance", icon: "paintbrush.fill", tint: .orange, value: draft.appearance.label) { appearance }
                    Toggle(isOn: $draft.notificationsOn) {
                        SettingsRowLabel(title: "Notifications", icon: "bell.badge.fill", tint: .red)
                    }
                }

                Section {
                    page("About", icon: "info.circle.fill", tint: .gray, value: saveStatus, valueTint: app.sync.isEverythingBackedUp ? nil : .orange) {
                        about
                        backup
                        Section {
                            NavigationLink { HealthCheckScreen(embedded: true) } label: {
                                Label("Check everything", systemImage: "checkmark.shield")
                            }
                        }
                        technical
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                if !loaded {
                    draft = app.settings
                    loaded = true
                }
            }
            // The Memories page has the same switch and saves it straight away.
            .onChange(of: app.settings.memoriesOn) { _, value in
                if loaded, draft.memoriesOn != value { draft.memoriesOn = value }
            }
            .onChange(of: draft) { _, edited in
                guard loaded else { return }
                app.updateSettings { settings in
                    settings.appearance = edited.appearance
                    settings.accent = edited.accent
                    settings.effects = edited.effects
                    settings.spendLimitOn = edited.spendLimitOn
                    settings.spendLimit = edited.spendLimit
                    settings.notificationsOn = edited.notificationsOn
                    settings.memoriesOn = edited.memoriesOn
                    settings.chatComputerServer = edited.chatComputerServer
                    settings.chatComputerOff = edited.chatComputerOff
                }
            }
            .task {
                await app.openRouter.refreshKeyInfo()
                await app.github.refreshActionsBilling()
                copiesSize = await app.snapshots.diskUsage()
                freeSpace = try? app.paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            }
        }
        .sheet(item: $providerConnectSheet) { sheet in
            sheet
        }
        .alert("Disconnect GitHub?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await app.disconnectGitHub() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MAIPA-G stops using your repos and stops saving chats to GitHub. Your chats stay on this phone, and the ones already saved stay in MAIPA-G-data.")
        }
        .alert("Disconnect GitLab?", isPresented: $confirmDisconnectGitLab) {
            Button("Disconnect", role: .destructive) { app.disconnectGitLab() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MAIPA-G forgets the GitLab token on this phone and stops using your GitLab projects. Nothing on GitLab changes; you can also revoke the token on GitLab.")
        }
        .alert("Some data is not backed up", isPresented: $confirmUnsafeUpdate) {
            Button("Save now first") { Task { await app.sync.syncNow() } }
            Button("Download anyway", role: .destructive) { openURL(app.updates.downloadURL) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Install the new build over this one. Deleting the app first can lose the files that are still only on this phone.")
        }
        .fileMover(isPresented: $movingExport, file: exportURL) { result in
            switch result {
            case .success: exportMessage = "Exported."
            case .failure(let error): exportMessage = "Export failed: \(error.localizedDescription)"
            }
            exportURL = nil
        }
    }

    // MARK: The main page

    /// The app, the account and whether everything is saved, at the top like an account card.
    private var header: some View {
        Section {
            HStack(spacing: 14) {
                Spark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MAIPA-G").font(.title3.weight(.semibold))
                    Text(app.github.login.map { "\($0) · Build \(app.updates.currentBuild)" } ?? "Build \(app.updates.currentBuild)")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// One row on the main page that opens its own page.
    private func page<Content: View>(_ title: String, icon: String, tint: Color, value: String? = nil, valueTint: Color? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
        } label: {
            SettingsRowLabel(title: title, icon: icon, tint: tint, value: value, valueTint: valueTint)
        }
    }

    private var accountsSummary: String {
        if let login = app.github.login { return login }
        if app.gitlab.isConnected { return "GitLab" }
        return "Not connected"
    }

    private var aiSummary: String {
        guard app.openRouter.isSignedIn else { return "Not connected" }
        let connected = app.openRouter.externalProviders.filter(\.isEnabled).count + (app.openRouter.hasOpenRouterKey ? 1 : 0)
        return connected == 1 ? "1 provider" : "\(connected) providers"
    }

    private var computerSummary: String {
        if draft.chatComputerOff { return "Off" }
        if let server = draft.chatComputerServer, let connector = computerConnectors.first(where: { $0.serverID == server }) {
            return connector.displayName
        }
        return computerConnectors.isEmpty ? "None" : "Automatic"
    }

    // MARK: Accounts

    private var accounts: some View {
        Group {
            Section {
                if app.github.isConnected {
                    HStack(spacing: 12) {
                        Image("IntegrationGitHub").resizable().scaledToFit().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.github.login ?? "GitHub").font(.body.weight(.semibold))
                            if let credentials = app.github.credentials {
                                Text("Changes show up as \(credentials.botName)").font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    if app.github.needsSignInAgain {
                        Button("Sign in to GitHub again") {
                            Task { await app.github.reauthorize() }
                        }
                    }
                    if let url = app.github.installationSettingsURL {
                        Button("Choose which repos MAIPA-G can use") { openURL(url) }
                    }
                    Button("Disconnect GitHub", role: .destructive) { confirmDisconnect = true }
                } else {
                    Button {
                        app.sheet = .connectGitHub
                    } label: {
                        HStack(spacing: 12) {
                            Image("IntegrationGitHub").resizable().scaledToFit().frame(width: 26, height: 26)
                            Text(app.github.phase == .needsInstall ? "Finish connecting GitHub" : "Connect GitHub")
                        }
                    }
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("To change how your work is saved, just tell the AI in a chat (\"no pull requests\", \"use branches\"). A repo's own rules always win.")
            }

            Section {
                if app.gitlab.isConnected {
                    HStack(spacing: 12) {
                        Image("IntegrationGitLab").resizable().scaledToFit().frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.gitlab.login ?? "GitLab").font(.body.weight(.semibold))
                            Text(app.gitlab.host).font(.footnote).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let error = app.gitlab.reposError {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                    Button("Disconnect GitLab", role: .destructive) { confirmDisconnectGitLab = true }
                } else {
                    NavigationLink {
                        Form { gitLabConnect }
                            .navigationTitle("Connect GitLab")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 12) {
                            Image("IntegrationGitLab").resizable().scaledToFit().frame(width: 26, height: 26)
                            Text("Connect GitLab")
                        }
                    }
                }
            } header: {
                Text("GitLab")
            }
        }
    }

    /// gitlab.com or your own server, with a personal access token kept in the Keychain.
    private var gitLabConnect: some View {
        Section {
            TextField("gitlab.com or https://your-server", text: $gitlabHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Personal access token (api scope)", text: $gitlabToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(app.gitlab.isConnecting ? "Connecting…" : "Connect") {
                Task {
                    if await app.gitlab.connect(host: gitlabHost, token: gitlabToken) { gitlabToken = "" }
                }
            }
            .disabled(app.gitlab.isConnecting || gitlabToken.trimmingCharacters(in: .whitespaces).isEmpty)
            if let error = app.gitlab.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
            }
        } footer: {
            Button("Make a token on GitLab") {
                let host = GitLabClient.normalizedHost(gitlabHost) ?? GitLabClient.defaultHost
                if let url = URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=MAIPA-G&scopes=api") { openURL(url) }
            }
            .font(.footnote)
        }
    }

    // MARK: AI

    private var aiPage: some View {
        Group {
            Section {
                if app.openRouter.hasOpenRouterKey {
                    NavigationLink {
                        openRouterPage
                    } label: {
                        providerRow(assetName: "ProviderOpenRouter", name: "OpenRouter", value: app.openRouter.balance?.dollars ?? "Signed in", valueTint: Theme.secondaryText)
                    }
                } else {
                    Button { app.sheet = .signInOpenRouter } label: {
                        providerRow(assetName: "ProviderOpenRouter", name: "OpenRouter", value: "Sign in", valueTint: theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(AIProviderPreset.builtIn) { preset in
                    let saved = app.openRouter.endpoint(for: preset.id)
                    Button {
                        providerConnectSheet = AIProviderConnectSheet(mode: .preset(preset))
                    } label: {
                        providerRow(assetName: preset.assetName, name: preset.name, value: providerValue(saved: saved, id: preset.id), valueTint: providerTint(saved: saved, id: preset.id))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(app.openRouter.externalProviders.filter { AIProviderPreset.matching($0.id) == nil }) { custom in
                    Button {
                        providerConnectSheet = AIProviderConnectSheet(mode: .existing(custom))
                    } label: {
                        providerRow(assetName: nil, name: custom.name, value: providerValue(saved: custom, id: custom.id), valueTint: providerTint(saved: custom, id: custom.id))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    providerConnectSheet = AIProviderConnectSheet(mode: .customNew)
                } label: {
                    Label("Add another provider", systemImage: "plus.circle")
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("Every connected provider's models show together when you pick an AI.")
            }

            Section {
                Toggle("Stop and ask when a reply has cost…", isOn: $draft.spendLimitOn)
                if draft.spendLimitOn {
                    Stepper(value: $draft.spendLimit, in: 0.25...50, step: 0.25) {
                        Text(draft.spendLimit.dollars).font(.body.monospacedDigit())
                    }
                }
            } header: {
                Text("Spending")
            }
        }
    }

    private var openRouterPage: some View {
        Form {
            Section {
                if let info = app.openRouter.keyInfo {
                    Text(moneyLine(info)).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                Button("Add credit on OpenRouter") { openURL(OpenRouterClient.creditsURL) }
            }
            Section {
                Button("Sign out of OpenRouter", role: .destructive) { app.openRouter.signOut() }
            }
        }
        .navigationTitle("OpenRouter")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func providerRow(assetName: String?, name: String, value: String, valueTint: Color) -> some View {
        HStack(spacing: 12) {
            AIProviderIcon(assetName: assetName, fallbackTitle: name, size: 28)
            Text(name).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(valueTint)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    /// One short word or amount for a provider: its balance, Connect, Paused or Problem.
    private func providerValue(saved: AIProviderEndpoint?, id: String) -> String {
        guard let saved else { return "Connect" }
        if !saved.isEnabled { return "Paused" }
        if app.openRouter.externalErrors[id] != nil { return "Problem" }
        if let balance = app.openRouter.externalBalances[id] { return balance.dollars }
        return "On"
    }

    private func providerTint(saved: AIProviderEndpoint?, id: String) -> Color {
        guard let saved else { return theme.accent }
        if app.openRouter.externalErrors[id] != nil { return Theme.danger }
        return saved.isEnabled ? Theme.secondaryText : Theme.secondaryText.opacity(0.6)
    }

    private func moneyLine(_ info: OpenRouterKeyInfo) -> String {
        var parts: [String] = []
        if let balance = app.openRouter.balance { parts.append("Balance: \(balance.dollars)") }
        if let today = info.usageDaily { parts.append("Spent today: \(today.dollars)") }
        if let left = info.freeRequestsLeftToday { parts.append("free AI requests left today: \(left)") }
        if info.isFreeTier { parts.append("no credit bought yet, so Auto uses the free AIs") }
        return parts.isEmpty ? "Ready" : parts.joined(separator: ", ")
    }

    // MARK: Computer

    /// The choices in Computer. A connector is picked by its serverID.
    private enum ComputerChoice: Hashable {
        case automatic, off
        case connector(String)
    }

    private var computer: some View {
        Section {
            Picker("Computer", selection: computerChoice) {
                Text("Automatic").tag(ComputerChoice.automatic)
                Text("Off").tag(ComputerChoice.off)
                ForEach(computerConnectors) { connector in
                    Text(connector.displayName).tag(ComputerChoice.connector(connector.serverID))
                }
                if let removed = removedComputerServer {
                    Text("Removed connector").tag(ComputerChoice.connector(removed))
                }
            }
        } footer: {
            Text(computerConnectors.isEmpty
                 ? "Connect Sprites (or another computer) in Connectors, and the AI runs commands, builds and previews on it by itself."
                 : "The AI runs commands, builds and previews on it by itself, and replies keep going there when you close the app.")
        }
    }

    private var computerChoice: Binding<ComputerChoice> {
        Binding(
            get: {
                if draft.chatComputerOff { return ComputerChoice.off }
                guard let serverID = draft.chatComputerServer else { return ComputerChoice.automatic }
                return ComputerChoice.connector(serverID)
            },
            set: { choice in
                switch choice {
                case .automatic:
                    draft.chatComputerOff = false
                    draft.chatComputerServer = nil
                case .off:
                    draft.chatComputerOff = true
                case .connector(let serverID):
                    draft.chatComputerOff = false
                    draft.chatComputerServer = serverID
                }
            }
        )
    }

    /// Connectors that can actually run commands (Sprites and the like), one per server.
    private var computerConnectors: [ConnectorConfiguration] {
        var seen = Set<String>()
        return app.connectors.connected.filter { $0.kind == .remote && app.connectors.canRunCommands($0) && seen.insert($0.serverID).inserted }
    }

    /// The chosen connector's serverID when that connector has since been removed, so the picker
    /// still has a row for what is saved.
    private var removedComputerServer: String? {
        guard !draft.chatComputerOff, let serverID = draft.chatComputerServer,
              !computerConnectors.contains(where: { $0.serverID == serverID }) else { return nil }
        return serverID
    }

    // MARK: Memories

    private var memories: some View {
        Section {
            Toggle("Use memories in new chats", isOn: $draft.memoriesOn)
            NavigationLink("See and edit memories") { MemoriesScreen(embedded: true) }
        } footer: {
            Text("The AI saves what you tell it to remember, and your corrections, by itself.")
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        Section {
            Picker("Appearance", selection: $draft.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                ForEach(AccentChoice.allCases) { choice in
                    let (accent, partner) = Palette.colors(for: choice)
                    Button {
                        draft.accent = choice
                        Haptics.selection()
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [accent, partner], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                            .overlay {
                                if draft.accent == choice {
                                    Circle().strokeBorder(.primary, lineWidth: 2.5).padding(-4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.label)
                }
            }
            .padding(.vertical, 6)

            Toggle("Motion", isOn: motion)
        } footer: {
            if theme.reduceMotion {
                Text("Reduce Motion is on in your iPhone's settings, so nothing moves.")
            }
        }
    }

    /// One switch for the moving touches: the spark, the glow, the shimmer and sliding messages.
    private var motion: Binding<Bool> {
        Binding(
            get: { draft.effects.sparkMoves || draft.effects.backgroundGlow || draft.effects.thinkingShimmer || draft.effects.messagesSlideIn },
            set: { on in
                draft.effects.sparkMoves = on
                draft.effects.backgroundGlow = on
                draft.effects.thinkingShimmer = on
                draft.effects.messagesSlideIn = on
            }
        )
    }

    // MARK: About and backup

    private var about: some View {
        Section("MAIPA-G") {
            HStack {
                Text("Version")
                Spacer()
                Text("\(app.updates.currentVersion) (build \(app.updates.currentBuild))").foregroundStyle(Theme.secondaryText)
            }
            Button {
                Task { await app.updates.check(using: app.github.publicClient, force: true) }
            } label: {
                HStack {
                    Text(app.updates.isChecking ? "Checking GitHub…" : "Check for a new build")
                    Spacer()
                    if app.updates.isChecking {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(app.updates.isChecking)
            if let message = app.updates.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(app.updates.newer != nil ? theme.accent : Theme.secondaryText)
            }
            if let newer = app.updates.newerBuildNumber {
                Button("Download build \(newer) (.ipa)") {
                    if app.sync.isEverythingBackedUp { openURL(app.updates.downloadURL) }
                    else { confirmUnsafeUpdate = true }
                }
                .fontWeight(.semibold)
            }
        }
    }

    private var backup: some View {
        Section {
            HStack {
                Text("Chats and settings")
                Spacer()
                Text(saveStatus).foregroundStyle(app.sync.isEverythingBackedUp ? Theme.secondaryText : .orange)
            }
            if case .failed(let message) = app.sync.status {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
            }
            if app.github.isConnected {
                Button("Save now") { Task { await app.sync.syncNow() } }
                    .disabled(app.sync.status == .saving)
            }
            NavigationLink("Recently Deleted") { RecentlyDeletedScreen(embedded: true) }
            Button(exporting ? "Preparing export…" : "Export everything to Files") {
                Task { await exportEverything() }
            }
            .disabled(exporting)
            if let exportMessage { Text(exportMessage).font(.footnote).foregroundStyle(Theme.secondaryText) }
        } header: {
            Text("Backup")
        } footer: {
            Text(app.sync.isEverythingBackedUp
                 ? "Everything is in your private MAIPA-G-data repo. Install updates over this app."
                 : "Some data is still only on this phone. Don’t delete the app; tap Save now and install updates over it.")
        }
    }

    private func exportEverything() async {
        guard !exporting else { return }
        exporting = true
        exportMessage = nil
        let source = app.paths.data
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("MAIPA-G-export-\(UUID().uuidString).zip")
        do {
            try await Task.detached {
                try DataExport.makeArchive(dataDirectory: source, destination: destination)
            }.value
            exportURL = destination
            movingExport = true
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
        exporting = false
    }

    private var saveStatus: String {
        switch app.sync.status {
        case .off: return "On this phone only"
        case .idle: return app.sync.lastSaved.map { "Saved \($0.friendlyAgo)" } ?? "Saved"
        case .saving: return "Saving…"
        case .failed: return "Not saved yet"
        }
    }

    /// Everything a person never needs day to day, folded away.
    private var technical: some View {
        Section {
            DisclosureGroup("Technical details") {
                detail("GitHub app", app.github.credentials.map { "\($0.slug) (id \($0.appID))" } ?? "none")
                detail("Installation", app.github.installationID.map(String.init) ?? "none")
                detail("Data repo", app.sync.repo?.fullName ?? "none")
                detail("AIs listed", "\(app.openRouter.allSelectableModels.count)")
                detail("AI providers", app.openRouter.activeProviderSummary)
                detail("iPhone's own AI", OnDeviceAI.status)
                detail("Repo copies", copiesSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                detail("Free iPhone storage", freeSpace.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                if let billing = app.github.actionsBilling {
                    detail("Private Actions minutes", "\(billing.includedMinutesRemaining) of \(Int(billing.includedMinutes)) left")
                    if billing.paidAmount > 0 {
                        Text(String(format: "GitHub is charging $%.2f this month for minutes beyond the allowance.", billing.paidAmount))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let freeSpace, freeSpace < 2 * 1024 * 1024 * 1024 {
                    Text("Storage is low. Clear repo copies before opening another large repository.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let failure = app.backgroundJobs.lastFailure {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Background task")
                        Text(failure).font(.caption).foregroundStyle(Theme.danger)
                    }
                }
                ForEach(app.sync.fileProblems, id: \.self) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.path).font(.footnote.monospaced())
                        Text("\(problem.stage.rawValue.capitalized): \(problem.message)")
                            .font(.caption)
                            .foregroundStyle(Theme.danger)
                    }
                }
                if let error = app.jobs.lastError, error.contains("secret cleanup") || error.contains("Autonomous secrets") {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                    Button("Retry Autonomous cleanup") { Task { await app.jobs.retryPendingSecretCleanup() } }
                }
                if let url = app.sync.repoURL {
                    Button("Open MAIPA-G-data on GitHub") { openURL(url) }
                }
                NavigationLink("Unreadable files") { UnreadableFilesScreen(embedded: true) }
                if app.openRouter.isSignedIn {
                    Button(app.openRouter.isLoadingModels ? "Refreshing models…" : "Refresh all AI models") {
                        Task { await app.openRouter.loadModels(force: true) }
                    }
                    .disabled(app.openRouter.isLoadingModels)
                }
                Button("Clear repo copies") {
                    Task {
                        await app.snapshots.removeAll()
                        copiesSize = await app.snapshots.diskUsage()
                    }
                }
            }
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// A rounded, colored icon tile like the iPhone's own Settings.
struct SettingsIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A main-page row: icon, name, and the current value in grey.
struct SettingsRowLabel: View {
    let title: String
    let icon: String
    let tint: Color
    var value: String?
    var valueTint: Color?

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemImage: icon, tint: tint)
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(valueTint ?? Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
