import AgentCore
import SwiftUI

/// The first screen: Spark, a greeting, and the message box.
struct HomeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var home = app.home
        ZStack {
            Theme.background.ignoresSafeArea()
            GlowBackground().ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Spark(size: 116)
                Text("What's the plan?")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Spacer(minLength: 24)
                if app.openRouter.isSignedIn {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button { app.sheet = app.github.isConnected ? .repos(.home) : .connectGitHub } label: {
                                Label(app.github.isConnected ? "GitHub ✓" : "GitHub", systemImage: "link")
                            }
                            Button { app.sheet = .specs(home.repo) } label: { Label("Specs", systemImage: "list.clipboard") }
                            Button { app.sheet = .workflows } label: { Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted") }
                            Button { app.sheet = .agents } label: { Label("Agents", systemImage: "person.crop.circle") }
                            if let balance = app.openRouter.balance { Label(balance.dollars, systemImage: "creditcard") }
                            else { Label("OpenRouter ✓", systemImage: "sparkles") }
                            if let free = app.openRouter.freeRequestsLeft { Label("\(free) free", systemImage: "sparkles") }
                            if let repo = home.repo {
                                Button { app.sheet = .files(repo) } label: { Label("Files", systemImage: "folder") }
                            }
                            if !app.jobs.jobs.isEmpty {
                                Button { app.jobs.show() } label: {
                                    Label(app.jobs.activeCount > 0 ? "\(app.jobs.activeCount) working" : "Jobs", systemImage: "gearshape.2")
                                }
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.bottom, 10)
                }
                SetupCards()
                    .padding(.bottom, 12)
                Composer(
                    text: $home.text,
                    attachments: $home.attachments,
                    webEnabled: $home.webEnabled,
                    autonomous: $home.autonomous,
                    modelLabel: app.openRouter.label(for: home.model),
                    thinking: home.thinking,
                    thinkingLevels: app.openRouter.thinkingLevels(for: home.model),
                    repo: home.repo,
                    groupName: app.groups.name(for: home.groupID),
                    isGitHubConnected: app.github.isConnected,
                    isRunning: false,
                    canStop: false,
                    onSend: { app.sendFromHome() },
                    onStop: {},
                    onPickModel: { app.sheet = .models(.home) },
                    onPickThinking: { app.choose(thinking: $0, for: .home) },
                    onPickRepo: { app.sheet = app.github.isConnected ? .repos(.home) : .connectGitHub },
                    onPickBranch: { app.sheet = .branches(.home) },
                    onClearRepo: { app.choose(repo: nil, for: .home) },
                    onPickGroup: { app.sheet = .groups(.home) },
                    onSpec: { app.sheet = .specs(home.repo) }
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Short cards for whatever still needs setting up.
struct SetupCards: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            if !app.openRouter.isSignedIn {
                setupCard(
                    icon: "sparkles",
                    title: "Sign in with OpenRouter",
                    detail: "So MAIPA-G can talk to the AIs. The free ones cost nothing.",
                    button: "Sign in"
                ) { app.sheet = .signInOpenRouter }
            }
            if !app.github.isConnected {
                setupCard(
                    icon: "link",
                    title: app.github.phase == .needsInstall ? "Finish connecting GitHub" : "Connect GitHub",
                    detail: "So MAIPA-G can read your repos and keep your chats safe.",
                    button: app.github.phase == .needsInstall ? "Finish" : "Connect"
                ) { app.sheet = .connectGitHub }
            }
        }
    }

    private func setupCard(icon: String, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .font(.subheadline.weight(.semibold))
        }
        .card(cornerRadius: 20, padding: 14)
    }
}

/// The side-menu button at the top left.
struct MenuButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { app.isMenuOpen.toggle() }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .overlay(alignment: .topTrailing) {
                    if app.updates.newer != nil {
                        Circle().fill(.red).frame(width: 8, height: 8).offset(x: 4, y: -3)
                    }
                }
        }
        .accessibilityLabel("Menu")
    }
}
