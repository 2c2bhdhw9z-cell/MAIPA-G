import AgentCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var confirmDisconnect = false
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

    var body: some View {
        NavigationStack {
            Form {
                if let newer = app.updates.newerBuildNumber {
                    Section {
                        Button {
                            if app.sync.isEverythingBackedUp { openURL(app.updates.downloadURL) }
                            else { confirmUnsafeUpdate = true }
                        } label: {
                            HStack(spacing: 12) {
                                Spark(size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Build \(newer) is out").font(.body.weight(.semibold))
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

                accounts
                Section {
                    NavigationLink { HealthCheckScreen(embedded: true) } label: {
                        Label("Check everything", systemImage: "checkmark.shield")
                    }
                }
                look
                workflowPolicy
                chatComputer
                previewHosts
                memories
                money
                notifications
                repoSaving
                saving
                about
                technical
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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
                let disabledAutonomous = app.settings.autonomousEnabled && !edited.autonomousEnabled
                app.updateSettings { settings in
                    settings.appearance = edited.appearance
                    settings.accent = edited.accent
                    settings.effects = edited.effects
                    settings.spendLimitOn = edited.spendLimitOn
                    settings.spendLimit = edited.spendLimit
                    settings.notificationsOn = edited.notificationsOn
                    settings.directSaveRepos = edited.directSaveRepos
                    settings.workflowPolicy = edited.workflowPolicy
                    settings.autonomousEnabled = edited.autonomousEnabled
                    settings.memoriesOn = edited.memoriesOn
                    settings.chatComputerServer = edited.chatComputerServer
                    settings.chatComputerOff = edited.chatComputerOff
                    settings.chatComputerMachine = edited.chatComputerMachine
                    settings.chatComputerHourlyCost = edited.chatComputerHourlyCost
                    settings.previewAllowedHosts = edited.previewAllowedHosts
                }
                if disabledAutonomous {
                    app.home.autonomous = false
                    Task { await app.jobs.cleanupAllAutonomousSecrets() }
                }
            }
            .task {
                await app.openRouter.refreshKeyInfo()
                await app.github.refreshActionsBilling()
                copiesSize = await app.snapshots.diskUsage()
                freeSpace = try? app.paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            }
            .alert("Disconnect GitHub?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) {
                    Task { await app.disconnectGitHub() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("MAIPA-G stops using your repos and stops saving chats to GitHub. Your chats stay on this phone, and the ones already saved stay in MAIPA-G-data.")
            }
            .alert("Some data is not backed up", isPresented: $confirmUnsafeUpdate) {
                Button("Save now first") { Task { await app.sync.syncNow() } }
                Button("Download anyway", role: .destructive) { openURL(app.updates.downloadURL) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Install the new build over this one. Deleting the app first can lose the files that are still only on this phone.")
            }
        }
        .fileMover(isPresented: $movingExport, file: exportURL) { result in
            switch result {
            case .success: exportMessage = "Exported."
            case .failure(let error): exportMessage = "Export failed: \(error.localizedDescription)"
            }
            exportURL = nil
        }
    }

    // MARK: Accounts

    private var accounts: some View {
        Section("Accounts") {
            if app.github.isConnected {
                VStack(alignment: .leading, spacing: 4) {
                    Label("GitHub: \(app.github.login ?? "connected")", systemImage: "link")
                    if let credentials = app.github.credentials {
                        Text("Changes show up as \(credentials.botName)").font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
                if let url = app.github.installationSettingsURL {
                    Button("Choose which repos MAIPA-G can use") { openURL(url) }
                }
                if app.github.needsSignInAgain {
                    Button("Sign in to GitHub again") {
                        Task { await app.github.reauthorize() }
                    }
                }
                Button("Disconnect GitHub", role: .destructive) { confirmDisconnect = true }
            } else {
                Button {
                    app.sheet = .connectGitHub
                } label: {
                    Label(app.github.phase == .needsInstall ? "Finish connecting GitHub" : "Connect GitHub", systemImage: "link")
                }
            }

            if app.openRouter.isSignedIn {
                VStack(alignment: .leading, spacing: 4) {
                    Label("OpenRouter: signed in", systemImage: "sparkles")
                    if let info = app.openRouter.keyInfo {
                        Text(moneyLine(info)).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
                Button("Add credit on OpenRouter") { openURL(OpenRouterClient.creditsURL) }
                Button("Sign out of OpenRouter", role: .destructive) { app.openRouter.signOut() }
            } else {
                Button {
                    app.sheet = .signInOpenRouter
                } label: {
                    Label("Sign in with OpenRouter", systemImage: "sparkles")
                }
            }
        }
    }

    private func moneyLine(_ info: OpenRouterKeyInfo) -> String {
        var parts: [String] = []
        if let balance = app.openRouter.balance { parts.append("Balance: \(balance.dollars)") }
        if let today = info.usageDaily { parts.append("Spent today: \(today.dollars)") }
        if let left = info.freeRequestsLeftToday { parts.append("free AI requests left today: \(left)") }
        if info.isFreeTier { parts.append("no credit bought yet, so Auto uses the free AIs") }
        return parts.isEmpty ? "Ready" : parts.joined(separator: ", ")
    }

    // MARK: Look

    private var look: some View {
        Section {
            Picker("Appearance", selection: $draft.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                Text("Colour")
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
                .padding(.vertical, 4)
            }

            Toggle("Spark moves", isOn: $draft.effects.sparkMoves)
            Toggle("Glow behind the home screen", isOn: $draft.effects.backgroundGlow)
            Toggle("Shimmer while thinking", isOn: $draft.effects.thinkingShimmer)
            Toggle("Messages slide in", isOn: $draft.effects.messagesSlideIn)
        } header: {
            Text("Look")
        } footer: {
            if theme.reduceMotion {
                Text("Reduce Motion is on in your iPhone's settings, so nothing moves.")
            }
        }
    }

    // MARK: Autonomous

    private var workflowPolicy: some View {
        Section {
            Toggle("Autonomous enabled", isOn: $draft.autonomousEnabled)
        } header: {
            Text("Autonomous")
        } footer: {
            Text("Turn Autonomous on from the + button in any chat so the AI plans, uses helper agents and finishes the whole job inside the chat using Auto or whichever AI you pick.")
        }
    }

    // MARK: Computer for chats

    /// The choices in "Computer for chats". A connector is picked by its serverID.
    private enum ComputerChoice: Hashable {
        case automatic, off
        case connector(String)
    }

    /// Every outside host a website preview may reach, by repo, each removable. Previews reach
    /// nothing outside the phone until a host is added from that repo's preview.
    private var previewHosts: some View {
        Section {
            let repos = draft.previewAllowedHosts.filter { !$0.value.isEmpty }.keys.sorted()
            if repos.isEmpty {
                Text("None. Website previews can't reach any outside host.")
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(repos, id: \.self) { repo in
                ForEach((draft.previewAllowedHosts[repo] ?? []).sorted(), id: \.self) { host in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host).font(.body.monospaced())
                        Text(repo).font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", role: .destructive) { removePreviewHost(host, from: repo) }
                            .tint(Theme.danger)
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) { removePreviewHost(host, from: repo) }
                    }
                    .accessibilityAction(named: "Remove") { removePreviewHost(host, from: repo) }
                }
            }
        } header: {
            Text("Preview network access")
        } footer: {
            Text("Add a host from a repo's preview with the network button. Swipe a host to remove it; the preview loses access the next time it opens.")
        }
    }

    private func removePreviewHost(_ host: String, from repo: String) {
        draft.previewAllowedHosts[repo]?.remove(host)
        if draft.previewAllowedHosts[repo]?.isEmpty == true { draft.previewAllowedHosts[repo] = nil }
    }

    private var chatComputer: some View {
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
            if !draft.chatComputerOff {
                LabeledContent("Approximate cost per hour") {
                    TextField("0.10", value: $draft.chatComputerHourlyCost, format: .number.precision(.fractionLength(0...3)))
                        .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                }
                LabeledContent("Machine name") {
                    TextField(AppSettings.defaultChatComputerMachine, text: $draft.chatComputerMachine)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: draft.chatComputerMachine) { _, typed in
                            let clean = AppSettings.machineNameCharacters(typed)
                            if clean != typed { draft.chatComputerMachine = clean }
                        }
                }
                if !draft.chatComputerMachineName.hasPrefix("mcp-") {
                    Text("Sprites' default sign-in only allows names that start with mcp-.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        } header: {
            Text("Computer for chats")
        } footer: {
            Text("The AI uses this computer by itself whenever a job needs commands. Connect Sprites or another computer service in Connectors first.")
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

    /// Connectors that can actually run commands (Sprites and the like), one per server. A
    /// connector such as Hugging Face only answers questions, so it isn't a computer.
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

    private var memories: some View {
        Section {
            Toggle("Use memories in new chats", isOn: $draft.memoriesOn)
            NavigationLink("Edit memories") { MemoriesScreen(embedded: true) }
        } header: { Text("Memories") } footer: {
            Text("Each memory also has its own switch. Memories start empty.")
        }
    }

    // MARK: Money

    private var money: some View {
        Section {
            Toggle("Stop and ask when a job has cost…", isOn: $draft.spendLimitOn)
            if draft.spendLimitOn {
                Stepper(value: $draft.spendLimit, in: 0.25...50, step: 0.25) {
                    Text(draft.spendLimit.dollars).font(.body.monospacedDigit())
                }
            }
        } header: {
            Text("Money")
        } footer: {
            Text("When a reply costs this much, MAIPA-G pauses and asks before spending more.")
        }
    }

    private var notifications: some View {
        Section {
            Toggle("Tell me when work finishes or needs me", isOn: $draft.notificationsOn)
        } header: { Text("Notifications") } footer: {
            Text("MAIPA-G only sends a notification when work finishes or needs an answer.")
        }
    }

    private var repoSaving: some View {
        Section {
            if app.github.repos.isEmpty {
                Text("Your repos appear here after GitHub connects.").foregroundStyle(Theme.secondaryText)
            }
            ForEach(app.github.repos) { repo in
                Toggle(repo.fullName, isOn: Binding(
                    get: { draft.directSaveRepos[repo.fullName] ?? false },
                    set: { draft.directSaveRepos[repo.fullName] = $0 }
                ))
            }
        } header: { Text("Save straight to branch") } footer: {
            Text("Off uses a side branch and pull request. A repo's own rules always win.")
        }
    }

    // MARK: Saving

    private var saving: some View {
        Section {
            HStack {
                Text("Chats and settings")
                Spacer()
                Text(saveStatus).foregroundStyle(Theme.secondaryText)
            }
            if let billing = app.github.actionsBilling {
                HStack {
                    Text("Private Actions minutes")
                    Spacer()
                    Text("\(billing.includedMinutesRemaining) of \(Int(billing.includedMinutes)) left")
                        .foregroundStyle(billing.isLow ? .orange : Theme.secondaryText)
                }
                if billing.paidAmount > 0 {
                    Text(String(format: "GitHub is charging $%.2f this month for minutes beyond the allowance.", billing.paidAmount))
                        .font(.footnote).foregroundStyle(.orange)
                } else if billing.includedMinutesRemaining < 200 {
                    Text("GitHub’s included private-repo minutes are running low. Autonomous jobs in private repos stop or start costing money when they run out.").font(.footnote).foregroundStyle(.orange)
                }
            } else if let error = app.github.actionsBillingError {
                Text("Actions minutes: \(error)").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            if case .failed(let message) = app.sync.status {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
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
                Text(error).font(.footnote).foregroundStyle(Theme.danger)
                Button("Retry Autonomous cleanup") { Task { await app.jobs.retryPendingSecretCleanup() } }
            }
            if app.github.isConnected {
                Button("Find repos with old Autonomous secrets") { Task { await app.jobs.migrateAutonomousLedger() } }
            }
            if app.github.isConnected {
                Button("Save now") { Task { await app.sync.syncNow() } }
                    .disabled(app.sync.status == .saving)
            }
            if let url = app.sync.repoURL {
                Button("Open MAIPA-G-data on GitHub") { openURL(url) }
            }
            NavigationLink("Recently Deleted") { RecentlyDeletedScreen(embedded: true) }
            NavigationLink("Unreadable files") { UnreadableFilesScreen(embedded: true) }
            Button(exporting ? "Preparing export…" : "Export everything to Files") {
                Task { await exportEverything() }
            }
            .disabled(exporting)
            if let exportMessage { Text(exportMessage).font(.footnote).foregroundStyle(Theme.secondaryText) }
        } header: {
            Text("Saving")
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

    // MARK: About

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

    private var technical: some View {
        Section {
            DisclosureGroup("Technical details") {
                detail("GitHub app", app.github.credentials.map { "\($0.slug) (id \($0.appID))" } ?? "none")
                detail("Installation", app.github.installationID.map(String.init) ?? "none")
                detail("Data repo", app.sync.repo?.fullName ?? "none")
                detail("AIs listed", "\(app.openRouter.models.count)")
                detail("OpenRouter key", app.openRouter.keyInfo?.label ?? (app.openRouter.isSignedIn ? "signed in" : "none"))
                detail("iPhone's own AI", OnDeviceAI.status)
                detail("Repo copies", copiesSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                detail("Free iPhone storage", freeSpace.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
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
