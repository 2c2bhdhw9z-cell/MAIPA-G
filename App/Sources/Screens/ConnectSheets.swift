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

/// Sign in with OpenRouter: one tap, no key to copy.
struct SignInOpenRouterSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let account = app.openRouter
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    Spark(size: 88, mood: account.isSigningIn ? .working : .idle)
                    Spacer()
                }
                Text(account.isSignedIn ? "You're signed in" : "Sign in with OpenRouter")
                    .font(.rounded(.title2, weight: .bold))
                Text("MAIPA-G uses your OpenRouter account to talk to AIs. You pay OpenRouter only for what you use, and the free AIs cost nothing.")
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = account.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
                Spacer()
                if !account.isSignedIn {
                    PrimaryButton(title: "Sign in with OpenRouter", systemImage: "person.crop.circle", isBusy: account.isSigningIn) {
                        Task {
                            await account.signIn()
                            if account.isSignedIn { dismiss() }
                        }
                    }
                }
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
