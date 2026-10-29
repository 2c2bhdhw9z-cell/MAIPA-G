import AgentCore
import SwiftUI

/// The side menu under the main screen. The main screen slides right to show it: tap the menu
/// button, or swipe from the left edge. Tap or swipe the main screen to close it.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        @Bindable var app = app
        let theme = Theme.make(app.settings, reduceMotion: reduceMotion)
        GeometryReader { proxy in
            let width = min(330, proxy.size.width * 0.86)
            let base = app.isMenuOpen ? width : 0
            let offset = min(max(base + drag, 0), width)
            let progress = offset / width

            ZStack(alignment: .leading) {
                SideMenu()
                    .frame(width: width)
                    .offset(x: (progress - 1) * width * 0.25)
                    .opacity(0.4 + 0.6 * progress)

                main
                    .frame(width: proxy.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: progress * 28, style: .continuous))
                    .shadow(color: .black.opacity(0.25 * progress), radius: 20, x: -4)
                    // Watches swipes alongside everything else, so it never blocks a tap, a scroll
                    // or the menu button; only a sideways swipe from the left edge opens the menu.
                    .simultaneousGesture(openDrag(width: width), including: app.isMenuOpen ? .subviews : .all)
                    .overlay {
                        if app.isMenuOpen {
                            Color.black.opacity(0.001)
                                .onTapGesture { close() }
                                .gesture(closeDrag(width: width))
                        }
                    }
                    .offset(x: offset)
            }
        }
        .background(Theme.surface.ignoresSafeArea())
        .environment(\.theme, theme)
        .tint(theme.accent)
        .sheet(item: $app.sheet) { sheet in
            SheetContent(sheet: sheet)
                .environment(\.theme, theme)
                .tint(theme.accent)
        }
    }

    private var main: some View {
        NavigationStack {
            if let session = app.library.openSession {
                ChatScreen(session: session)
                    .id(session.id)
            } else {
                HomeScreen()
            }
        }
    }

    private func close() {
        withAnimation(.snappy(duration: 0.3)) {
            app.isMenuOpen = false
            drag = 0
        }
    }

    private func openDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !app.isMenuOpen, value.startLocation.x < 30,
                      value.translation.width > abs(value.translation.height) else { return }
                drag = max(0, value.translation.width)
            }
            .onEnded { value in
                guard drag > 0 else { return }
                withAnimation(.snappy(duration: 0.3)) {
                    app.isMenuOpen = value.translation.width + value.predictedEndTranslation.width * 0.3 > width * 0.35
                    drag = 0
                }
            }
    }

    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in drag = min(0, value.translation.width) }
            .onEnded { value in
                withAnimation(.snappy(duration: 0.3)) {
                    app.isMenuOpen = !(value.translation.width < -width * 0.25 || value.predictedEndTranslation.width < -width * 0.4)
                    drag = 0
                }
            }
    }
}

/// Every sheet the app shows.
struct SheetContent: View {
    @Environment(AppModel.self) private var app
    var sheet: AppSheet

    var body: some View {
        switch sheet {
        case .settings: SettingsScreen()
        case .connectGitHub: ConnectGitHubSheet()
        case .signInOpenRouter: SignInOpenRouterSheet()
        case .models(let target): ModelPicker(target: target)
        case .repos(let target): RepoPicker(target: target)
        case .branches(let target): BranchPicker(target: target)
        case .files(let repo): FilesScreen(repo: repo)
        case .jobs: JobsScreen()
        case .agents: AgentsScreen()
        case .agentEditor(let id):
            NavigationStack {
                AgentEditorScreen(
                    record: id.flatMap { value in app.automations.customAgents.first { $0.definition.id == value } },
                    template: id.flatMap { value in app.automations.agents.first { $0.id == value } }
                )
            }
        case .workflows: WorkflowsScreen()
        case .workflowEditor(let id):
            NavigationStack {
                WorkflowEditorScreen(
                    record: id.flatMap { value in app.automations.customWorkflows.first { $0.definition.id == value } },
                    template: id.flatMap { value in app.automations.workflows.first { $0.id == value } }
                )
            }
        case .workflowMaker: NavigationStack { WorkflowMakerScreen() }
        }
    }
}
