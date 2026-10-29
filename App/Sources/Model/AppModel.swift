import AgentCore
import Foundation
import Observation
import SwiftUI

/// Which message box a picker is choosing for: the home screen's, or an open chat's.
enum ComposerTarget: Hashable, Sendable {
    case home
    case chat(UUID)
}

enum AppSheet: Identifiable, Hashable {
    case settings
    case connectGitHub
    case signInOpenRouter
    case models(ComposerTarget)
    case repos(ComposerTarget)
    case branches(ComposerTarget)
    case files(ChatRepo, ComposerTarget)
    case jobs
    case agents
    case agentEditor(String?)
    case workflows
    case workflowEditor(String?)
    case workflowMaker
    case memories
    case memoryEditor(UUID?)
    case groups(ComposerTarget)
    case specs(ChatRepo?)
    case specReview(UUID)
    case connectors
    case connectorDetail(UUID)
    case connectorCatalogDetail(String)
    case pictureGenerator(ComposerTarget)
    case picture(UUID)
    case webPreview(ChatRepo)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .connectGitHub: return "github"
        case .signInOpenRouter: return "openrouter"
        case .models(let target): return "models-\(target)"
        case .repos(let target): return "repos-\(target)"
        case .branches(let target): return "branches-\(target)"
        case .files(let repo, let target): return "files-\(repo.ref.fullName)-\(repo.branch)-\(target)"
        case .jobs: return "jobs"
        case .agents: return "agents"
        case .agentEditor(let id): return "agent-editor-\(id ?? "new")"
        case .workflows: return "workflows"
        case .workflowEditor(let id): return "workflow-editor-\(id ?? "new")"
        case .workflowMaker: return "workflow-maker"
        case .memories: return "memories"
        case .memoryEditor(let id): return "memory-editor-\(id?.uuidString ?? "new")"
        case .groups(let target): return "groups-\(target)"
        case .specs(let repo): return "specs-\(repo?.ref.fullName ?? "all")"
        case .specReview(let id): return "spec-review-\(id.uuidString)"
        case .connectors: return "connectors"
        case .connectorDetail(let id): return "connector-\(id.uuidString)"
        case .connectorCatalogDetail(let id): return "connector-catalog-\(id)"
        case .pictureGenerator(let target): return "picture-generator-\(target)"
        case .picture(let id): return "picture-\(id.uuidString)"
        case .webPreview(let repo): return "preview-\(repo.ref.fullName)-\(repo.branch)"
        }
    }
}

/// What's in the home screen's box before a chat starts.
@MainActor
@Observable
final class HomeDraft {
    var text = ""
    /// New chats start on Auto.
    var model: ModelChoice = .auto
    var thinking: ThinkingLevel = .default
    var repo: ChatRepo?
    var attachments: [AttachmentReference] = []
    var groupID: UUID?
    var webEnabled = true
    /// Always starts off for a new chat.
    var autonomous = false
}

/// The app's state, shared by every screen.
@MainActor
@Observable
final class AppModel {
    let paths: AppPaths
    let transport: URLSessionTransport
    let github: GitHubAccount
    let openRouter: OpenRouterAccount
    let library: ChatLibrary
    let sync: SyncCoordinator
    let updates: UpdateChecker
    let snapshots: SnapshotStore
    let attachmentStore: AttachmentStore
    let notifications = Notifications()
    let jobs: JobCoordinator
    let automations: AutomationLibrary
    let memories: MemoryLibrary
    let groups: GroupLibrary
    let specs: SpecCoordinator
    let connectors: ConnectorLibrary
    let previews: PreviewCoordinator
    let backgroundJobs = BackgroundJobs()
    let home = HomeDraft()
    private(set) var settings: AppSettings

    var isMenuOpen = false
    var sheet: AppSheet?
    @ObservationIgnored private var started = false

    init() {
        let paths = AppPaths.make()
        self.paths = paths
        let transport = URLSessionTransport()
        self.transport = transport
        github = GitHubAccount(transport: transport)
        openRouter = OpenRouterAccount(transport: transport, paths: paths)
        library = ChatLibrary(store: ChatStore(dataDirectory: paths.data))
        sync = SyncCoordinator(paths: paths)
        updates = UpdateChecker()
        snapshots = SnapshotStore(root: paths.repoCopies)
        attachmentStore = AttachmentStore(dataDirectory: paths.data)
        jobs = JobCoordinator(dataDirectory: paths.data)
        automations = AutomationLibrary(dataDirectory: paths.data)
        memories = MemoryLibrary(dataDirectory: paths.data)
        groups = GroupLibrary(dataDirectory: paths.data)
        specs = SpecCoordinator(dataDirectory: paths.data)
        connectors = ConnectorLibrary(transport: transport, paths: paths)
        previews = PreviewCoordinator(root: paths.previews)
        settings = Self.readSettings(paths)
        library.app = self
        sync.app = self
        jobs.app = self
        automations.app = self
        memories.app = self
        groups.app = self
        specs.app = self
        connectors.app = self
        previews.app = self
        backgroundJobs.app = self
        backgroundJobs.register()
        home.repo = settings.lastRepo
    }

