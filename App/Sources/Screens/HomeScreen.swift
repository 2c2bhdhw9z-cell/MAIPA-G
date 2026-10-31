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
                SetupCards()
                    .padding(.bottom, 12)
                Composer(
                    text: $home.text,
                    attachments: $home.attachments,
                    webEnabled: $home.webEnabled,
                    autonomous: $home.autonomous,
                    modelLabel: app.openRouter.label(for: home.model),
                    contextUsedTokens: 0,
                    contextLimitTokens: app.openRouter.contextLimit(for: home.model),
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
                    onSpec: { app.sheet = .specs(home.repo) },
                    onPicture: { app.sheet = .pictureGenerator(.home) },
                    onPreview: { if let repo = home.repo { app.sheet = .webPreview(repo) } },
                    onFiles: { if let repo = home.repo { app.sheet = .files(repo, .home) } },
                    onWorkstation: { app.sheet = .workstation(.home) }
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                MenuButton()
                Spacer()
                HStack(spacing: 4) {
                    if app.jobs.activeCount > 0 {
                        Button { app.jobs.show() } label: {
                            Label("\(app.jobs.activeCount) working", systemImage: "gearshape.2")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        app.sheet = .workstation(.home)
                    } label: {
                        Image(systemName: "square.on.square.dashed")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Workstation")
                }
                .padding(.horizontal, 4)
                .glassPanel(cornerRadius: 20, interactive: false)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .toolbar(.hidden, for: .navigationBar)
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
                    title: "Connect an AI provider",
                    detail: "Sign in with OpenRouter (includes free AIs) or paste a key from OneProvider, SayGM, TeamoRouter, or OmniRoute.",
                    button: "Connect"
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
    @Environment(\.theme) private var theme
    @AccessibilityFocusState(for: .voiceOver) private var menuButtonFocused: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { app.isMenuOpen.toggle() }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 44, height: 44)
                .glassPanel(cornerRadius: 22, interactive: false)
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if app.updates.newer != nil {
                        Circle().fill(.red).frame(width: 8, height: 8).offset(x: -2, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Menu")
        .accessibilityFocused($menuButtonFocused)
        .onChange(of: app.isMenuOpen) { _, isOpen in
            guard !isOpen, app.sheet == nil else { return }
            Task { @MainActor in
                await Task.yield()
                menuButtonFocused = true
            }
        }
    }
}
