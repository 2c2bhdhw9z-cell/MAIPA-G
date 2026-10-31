import AgentCore
import SwiftUI

/// Connect GitHub: make the user's own MAIPA-G app, then let it into their repos.
struct ConnectGitHubSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var triedOnce = false

    var body: some View {
        let github = app.github
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Spacer()
                        Spark(size: 88, mood: github.progress == nil ? .idle : .working)
                        Spacer()
                    }
                    Text(github.isConnected ? "GitHub is connected" : "Connect GitHub")
                        .font(.rounded(.title2, weight: .bold))
                    if github.isConnected {
                        connected
                    } else {
                        steps
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var steps: some View {
        let github = app.github
        let needsInstall = github.phase == .needsInstall
        return VStack(alignment: .leading, spacing: 16) {
            if let error = github.lastError, !triedOnce {
                Label(error, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            Text("MAIPA-G gets its own app on your GitHub, so everything it does shows up under its own name. Two quick steps:")
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            step(1, "Make your MAIPA-G app", "GitHub asks you to confirm. Tap Create GitHub App.", done: needsInstall)
            step(2, "Let it into your repos", "Pick All repositories, then tap Install & Authorize.", done: false)

            if let progress = github.progress {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progress).foregroundStyle(Theme.secondaryText)
                }
            }
            if let error = github.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }

            PrimaryButton(title: needsInstall ? "Let MAIPA-G in" : "Connect GitHub", systemImage: "link", isBusy: github.progress != nil) {
                Task {
                    triedOnce = true
                    if needsInstall {
                        await github.install()
                    } else {
                        await github.connect()
                    }
                    if github.isConnected {
                        await app.githubDidConnect()
                        dismiss()
                    }
                }
            }

            if triedOnce && !github.isConnected && github.progress == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Didn't work?")
                        .font(.subheadline.weight(.semibold))
                    Text("If GitHub asked you to sign in and then showed an empty page, tap the button again: it goes straight through the second time. If GitHub says the name is taken, add anything to the end, like MAIPA-G-2.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card()
            }
        }
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let login = app.github.login {
                Label("Signed in as \(login)", systemImage: "person.crop.circle.badge.checkmark")
            }
            if let credentials = app.github.credentials {
                Label("Its changes show up as \(credentials.botName)", systemImage: "sparkles")
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Theme.raised))
                    .overlay(Circle().strokeBorder(Theme.stroke))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.black.opacity(0.8))
                } else {
                    Text("\(number)").font(.subheadline.weight(.bold))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Renders the official bundled logo for OpenRouter, OneProvider, SayGM, TeamoRouter, or OmniRoute.
struct AIProviderIcon: View {
    let assetName: String?
    var fallbackTitle: String = "AI"
    var size: CGFloat = 28
    @Environment(\.theme) private var theme

    var body: some View {
        if let assetName, !assetName.isEmpty {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else {
            Text(String(fallbackTitle.prefix(2)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .frame(width: size, height: size)
                .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

/// Sheet to connect or edit OneProvider, SayGM, TeamoRouter, OmniRoute, or a Custom OpenAI/Anthropic-compatible provider.
struct AIProviderConnectSheet: View, Identifiable {
    enum Mode: Hashable {
        case preset(AIProviderPreset)
        case existing(AIProviderEndpoint)
        case customNew
    }

    let mode: Mode
    var onConnected: (() -> Void)? = nil

    var id: String {
        switch mode {
        case .preset(let p): return "preset-\(p.id)"
        case .existing(let e): return "existing-\(e.id)"
        case .customNew: return "custom-new"
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var isEnabled = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var preset: AIProviderPreset? {
        switch mode {
        case .preset(let p): return p
        case .existing(let e): return AIProviderPreset.matching(e.id)
        case .customNew: return nil
        }
    }

    private var existingEndpoint: AIProviderEndpoint? {
        if case .existing(let e) = mode { return app.openRouter.endpoint(for: e.id) ?? e }
        if case .preset(let p) = mode { return app.openRouter.endpoint(for: p.id) }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        AIProviderIcon(assetName: preset?.assetName, fallbackTitle: name.isEmpty ? "AI" : name, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset?.name ?? (name.isEmpty ? "Custom AI Provider" : name))
                                .font(.headline)
                            Text(preset?.subtitle ?? "Any OpenAI or Anthropic-compatible /v1 gateway")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let dash = preset?.dashboardURL, let url = URL(string: dash) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Get API key on \(preset?.name ?? "provider")", systemImage: "safari")
                        }
                    }
                }

                Section {
                    if preset == nil {
                        TextField("Provider name (e.g. My Gateway)", text: $name)
                            .autocorrectionDisabled()
                    }
                    TextField("Base URL (https://.../v1)", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField(preset?.keyPlaceholder ?? "API key (sk-...)", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if existingEndpoint != nil {
                        Toggle("Enabled in model picker", isOn: $isEnabled)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Your API key is stored only in this iPhone's Keychain. MAIPA-G automatically routes OpenAI (/v1/chat/completions, /v1/responses), Anthropic (/v1/messages), and Gemini models.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(isSaving ? "Connecting & loading models…" : "Save & Load Models")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isSaving || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let existing = existingEndpoint {
                        Button("Remove \(existing.name)", role: .destructive) {
                            app.openRouter.removeExternalProvider(existing.id)
                            dismiss()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(preset?.name ?? "Custom AI Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                if let existing = existingEndpoint {
                    name = existing.name
                    baseURL = existing.baseURL
                    apiKey = existing.apiKey
                    isEnabled = existing.isEnabled
                } else if let preset {
                    name = preset.name
                    baseURL = preset.defaultBaseURL
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        let providerID: String
        if let existing = existingEndpoint {
            providerID = existing.id
        } else if let preset {
            providerID = preset.id
        } else {
            let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
            providerID = "custom-\(slug.isEmpty ? UUID().uuidString.prefix(6).lowercased() : slug)"
        }
        do {
            _ = try await app.openRouter.saveExternalProvider(
                id: providerID,
                name: preset?.name ?? name,
                baseURL: baseURL,
                apiKey: apiKey,
                isEnabled: isEnabled
            )
            onConnected?()
            dismiss()
        } catch {
            errorMessage = app.openRouter.describe(error)
        }
    }
}

/// Connect OpenRouter (one-tap OAuth or API key) OR any supported AI gateway (OneProvider, SayGM, TeamoRouter, OmniRoute, Custom).
struct SignInOpenRouterSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var manualOpenRouterKey = ""
    @State private var savingManualKey = false
    @State private var showingManualKey = false
    @State private var selectedGatewaySheet: AIProviderConnectSheet?

    var body: some View {
        let account = app.openRouter
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Spacer()
                        Spark(size: 76, mood: (account.isSigningIn || savingManualKey) ? .working : .idle)
                        Spacer()
                    }
                    Text(account.isSignedIn ? "AI Providers Connected" : "Connect an AI Provider")
                        .font(.rounded(.title2, weight: .bold))
                    Text("Sign in with OpenRouter in one tap (includes free AIs), or connect OneProvider, SayGM, TeamoRouter, OmniRoute, or your own gateway.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = account.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }

                    // Primary OpenRouter card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            AIProviderIcon(assetName: "ProviderOpenRouter", fallbackTitle: "OR", size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("OpenRouter").font(.headline)
                                Text(account.hasOpenRouterKey ? "Signed in" : "300+ models + free tier")
                                    .font(.caption)
                                    .foregroundStyle(account.hasOpenRouterKey ? .green : Theme.secondaryText)
                            }
                            Spacer()
                        }

                        if !account.hasOpenRouterKey {
                            PrimaryButton(title: "Sign in with OpenRouter", systemImage: "person.crop.circle", isBusy: account.isSigningIn) {
                                Task {
                                    await account.signIn()
                                    if account.isSignedIn { dismiss() }
                                }
                            }

                            DisclosureGroup("Or paste an OpenRouter API key", isExpanded: $showingManualKey) {
                                VStack(spacing: 10) {
                                    SecureField("sk-or-v1-...", text: $manualOpenRouterKey)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .textFieldStyle(.roundedBorder)
                                    Button {
                                        Task {
                                            savingManualKey = true
                                            defer { savingManualKey = false }
                                            do {
                                                try await account.saveOpenRouterAPIKey(manualOpenRouterKey)
                                                manualOpenRouterKey = ""
                                                dismiss()
                                            } catch {
                                                // Error displayed via account
                                            }
                                        }
                                    } label: {
                                        Text(savingManualKey ? "Checking key…" : "Save OpenRouter Key")
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(savingManualKey || manualOpenRouterKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                .padding(.top, 8)
                            }
                            .font(.footnote.weight(.medium))
                        }
                    }
                    .card(cornerRadius: 20, padding: 14)

                    // First-class gateways: OneProvider, SayGM, TeamoRouter, OmniRoute, Custom
                    VStack(alignment: .leading, spacing: 10) {
                        Text("More Supported AI Providers")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)

                        ForEach(AIProviderPreset.builtIn) { preset in
                            let connected = account.endpoint(for: preset.id)?.isReady == true
                            Button {
                                selectedGatewaySheet = AIProviderConnectSheet(mode: .preset(preset)) {
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    AIProviderIcon(assetName: preset.assetName, fallbackTitle: preset.name, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(preset.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(connected ? "Connected" : "Connect")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(connected ? .green : .secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            selectedGatewaySheet = AIProviderConnectSheet(mode: .customNew) {
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AIProviderIcon(assetName: nil, fallbackTitle: "+", size: 32)
                                Text("Custom OpenAI / Anthropic URL…")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $selectedGatewaySheet) { sheet in
                sheet
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