    // MARK: Starting up

    func start() async {
        guard !started else { return }
        started = true
        if let scene = PreviewScenes.scene {
            await showPreview(scene)
            return
        }
        openRouter.restore()
        github.restore()
        await library.load()
        await jobs.load()
        await automations.load()
        await memories.load()
        await groups.load()
        await specs.load()
        await connectors.load()
        async let models: Void = openRouter.loadModels()
        async let key: Void = openRouter.refreshKeyInfo()
        await github.refresh()
        await startSaving()
        await updates.check(using: github.publicClient)
        _ = await (models, key)
    }

    /// Called when the connect sheet finishes.
    func githubDidConnect() async {
        await github.refresh()
        await startSaving()
    }

    private func startSaving() async {
        guard github.isConnected, let client = github.client, let installation = github.installationID, let owner = github.login else { return }
        await sync.configure(client: client, owner: owner, installationID: installation)
    }

    func disconnectGitHub() async {
        await sync.syncNow()
        await sync.reset()
        await github.disconnect()
        home.repo = nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard !PreviewScenes.isActive else { return }
        switch phase {
        case .background:
            backgroundJobs.schedule(hasActiveJobs: jobs.activeCount > 0)
            // iOS 17–25 keep the established short grace period. It also safely covers a final
            // save if iOS 26 declines a continued-processing request.
            let grace = BackgroundGrace(name: "MAIPA-G save") {}
            Task {
                await sync.syncNow()
                await jobs.refresh()
                await specs.refreshJobs()
                grace.end()
            }
        case .active:
            guard started else { return }
            Task {
                await openRouter.refreshKeyInfo()
                await updates.check(using: github.publicClient)
                sync.request(after: 1)
            }
        default:
            break
        }
    }

    // MARK: Settings

    private static func readSettings(_ paths: AppPaths) -> AppSettings {
        let url = paths.data.appendingPathComponent(AppSettings.fileName)
        guard let data = try? Data(contentsOf: url), let settings = try? JSONCoding.decoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        copy.updatedAt = Date()
        settings = copy
        guard !PreviewScenes.isActive else { return }
        let store = library.store
        Task {
            try? await store.saveDocument(copy, at: AppSettings.fileName)
            sync.request()
        }
    }

