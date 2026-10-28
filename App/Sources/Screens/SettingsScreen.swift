import AgentCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var confirmDisconnect = false
    @State private var copiesSize: Int64?
    /// The controls edit this copy; every change is saved straight away.
    @State private var draft = AppSettings()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let newer = app.updates.newerBuildNumber {
                    Section {
                        Button {
                            openURL(app.updates.downloadURL)
                        } label: {
                            HStack(spacing: 12) {
                                Spark(size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Build \(newer) is out").font(.body.weight(.semibold))
                                    Text("Tap to download it, then sign it with your sideloading app.")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.secondaryText)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                accounts
                look
                money
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
            .onChange(of: draft) { _, edited in
                guard loaded else { return }
                app.updateSettings { settings in
                    settings.appearance = edited.appearance
                    settings.accent = edited.accent
                    settings.effects = edited.effects
                    settings.spendLimitOn = edited.spendLimitOn
                    settings.spendLimit = edited.spendLimit
                }
            }
            .task {
                await app.openRouter.refreshKeyInfo()
                copiesSize = await app.snapshots.diskUsage()
            }
            .confirmationDialog("Disconnect GitHub?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    Task { await app.disconnectGitHub() }
                }
            } message: {
                Text("MAIPA-G stops using your repos and stops saving chats to GitHub. Your chats stay on this phone, and the ones already saved stay in MAIPA-G-data.")
            }
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

    // MARK: Saving

    private var saving: some View {
        Section {
            HStack {
                Text("Chats and settings")
                Spacer()
                Text(saveStatus).foregroundStyle(Theme.secondaryText)
            }
            if case .failed(let message) = app.sync.status {
                Text(message).font(.footnote).foregroundStyle(Theme.danger)
            }
            if app.github.isConnected {
                Button("Save now") { Task { await app.sync.syncNow() } }
                    .disabled(app.sync.status == .saving)
            }
            if let url = app.sync.repoURL {
                Button("Open MAIPA-G-data on GitHub") { openURL(url) }
            }
        } header: {
            Text("Saving")
        } footer: {
            Text("Everything is kept in your private MAIPA-G-data repo, so deleting the app loses nothing.")
        }
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
            Button("Check for a new build") {
                Task { await app.updates.check(using: app.github.publicClient, force: true) }
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