    /// A save brought newer chats or settings from GitHub (another phone, or a reinstall).
    func dataChangedFromGitHub(_ report: DataRepoSync.Report) async {
        if report.downloaded.contains(AppSettings.fileName) {
            settings = Self.readSettings(paths)
            if home.repo == nil { home.repo = settings.lastRepo }
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("chats/") }) {
            await library.reloadFromDisk()
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("jobs/") }) {
            await jobs.refresh()
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("agents/") || $0.hasPrefix("workflows/") }) {
            await automations.load()
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("memories/") }) {
            await memories.load()
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("groups/") }) {
            await groups.load()
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("specs/") }) {
            await specs.load()
        }
        if (report.downloaded + report.deletedHere).contains(where: { $0.hasPrefix("connectors/") }) {
            await connectors.load()
        }
    }

    // MARK: Chats

    func sendFromHome() {
        let text = home.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !home.attachments.isEmpty else { return }
        guard openRouter.isSignedIn else {
            sheet = .signInOpenRouter
            return
        }
        notifications.requestIfNeeded(enabled: settings.notificationsOn)
        if home.attachments.isEmpty, let repo = home.repo, jobs.shouldRunAutonomously(request: text, repo: repo, explicitlyEnabled: home.autonomous) {
            let request = text
            Task { await jobs.start(request: request, repo: repo) }
        } else {
            library.startChat(text: text, attachments: home.attachments, repo: home.repo, model: home.model, thinking: home.thinking, groupID: home.groupID, memories: memories.activeTexts)
        }
        home.text = ""
        home.attachments = []
        home.groupID = nil
        home.model = .auto
        home.thinking = .default
        home.autonomous = false
        let repo = home.repo
        updateSettings { $0.lastRepo = repo }
        Haptics.tap(enabled: true)
    }

    func newChat() {
        library.showHome()
        isMenuOpen = false
    }

    func turnFinished(in session: ChatSession) {
        Task { await openRouter.refreshKeyInfo() }
        sync.request()
        if session.lastTurn?.status == .done || session.lastTurn?.status == .waitingForUser {
            Haptics.success()
            let needsAnswer = session.lastTurn?.status == .waitingForUser
            notifications.post(title: needsAnswer ? "MAIPA-G needs you" : "MAIPA-G finished", body: session.chat.title.isEmpty ? "Your chat is ready." : session.chat.title, enabled: settings.notificationsOn)
        }
    }

    // MARK: Pickers

    func repo(for target: ComposerTarget) -> ChatRepo? {
        switch target {
        case .home: return home.repo
        case .chat(let id): return library.session(id)?.chat.repo
        }
    }

    func model(for target: ComposerTarget) -> ModelChoice {
        switch target {
        case .home: return home.model
        case .chat(let id): return library.session(id)?.chat.model ?? .auto
        }
    }

    func choose(model: ModelChoice, for target: ComposerTarget) {
        switch target {
        case .home:
            home.model = model
            let levels = openRouter.thinkingLevels(for: model)
            if !levels.isEmpty, let nearest = home.thinking.nearest(in: levels) { home.thinking = nearest }
        case .chat(let id):
            library.session(id)?.setModel(model)
        }
    }

    func choose(thinking: ThinkingLevel, for target: ComposerTarget) {
        switch target {
        case .home: home.thinking = thinking
        case .chat(let id): library.session(id)?.setThinking(thinking)
        }
    }

    func choose(repo: GitHubRepo?, for target: ComposerTarget) {
        let chosen = repo.map { ChatRepo(ref: $0.ref, branch: $0.defaultBranch, defaultBranch: $0.defaultBranch, isPrivate: $0.isPrivate) }
        set(chosen, for: target)
    }

    func choose(branch: String, for target: ComposerTarget) {
        guard var repo = repo(for: target) else { return }
        repo.branch = branch
        set(repo, for: target)
    }

    private func set(_ repo: ChatRepo?, for target: ComposerTarget) {
        switch target {
        case .home:
            home.repo = repo
            updateSettings { $0.lastRepo = repo }
        case .chat(let id):
            library.session(id)?.setRepo(repo)
        }
    }

    func group(for target: ComposerTarget) -> UUID? {
        switch target {
        case .home: return home.groupID
        case .chat(let id): return library.session(id)?.chat.groupID
        }
    }

    func choose(group id: UUID?, for target: ComposerTarget) {
        switch target {
        case .home: home.groupID = id
        case .chat(let chatID): library.session(chatID)?.setGroup(id)
        }
    }

    func reference(repo: RepoRef, commit: String, path: String, in target: ComposerTarget) {
        let reference = "Repo file: \(repo.fullName)@\(commit):\(path)"
        switch target {
        case .home:
            home.text = [home.text, reference].filter { !$0.isEmpty }.joined(separator: home.text.isEmpty ? "" : "\n")
        case .chat(let id):
            guard let session = library.session(id) else { return }
            session.draft = [session.draft, reference].filter { !$0.isEmpty }.joined(separator: session.draft.isEmpty ? "" : "\n")
        }
    }

    func attach(_ attachment: AttachmentReference, to target: ComposerTarget) {
        switch target {
        case .home: if !home.attachments.contains(where: { $0.id == attachment.id }) { home.attachments.append(attachment) }
        case .chat(let id):
            if let session = library.session(id), !session.draftAttachments.contains(where: { $0.id == attachment.id }) { session.draftAttachments.append(attachment) }
        }
    }

    // MARK: Screenshots

    /// Sets up one made-up scene for the build check's screenshots (see PreviewScenes).
    private func showPreview(_ scene: String) async {
        if scene != "home-new" && scene != "connect" {
            openRouter.previewSignedIn()
            github.previewConnected()
            sync.previewSaved()
            home.repo = ChatRepo(ref: RepoRef(owner: "2c2bhdhw9z-cell", name: "MAIPA-G"), branch: "main", defaultBranch: "main", isPrivate: false)
        }
        let summaries = PreviewScenes.sampleSummaries()
        groups.preview(PreviewScenes.sampleGroups())
        memories.preview(PreviewScenes.sampleMemories())
        specs.preview(PreviewScenes.sampleSpecs())
        switch scene {
        case "chat": library.preview(summaries: summaries, open: PreviewScenes.sampleChat())
        case "questions": library.preview(summaries: summaries, open: PreviewScenes.questionChat())
        case "working": library.preview(summaries: summaries, open: PreviewScenes.workingChat())
        case "thinking": library.preview(summaries: summaries, open: PreviewScenes.thinkingChat())
        case "menu":
            library.preview(summaries: summaries, open: nil)
            isMenuOpen = true
        case "files":
            library.preview(summaries: summaries, open: nil)
            if let repo = home.repo { sheet = .files(repo, .home) }
        case "settings":
            library.preview(summaries: summaries, open: nil)
            sheet = .settings
        case "jobs", "job-needs-you":
            library.preview(summaries: summaries, open: nil)
            jobs.preview(PreviewScenes.sampleJobs(needsYou: scene == "job-needs-you"))
            sheet = .jobs
        case "agents":
            library.preview(summaries: summaries, open: nil)
            sheet = .agents
        case "agent-editor":
            library.preview(summaries: summaries, open: nil)
            sheet = .agentEditor("coder")
        case "workflows":
            library.preview(summaries: summaries, open: nil)
            sheet = .workflows
        case "workflow-editor":
            library.preview(summaries: summaries, open: nil)
            sheet = .workflowEditor("full-feature")
        case "workflow-maker":
            library.preview(summaries: summaries, open: nil)
            sheet = .workflowMaker
        case "memories", "menu-memories":
            library.preview(summaries: summaries, open: nil)
            if scene == "memories" { sheet = .memories } else { isMenuOpen = true }
        case "memory-editor":
            library.preview(summaries: summaries, open: nil)
            sheet = .memoryEditor(memories.memories.first?.id)
        case "chat-memory":
            var chat = PreviewScenes.sampleChat()
            if !chat.messages.isEmpty { chat.messages[0].starredMemoryID = memories.memories.first?.id }
            library.preview(summaries: summaries, open: chat)
        case "groups":
            library.preview(summaries: summaries, open: nil)
            home.groupID = PreviewScenes.previewGroupID
            sheet = .groups(.home)
        case "specs":
            library.preview(summaries: summaries, open: nil)
            sheet = .specs(home.repo)
        case "spec-requirements", "spec-design", "spec-tasks":
            var spec = PreviewScenes.sampleSpecs()[0]
            if scene == "spec-requirements" {
                spec.stage = .requirements
                spec.approvedStages = []
            } else if scene == "spec-design" {
                spec.stage = .checkedDesign
                spec.approvedStages = [.requirements, .design]
            }
            specs.preview([spec])
            library.preview(summaries: summaries, open: nil)
            sheet = .specReview(spec.id)
        case "menu-agents", "menu-workflows":
            library.preview(summaries: summaries, open: nil)
            isMenuOpen = true
        case "connect":
            library.preview(summaries: [], open: nil)
            sheet = .connectGitHub
        case "models":
            library.preview(summaries: summaries, open: nil)
            await openRouter.loadModels(force: true)
            sheet = .models(.home)
        case "connectors":
            library.preview(summaries: summaries, open: nil); connectors.preview(); sheet = .connectors
        case "connector-detail", "connector-auth":
            library.preview(summaries: summaries, open: nil); connectors.preview(authNeeded: scene == "connector-auth")
            if let connector = connectors.connected.first {
                sheet = .connectorDetail(connector.id)
            }
        case "chat-connector":
            var chat = PreviewScenes.sampleChat()
            if var turn = chat.lastAssistantTurn {
                var call = ToolCallRecord(id: "mcp1", name: "mcp_github_search_repositories", arguments: "{}", summary: "Used GitHub · Search repositories", status: .done)
                call.detail = "Found MAIPA-G and Continuum-."
                turn.steps[0].toolCalls.append(call); chat.messages[chat.messages.count - 1].assistantTurn = turn
            }
            library.preview(summaries: summaries, open: chat); connectors.preview()
        case "photo-input":
            library.preview(summaries: summaries, open: nil)
            home.attachments = [AttachmentReference(name: "launch-photo.jpg", mimeType: "image/jpeg", kind: .image, path: "attachments/preview/photo.jpg", bytes: 1200)]
        case "picture-generating": library.preview(summaries: summaries, open: nil); sheet = .pictureGenerator(.home)
        case "picture-result":
            let chat = PreviewScenes.pictureChat(); library.preview(summaries: summaries, open: chat)
            if let id = chat.lastAssistantTurn?.steps.first?.generatedImages?.first?.id { sheet = .picture(id) }
        case "preview", "preview-error", "files-web":
            library.preview(summaries: summaries, open: nil)
            if scene == "preview" { previews.previewFixture(); if let repo = home.repo { sheet = .webPreview(repo) } }
            else if scene == "files-web", let repo = home.repo { sheet = .files(repo, .home) }
            else if let repo = home.repo { previews.previewError(); sheet = .webPreview(repo) }
        default:
            library.preview(summaries: scene == "home-new" ? [] : summaries, open: nil)
        }
    }

    // MARK: Look

    var preferredColorScheme: ColorScheme? {
        switch settings.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}
