import AgentCore
import PDFKit
import PhotosUI
import SwiftUI
import UIKit

/// Unified Workstation combining Runable's infinite pan-and-zoom Canvas (upgraded to display EVERY
/// file type, not just images), Arena's Workspace folder tree, and Kiro's Changes/Reviews diff panel.
///
/// The lists, card places and view live in `WorkstationCanvasModel`. This screen only gathers what
/// they're made from and lays out the header and the three tabs, each its own view, so a pinch or
/// a drag redraws the Canvas board and nothing else.
struct WorkstationScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case canvas = "Canvas"
        case files = "Files"
        case changes = "Changes"
        var id: String { rawValue }
    }

    let target: ComposerTarget
    var initialTab: Tab = .canvas

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .canvas
    @State private var canvas = WorkstationCanvasModel()
    @State private var diffScope = 0
    @State private var diffText = "Loading changes…"

    @State private var fileQuery = ""
    @State private var expandedFolders: Set<String> = ["staged", "uploads", "generated", "diagrams", "repo", "computer"]
    @State private var stagedChanges: [StagedChange] = []
    @State private var repoEntries: [GitTreeEntry] = []
    @State private var repoCommit: String?
    @State private var repoLoading = false
    @State private var computerFiles: [String] = []
    @State private var computerLoading = false

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var localAddedAttachments: [AttachmentReference] = []
    @State private var importError: String?

    private var session: ChatSession? {
        if case .chat(let id) = target { return app.library.session(id) }
        return nil
    }

    private var storageKey: String {
        switch target {
        case .home: return "workstation.layout.v2.home"
        case .chat(let id): return "workstation.layout.v2.\(id.uuidString)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkstationHeader(
                tab: $tab,
                canvas: canvas,
                onExport: { exportAllLocalAttachments() },
                onClose: { dismiss() }
            )
            Divider().opacity(0.6)

            switch tab {
            case .canvas:
                WorkstationCanvasBoard(
                    canvas: canvas,
                    photoItems: $photoItems,
                    actions: WorkstationBoardActions(
                        addToChat: { addItemToChat($0) },
                        share: { shareItem($0) },
                        remove: { removeDraftItem($0) },
                        pickFiles: { pickFilesForWorkstation() }
                    )
                )
            case .files:
                WorkstationFilesTab(
                    canvas: canvas,
                    query: $fileQuery,
                    expandedFolders: $expandedFolders,
                    repoLoading: repoLoading,
                    computerAvailable: app.connectors.computerControl() != nil,
                    machineName: app.settings.chatComputerMachineName,
                    computerLoading: computerLoading,
                    computerFileCount: computerFiles.count,
                    onOpen: { canvas.previewingItem = $0 },
                    onAddToChat: { addItemToChat($0) },
                    onLoadComputer: { Task { await loadComputerFiles() } }
                )
            case .changes:
                WorkstationChangesTab(session: session, diffScope: $diffScope, diffText: $diffText)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .background(
            WorkstationSourceObserver(
                target: target,
                canvas: canvas,
                localAdded: localAddedAttachments,
                repoEntries: repoEntries,
                repoCommit: repoCommit,
                computerFiles: computerFiles,
                stagedChanges: $stagedChanges
            )
        )
        .onAppear {
            tab = initialTab
            canvas.configure(storageKey: storageKey)
        }
        .onDisappear {
            canvas.flushLayout()
            canvas.saveViewport()
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app: write any card move still waiting for its one-second save.
            if phase != .active { canvas.flushLayout() }
        }
        .task(id: canvas.activeRepo) {
            await loadRepoTreeIfNeeded()
        }
        .onChange(of: photoItems) { _, picked in
            guard !picked.isEmpty else { return }
            photoItems = []
            importPickedPhotos(picked)
        }
        .sheet(item: Binding(get: { canvas.previewingItem }, set: { canvas.previewingItem = $0 })) { item in
            WorkstationItemPreviewSheet(
                item: item,
                repo: canvas.activeRepo,
                repoCommit: repoCommit,
                onAddToChat: { addItemToChat(item) }
            )
        }
        .alert("Workstation", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Actions

    private func addItemToChat(_ item: WorkstationItem) {
        if let att = item.attachment {
            switch target {
            case .home:
                if !app.home.attachments.contains(where: { $0.id == att.id }) {
                    app.home.attachments.append(att)
                }
            case .chat(let id):
                if let s = app.library.session(id), !s.draftAttachments.contains(where: { $0.id == att.id }) {
                    s.draftAttachments.append(att)
                }
            }
            Haptics.selection()
            dismiss()
            return
        }
        if let path = item.repoPath, let repo = canvas.activeRepo {
            app.reference(repo: repo.ref, commit: repoCommit ?? repo.branch, path: path, in: target)
            Haptics.selection()
            dismiss()
            return
        }
        if case .computerFile(let path) = item.kind {
            let note = "Inspect `\(path)` on `\(app.settings.chatComputerMachineName)`"
            switch target {
            case .home: app.home.text = app.home.text.isEmpty ? note : "\(app.home.text)\n\(note)"
            case .chat(let id):
                if let s = app.library.session(id) {
                    s.draft = s.draft.isEmpty ? note : "\(s.draft)\n\(note)"
                }
            }
            Haptics.selection()
            dismiss()
        }
    }

    private func removeDraftItem(_ item: WorkstationItem) {
        guard let att = item.attachment else { return }
        localAddedAttachments.removeAll { $0.id == att.id }
        switch target {
        case .home:
            app.home.attachments.removeAll { $0.id == att.id }
        case .chat(let id):
            app.library.session(id)?.draftAttachments.removeAll { $0.id == att.id }
        }
        if canvas.selectedItemID == item.id { canvas.selectedItemID = nil }
        Haptics.selection()
    }

    private func shareItem(_ item: WorkstationItem) {
        guard let att = item.attachment else { return }
        Task {
            if let url = await ShareableAttachmentURL.prepare(attachment: att, store: app.attachmentStore) {
                SharePresenter.present(items: [url])
            }
        }
    }

    private func exportAllLocalAttachments() {
        let items = canvas.exportableAttachments
        guard !items.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for att in items.prefix(30) {
                if let url = await ShareableAttachmentURL.prepare(attachment: att, store: app.attachmentStore) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                SharePresenter.present(items: urls)
            }
        }
    }

    private func pickFilesForWorkstation() {
        AttachmentFilePicker.shared.present(
            onPick: { files in
                Task {
                    var failures: [String] = []
                    for picked in files {
                        do {
                            let imported = try await AttachmentImporter.importFileURL(picked.url, name: picked.name, store: app.attachmentStore)
                            appendDraftAttachment(imported)
                        } catch let error as AttachmentImporter.Failure {
                            failures.append("\(picked.name): \(error.localizedDescription)")
                        } catch {
                            failures.append("Couldn't add \(picked.name).")
                        }
                    }
                    if !failures.isEmpty {
                        importError = failures.joined(separator: "\n")
                    }
                }
            },
            onFailure: { importError = $0 }
        )
    }

    private func importPickedPhotos(_ picked: [PhotosPickerItem]) {
        Task {
            var idx = canvas.uploadItems.filter { $0.attachment?.kind == .image }.count + 1
            for item in picked {
                if let imported = try? await AttachmentImporter.importPhoto(item, baseName: picked.count > 1 ? "Photo \(idx)" : nil, store: app.attachmentStore) {
                    appendDraftAttachment(imported)
                    idx += 1
                }
            }
        }
    }

    private func appendDraftAttachment(_ attachment: AttachmentReference) {
        if !localAddedAttachments.contains(where: { $0.id == attachment.id }) {
            localAddedAttachments.append(attachment)
        }
        switch target {
        case .home:
            if !app.home.attachments.contains(where: { $0.id == attachment.id }) {
                app.home.attachments.append(attachment)
            }
        case .chat(let id):
            if let s = app.library.session(id), !s.draftAttachments.contains(where: { $0.id == attachment.id }) {
                s.draftAttachments.append(attachment)
            }
        }
        Haptics.selection()
    }

    private func loadRepoTreeIfNeeded() async {
        guard let repo = canvas.activeRepo, let github = app.repoClient(for: repo.ref) else {
            repoEntries = []
            repoCommit = nil
            return
        }
        repoLoading = true
        defer { repoLoading = false }
        do {
            let commit = try await github.resolveCommit(repo.ref, ref: repo.branch)
            let ws = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
            let tree = try await ws.tree().entries
            repoCommit = commit
            repoEntries = tree
        } catch {
            repoEntries = []
        }
    }

    private func loadComputerFiles() async {
        guard let control = app.connectors.computerControl(), !computerLoading else { return }
        computerLoading = true
        defer { computerLoading = false }
        if let output = try? await control.run("find ~ -maxdepth 3 -not -path '*/.*' -type f 2>/dev/null | head -n 120") {
            computerFiles = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}

/// Wide enough to stay roughly square. A hard cap of 8 turned a few hundred cards into a
/// single tall strip, which then had to be zoomed until every card was a speck.
extension WorkstationCanvasLayout {
    static func idealGridColumns(for count: Int) -> Int {
        if count <= 1 { return 1 }
        if count <= 4 { return 2 }
        if count <= 9 { return 3 }
        return Int(ceil(sqrt(Double(count))))
    }
}

extension WorkstationBadgeTint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .mint: return .mint
        case .orange: return .orange
        case .purple: return .purple
        case .green: return .green
        case .indigo: return .indigo
        case .teal: return .teal
        }
    }
}

extension WorkstationItem {
    var badgeColor: Color { badgeTint.color }
}

// MARK: - Sources

/// Reads the chat (which changes on every word of a streaming reply) so the screen doesn't have
/// to, and hands the model plain copies. The model rebuilds only what actually changed.
private struct WorkstationSourceObserver: View {
    let target: ComposerTarget
    let canvas: WorkstationCanvasModel
    let localAdded: [AttachmentReference]
    let repoEntries: [GitTreeEntry]
    let repoCommit: String?
    let computerFiles: [String]
    @Binding var stagedChanges: [StagedChange]

    @Environment(AppModel.self) private var app

    private struct Key: Equatable {
        var signature: WorkstationSourceSignature
        var pendingChanges: Int
        var repo: ChatRepo?
    }

    var body: some View {
        let session = currentSession
        let repo = app.repo(for: target)
        let sources = makeSources(session: session, repo: repo)
        let signature = sources.signature()
        let pending = pendingChanges(session)
        Color.clear
            .onChange(of: Key(signature: signature, pendingChanges: pending, repo: repo), initial: true) {
                canvas.sync(sources, signature: signature, pendingChanges: pending, activeRepo: repo)
            }
            .task(id: session?.chat.updatedAt) {
                if let session {
                    stagedChanges = await session.currentStagedChanges()
                }
            }
    }

    private var currentSession: ChatSession? {
        if case .chat(let id) = target { return app.library.session(id) }
        return nil
    }

    private func makeSources(session: ChatSession?, repo: ChatRepo?) -> WorkstationSources {
        var sources = WorkstationSources()
        sources.localAdded = localAdded
        if let session {
            sources.hasSession = true
            sources.workstationFiles = session.workstationFiles
            sources.draftAttachments = session.draftAttachments
            sources.messages = session.chat.messages
        } else {
            sources.homeAttachments = app.home.attachments
        }
        sources.staged = stagedChanges
        sources.repoName = repo?.ref.name
        sources.repoCommit = repoCommit
        sources.repoEntries = repoEntries
        sources.machineName = app.settings.chatComputerMachineName
        sources.computerFiles = computerFiles
        return sources
    }

    private func pendingChanges(_ session: ChatSession?) -> Int {
        if !stagedChanges.isEmpty { return stagedChanges.count }
        guard let session else { return 0 }
        if let receipt = session.chat.saveReceipts?.last, receipt.resolution == nil, receipt.undoneAt == nil {
            return 1
        }
        return 0
    }
}

// MARK: - Top Header (`Canvas | Files | Changes`)

private struct WorkstationHeader: View {
    @Binding var tab: WorkstationScreen.Tab
    let canvas: WorkstationCanvasModel
    let onExport: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "square.on.square.dashed")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(theme.accent)
                    Text("Workstation")
                        .font(.rounded(.headline, weight: .bold))
                }

                Spacer()

                Text("\(canvas.allCount) \(canvas.allCount == 1 ? "item" : "items") · \(canvas.totalBytesText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)

                if !canvas.exportableAttachments.isEmpty {
                    Button {
                        onExport()
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Download or share files")
                }

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 40, height: 40)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Close Workstation")
            }

            HStack(spacing: 6) {
                tabButton(.canvas, badge: canvas.items.count)
                tabButton(.files, badge: canvas.allCount)
                tabButton(.changes, badge: canvas.pendingChangesCount)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.surface.opacity(0.6))
    }

    private func tabButton(_ candidate: WorkstationScreen.Tab, badge: Int) -> some View {
        let selected = tab == candidate
        return Button {
            withAnimation(.snappy(duration: 0.22)) { tab = candidate }
            Haptics.selection()
        } label: {
            HStack(spacing: 5) {
                Text(candidate.rawValue)
                    .font(.subheadline.weight(.semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(selected ? Color.white.opacity(0.24) : Theme.raised, in: Capsule())
                }
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(selected ? theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? Color.clear : Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Infinite Pan & Zoom Canvas Tab (All File Types)

/// What the board's buttons do that needs the screen (the chat's draft, sharing, the file picker).
struct WorkstationBoardActions {
    var addToChat: @MainActor (WorkstationItem) -> Void
    var share: @MainActor (WorkstationItem) -> Void
    var remove: @MainActor (WorkstationItem) -> Void
    var pickFiles: @MainActor () -> Void
}

private struct BoardPinch: Equatable {
    var magnification: CGFloat
    var anchor: CGPoint
}

/// A card being dragged on the drawn (lite) cards, by a screen offset.
private struct CanvasMovingCard: Equatable {
    let id: String
    let offset: CGSize
}

/// Which pictures and snippets the lite cards need: the 512-point squares in view, so it changes
/// a few times across a long pan rather than on every frame.
private struct LiteMediaRequest: Equatable {
    var cells: CanvasSpatialIndex.CellRange
    var revision: Int
    var layout: Int
    var pixels: Int
}

/// The Canvas. A gesture in progress lives in `@GestureState` here and moves one transformed
/// layer; the model's zoom and pan change once, when the gesture ends.
private struct WorkstationCanvasBoard: View {
    let canvas: WorkstationCanvasModel
    @Binding var photoItems: [PhotosPickerItem]
    let actions: WorkstationBoardActions

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var pinch: BoardPinch? = nil
    /// The drag being tracked (by where it started) and, on drawn cards, the card it moves.
    @State private var dragStart: CGPoint?
    @State private var dragCardID: String?
    @State private var liteMedia = WorkstationLiteMedia()

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            TimelineView(.animation(minimumInterval: nil, paused: canvas.animation == nil)) { timeline in
                boardContent(viewport: viewport, now: timeline.date)
            }
        }
        .onDisappear {
            liteMedia.clear()
        }
    }

    @ViewBuilder
    private func boardContent(viewport: CGSize, now: Date) -> some View {
        let shown = liveTransform(base: canvas.displayedTransform(at: now), viewport: viewport)
        let detail = detailLevel(zoom: shown.zoom)
        ZStack {
            CanvasDotGrid(pan: shown.pan, zoom: shown.zoom, isDark: colorScheme == .dark)
                .contentShape(Rectangle())
                .gesture(tapGesture(viewport: viewport))
                .gesture(dragGesture(viewport: viewport))

            if canvas.items.isEmpty {
                if canvas.hasBuiltItems {
                    emptyCanvasPlaceholder
                }
            } else if canvas.isLayoutReady {
                cardsLayer(detail: detail, shown: shown, viewport: viewport)
            }

            controls(viewport: viewport, shown: shown)
        }
        .clipped()
        .simultaneousGesture(pinchGesture(viewport: viewport))
        .onChange(of: pinch != nil) { _, pinching in
            // A pinch stops a running animation where it is, as a drag does.
            if pinching { canvas.interruptAnimation() }
        }
        .onChange(of: liteRequest(detail: detail, shown: shown, viewport: viewport), initial: true) { _, request in
            loadLiteMedia(request)
        }
    }

    /// How cards are drawn at a zoom. With VoiceOver on, the drawn (lite) range uses real cards,
    /// which VoiceOver can read and tap.
    private func detailLevel(zoom: CGFloat) -> WorkstationCanvasLayout.Detail {
        let level = WorkstationCanvasLayout.detail(zoom: zoom, itemCount: canvas.items.count)
        return level == .lite && voiceOverEnabled ? .full : level
    }

    /// The resting (or animating) view with the gesture in progress applied: zoom around the
    /// fingers first, then the pan.
    private func liveTransform(base: CanvasViewTransform, viewport: CGSize) -> CanvasViewTransform {
        var transform = base
        if let pinch {
            transform = transform.zoomed(by: pinch.magnification, anchor: pinch.anchor, viewport: viewport)
        }
        if dragCardID == nil {
            transform = transform.translated(by: dragTranslation)
        }
        return transform
    }

    @ViewBuilder
    private func cardsLayer(detail: WorkstationCanvasLayout.Detail, shown: CanvasViewTransform, viewport: CGSize) -> some View {
        switch detail {
        case .overview:
            CanvasOverviewMarks(
                entries: canvas.entries(in: shown.visibleCanvasRect(viewport: viewport, marginX: 30, marginY: 30)),
                transform: shown,
                viewport: viewport,
                selectedID: canvas.selectedItemID
            )
            .allowsHitTesting(false)
        case .lite:
            CanvasLiteCards(
                entries: canvas.entries(in: shown.visibleCanvasRect(viewport: viewport, marginX: 40, marginY: 40)),
                transform: shown,
                viewport: viewport,
                selectedID: canvas.selectedItemID,
                movingCard: dragCardID.map { CanvasMovingCard(id: $0, offset: dragTranslation) },
                thumbnails: liteMedia.thumbnails,
                snippets: liteMedia.snippets
            )
            .allowsHitTesting(false)
        case .full:
            fullCards(shown: shown, viewport: viewport)
        }
    }

    /// Real cards, only those on screen (and a margin). They're laid out at the resting zoom and
    /// moved as one layer while a gesture runs, so no card rebuilds until the gesture ends.
    private func fullCards(shown: CanvasViewTransform, viewport: CGSize) -> some View {
        let buildZoom = max(canvas.zoom, WorkstationCanvasLayout.fullCardZoom)
        let visible = canvas.entries(in: shown.visibleCanvasRect(viewport: viewport, marginX: 120, marginY: 160))
        let origin = shown.origin(in: viewport)
        let pointer = canvas.tool == .pointer
        let selectedID = canvas.selectedItemID
        return ZStack(alignment: .topLeading) {
            ForEach(visible) { entry in
                WorkstationCanvasCard(
                    item: entry.item,
                    isSelected: entry.id == selectedID,
                    pointerEnabled: pointer,
                    zoom: buildZoom,
                    canvas: canvas
                )
                .equatable()
                .frame(
                    width: max(1, WorkstationCanvasCard.cardWidth * buildZoom),
                    height: max(1, WorkstationCanvasCard.cardHeight * buildZoom)
                )
                .position(x: entry.center.x * buildZoom, y: entry.center.y * buildZoom)
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .scaleEffect(shown.zoom / buildZoom, anchor: .topLeading)
        .offset(x: origin.x, y: origin.y)
        .allowsHitTesting(pointer)
    }

    // MARK: Gestures

    /// One tap selects the card on top under the finger, or clears the selection, at once. A
    /// double tap also opens a drawn card (as on a real card) or zooms in around the tap, and back
    /// out when already in.
    private func tapGesture(viewport: CGSize) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                handleTap(at: value.location, viewport: viewport)
            }
            .simultaneously(
                with: SpatialTapGesture(count: 2)
                    .onEnded { value in
                        handleDoubleTap(at: value.location, viewport: viewport)
                    }
            )
    }

    private func handleTap(at location: CGPoint, viewport: CGSize) {
        let shown = canvas.displayedTransform(at: Date())
        let hit = canvas.item(at: location, viewport: viewport, transform: shown)
        canvas.selectedItemID = hit?.id
        if hit != nil, canvas.tool == .pointer, detailLevel(zoom: shown.zoom) == .lite {
            Haptics.selection()
        }
    }

    private func handleDoubleTap(at location: CGPoint, viewport: CGSize) {
        let shown = canvas.displayedTransform(at: Date())
        if canvas.tool == .pointer,
           detailLevel(zoom: shown.zoom) == .lite,
           let hit = canvas.item(at: location, viewport: viewport, transform: shown) {
            canvas.previewingItem = hit
            return
        }
        canvas.doubleTapZoom(at: location, viewport: viewport)
    }

    /// Pans the canvas, or, on drawn cards with the pointer tool, moves the card under the finger.
    /// A flick keeps gliding.
    private func dragGesture(viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onChanged { value in
                guard dragStart != value.startLocation else { return }
                dragStart = value.startLocation
                canvas.interruptAnimation()
                dragCardID = cardToMove(at: value.startLocation, viewport: viewport)
            }
            .onEnded { value in
                let movedCard = dragStart == value.startLocation ? dragCardID : cardToMove(at: value.startLocation, viewport: viewport)
                dragStart = nil
                dragCardID = nil
                if let movedCard {
                    let zoom = max(canvas.displayedTransform(at: Date()).zoom, WorkstationCanvasLayout.minZoom)
                    canvas.moveCard(movedCard, by: CGSize(width: value.translation.width / zoom, height: value.translation.height / zoom))
                } else {
                    canvas.commitPan(
                        translation: value.translation,
                        predictedEndTranslation: value.predictedEndTranslation,
                        viewport: viewport,
                        liveMagnification: pinch?.magnification
                    )
                }
            }
    }

    private func cardToMove(at location: CGPoint, viewport: CGSize) -> String? {
        guard canvas.tool == .pointer else { return nil }
        let shown = canvas.displayedTransform(at: Date())
        guard detailLevel(zoom: shown.zoom) == .lite else { return nil }
        return canvas.item(at: location, viewport: viewport, transform: shown)?.id
    }

    /// Pinch zooms around the point between the fingers.
    private func pinchGesture(viewport: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in
                state = BoardPinch(magnification: value.magnification, anchor: value.startLocation)
            }
            .onEnded { value in
                canvas.commitPinch(magnification: value.magnification, anchor: value.startLocation, viewport: viewport)
            }
    }

    // MARK: Lite card pictures

    private func liteRequest(detail: WorkstationCanvasLayout.Detail, shown: CanvasViewTransform, viewport: CGSize) -> LiteMediaRequest? {
        guard detail == .lite,
              let cells = CanvasSpatialIndex.cellRange(for: shown.visibleCanvasRect(viewport: viewport, marginX: 40, marginY: 40)) else { return nil }
        let pixels = Int((WorkstationCanvasLayout.previewHeight * shown.zoom * max(displayScale, 2)).rounded(.up))
        return LiteMediaRequest(
            cells: cells,
            revision: canvas.itemsRevision,
            layout: canvas.layoutRevision,
            pixels: ThumbnailPipeline.bucket(for: max(128, pixels))
        )
    }

    private func loadLiteMedia(_ request: LiteMediaRequest?) {
        guard let request else {
            liteMedia.clear()
            return
        }
        let size = CanvasSpatialIndex.cellSize
        let rect = CGRect(
            x: CGFloat(request.cells.minX) * size,
            y: CGFloat(request.cells.minY) * size,
            width: CGFloat(request.cells.maxX - request.cells.minX + 1) * size,
            height: CGFloat(request.cells.maxY - request.cells.minY + 1) * size
        )
        liteMedia.want(canvas.entries(in: rect).map(\.item), pixels: request.pixels, store: app.attachmentStore)
    }

    // MARK: Controls

    private func controls(viewport: CGSize, shown: CanvasViewTransform) -> some View {
        // Top controls: `Arrange` + `Center` on the left, `[ - | 100% | + ]` zoom pill on the right
        VStack {
            HStack(spacing: 8) {
                if !canvas.items.isEmpty {
                    HStack(spacing: 2) {
                        Button {
                            arrangeAllCards(in: viewport)
                        } label: {
                            Label("Arrange", systemImage: "square.grid.2x2")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 11)
                                .frame(minHeight: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().frame(height: 16)

                        Button {
                            centerOnCards(in: viewport)
                        } label: {
                            Label("Center", systemImage: "scope")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 11)
                                .frame(minHeight: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                    .glassPanel(cornerRadius: 19, interactive: false)
                }
                Spacer()
                zoomPill(viewport: viewport, shown: shown)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer()

            if let selectedItem = canvas.selectedItem {
                selectionActionBar(for: selectedItem)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            bottomCanvasDock(viewport: viewport)
                .padding(.bottom, 12)
        }
    }

    private func arrangeAllCards(in viewport: CGSize) {
        guard !canvas.items.isEmpty else { return }
        canvas.arrange(viewport: viewport)
        Haptics.selection()
    }

    private func centerOnCards(in viewport: CGSize) {
        canvas.centerOnCards(viewport: viewport)
        if !canvas.items.isEmpty { Haptics.selection() }
    }

    private func zoomPill(viewport: CGSize, shown: CanvasViewTransform) -> some View {
        HStack(spacing: 0) {
            Button {
                canvas.stepZoom(direction: -1, viewport: viewport)
                Haptics.selection()
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .frame(width: 40, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")

            Button {
                canvas.resetZoom(viewport: viewport)
                Haptics.selection()
            } label: {
                Text("\(max(1, Int((shown.zoom * 100).rounded())))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 50, minHeight: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset zoom to 100%")

            Button {
                canvas.stepZoom(direction: 1, viewport: viewport)
                Haptics.selection()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 40, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")
        }
        .padding(.horizontal, 4)
        .glassPanel(cornerRadius: 19, interactive: false)
    }

    private func selectionActionBar(for item: WorkstationItem) -> some View {
        HStack(spacing: 6) {
            Button {
                canvas.previewingItem = item
            } label: {
                Label("Open", systemImage: "eye")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                actions.addToChat(item)
            } label: {
                Label("Add to chat", systemImage: "plus.bubble")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if item.attachment != nil {
                Button {
                    actions.share(item)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 8)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if item.isRemovableDraft {
                Button(role: .destructive) {
                    actions.remove(item)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassPanel(cornerRadius: 20, interactive: false)
    }

    private func bottomCanvasDock(viewport: CGSize) -> some View {
        HStack(spacing: 6) {
            dockButton(icon: "cursorarrow", active: canvas.tool == .pointer, label: "Select & move cards") {
                canvas.tool = .pointer
                Haptics.selection()
            }
            dockButton(icon: "hand.raised", active: canvas.tool == .hand, label: "Pan canvas") {
                canvas.tool = .hand
                Haptics.selection()
            }
            Divider().frame(height: 22).padding(.horizontal, 2)
            dockButton(icon: "plus", active: false, label: "Add any file") {
                Haptics.selection()
                actions.pickFiles()
            }
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 20,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                Image(systemName: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add photos")

            if !canvas.items.isEmpty {
                dockButton(icon: "square.grid.2x2", active: false, label: "Arrange cards into grid") {
                    arrangeAllCards(in: viewport)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 26, interactive: false)
    }

    private func dockButton(icon: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? .white : .primary)
                .frame(width: 44, height: 44)
                .background(active ? theme.accent : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(label)
    }

    private var emptyCanvasPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 40))
                .foregroundStyle(theme.accent)
            Text("Your Canvas is ready")
                .font(.rounded(.title3, weight: .bold))
            Text("Photos, PDFs, Markdown, code, charts, ZIPs, IPAs, and repo files all appear here as movable cards you can arrange and zoom.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
            HStack(spacing: 10) {
                Button {
                    actions.pickFiles()
                } label: {
                    Label("Add files", systemImage: "doc.badge.plus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: 20,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label("Add photos", systemImage: "photo")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .glassPanel(cornerRadius: 24)
    }
}

// MARK: - Cards

/// What a card looks like at a zoom: preview on top, badge, name and source below. The real
/// cards draw it at the current zoom; the drawn (lite) cards draw it once at 100% and scale it.
private struct WorkstationCardFace: View, Equatable {
    let item: WorkstationItem
    let zoom: CGFloat
    let isSelected: Bool
    let thumbnail: UIImage?
    let snippet: String?
    /// Live Mermaid diagrams, only on real cards zoomed in enough to read them.
    let showsLiveDiagram: Bool
    let showsShadow: Bool

    @Environment(\.theme) private var theme

    nonisolated static func == (lhs: WorkstationCardFace, rhs: WorkstationCardFace) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.revision == rhs.item.revision
            && lhs.zoom == rhs.zoom
            && lhs.isSelected == rhs.isSelected
            && lhs.thumbnail === rhs.thumbnail
            && lhs.snippet == rhs.snippet
            && lhs.showsLiveDiagram == rhs.showsLiveDiagram
            && lhs.showsShadow == rhs.showsShadow
    }

    private var renderedWidth: CGFloat { max(1, WorkstationCanvasLayout.cardWidth * zoom) }
    private var renderedHeight: CGFloat { max(1, WorkstationCanvasLayout.cardHeight * zoom) }
    private var renderedPreviewHeight: CGFloat { max(1, WorkstationCanvasLayout.previewHeight * zoom) }

    private func scaled(_ value: CGFloat, floor: CGFloat = 1) -> CGFloat {
        max(floor, value * zoom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea
                .frame(width: renderedWidth, height: renderedPreviewHeight)
                .clipped()

            HStack(spacing: scaled(7)) {
                Text(item.badgeText)
                    .font(.system(size: scaled(9), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, scaled(6))
                    .padding(.vertical, scaled(2.5))
                    .background(item.badgeColor, in: RoundedRectangle(cornerRadius: scaled(5), style: .continuous))

                VStack(alignment: .leading, spacing: scaled(1, floor: 0)) {
                    Text(item.name)
                        .font(.system(size: scaled(12), weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(.system(size: scaled(10)))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(8))
            .frame(width: renderedWidth, height: max(1, renderedHeight - renderedPreviewHeight), alignment: .leading)
            .background(Theme.surface)
        }
        .frame(width: renderedWidth, height: renderedHeight)
        .clipShape(RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(16), style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Theme.stroke, lineWidth: isSelected ? scaled(2.5) : max(0.5, zoom))
        )
        .shadow(color: showsShadow ? .black.opacity(isSelected ? 0.26 : 0.10) : .clear, radius: isSelected ? 10 : 4, x: 0, y: 3)
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            Theme.raised
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: renderedWidth, height: renderedPreviewHeight)
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: scaled(30), weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.35), radius: scaled(4, floor: 0))
                }
            } else if let snippet {
                let lowerName = item.name.lowercased()
                if showsLiveDiagram, lowerName.hasSuffix(".mmd") || lowerName.hasSuffix(".mermaid") {
                    MermaidBlockView(code: snippet, compactCardMode: true)
                        .frame(width: renderedWidth, height: renderedPreviewHeight)
                } else {
                    snippetText(snippet)
                }
            } else if case .mermaid(let code) = item.kind {
                if showsLiveDiagram {
                    MermaidBlockView(code: code, compactCardMode: true)
                        .frame(width: renderedWidth, height: renderedPreviewHeight)
                } else {
                    // Only the first few hundred characters fit on a card; laying out more is wasted.
                    snippetText(String(code.prefix(1_200)))
                }
            } else {
                VStack(spacing: scaled(8)) {
                    Image(systemName: item.icon)
                        .font(.system(size: scaled(34), weight: .semibold))
                        .foregroundStyle(item.badgeColor)
                    Text(item.badgeText)
                        .font(.system(size: scaled(12), weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func snippetText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scaled(9.5), design: .monospaced))
            .foregroundStyle(.primary.opacity(0.86))
            .padding(scaled(10))
            .frame(width: renderedWidth, height: renderedPreviewHeight, alignment: .topLeading)
    }
}

/// A card you can touch: tap selects, double tap opens, drag moves (pointer tool). Compared by
/// id, revision, selection and zoom, and its actions go through the model, so moving the canvas
/// never rebuilds it.
private struct WorkstationCanvasCard: View, Equatable {
    let item: WorkstationItem
    let isSelected: Bool
    let pointerEnabled: Bool
    let zoom: CGFloat
    let canvas: WorkstationCanvasModel

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var snippet: String?
    @State private var liveDrag: CGSize = .zero

    static let cardWidth: CGFloat = WorkstationCanvasLayout.cardWidth
    static let cardHeight: CGFloat = WorkstationCanvasLayout.cardHeight

    nonisolated static func == (lhs: WorkstationCanvasCard, rhs: WorkstationCanvasCard) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.revision == rhs.item.revision
            && lhs.isSelected == rhs.isSelected
            && lhs.pointerEnabled == rhs.pointerEnabled
            && lhs.zoom == rhs.zoom
    }

    /// Pixels the photo needs on this screen, rounded up to a shared size. A fixed small
    /// thumbnail stretched by zoom is what made pictures soft.
    static func thumbnailPixels(zoom: CGFloat, scale: CGFloat) -> Int {
        let pixels = Int((WorkstationCanvasLayout.previewHeight * zoom * max(scale, 2)).rounded(.up))
        return pixels > 1_024 ? 1_600 : ThumbnailPipeline.bucket(for: max(128, pixels))
    }

    static func cachedThumbnail(for item: WorkstationItem, pixels: Int) -> UIImage? {
        if case .stagedChange = item.kind {
            return ThumbnailPipeline.shared.bestCachedImage(key: stagedKey(item), maxPixelSize: pixels)
        }
        guard let attachment = item.attachment else { return nil }
        return ThumbnailPipeline.shared.bestCachedThumbnail(for: attachment, maxPixelSize: pixels)
    }

    static func stagedKey(_ item: WorkstationItem) -> String {
        "staged-\(item.id)-\(item.revision)"
    }

    private var thumbnailPixelSize: Int {
        Self.thumbnailPixels(zoom: zoom, scale: displayScale)
    }

    var body: some View {
        // Until this card's own load finishes, show what's already decoded (this size or a
        // smaller one) on the first frame. Equatable cards rerun this only when they change,
        // not on every frame of a pan.
        WorkstationCardFace(
            item: item,
            zoom: zoom,
            isSelected: isSelected,
            thumbnail: thumbnail ?? Self.cachedThumbnail(for: item, pixels: thumbnailPixelSize),
            snippet: snippet ?? WorkstationSnippetCache.snippet(for: item),
            showsLiveDiagram: zoom >= 0.85,
            showsShadow: zoom >= 0.8
        )
        .equatable()
        .offset(liveDrag)
        .onTapGesture(count: 2) {
            canvas.previewingItem = item
        }
        .onTapGesture(count: 1) {
            canvas.selectedItemID = item.id
            Haptics.selection()
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    guard pointerEnabled else { return }
                    liveDrag = value.translation
                }
                .onEnded { value in
                    guard pointerEnabled else { return }
                    let delta = value.translation
                    liveDrag = .zero
                    let scale = max(zoom, 0.01)
                    canvas.moveCard(item.id, by: CGSize(width: delta.width / scale, height: delta.height / scale))
                }
        )
        .task(id: "\(item.id)#\(item.revision)#\(thumbnailPixelSize)") {
            await loadPreview(pixels: thumbnailPixelSize)
        }
    }

    /// Loads off the main thread and stops when the card scrolls away.
    private func loadPreview(pixels: Int) async {
        if case .stagedChange(let path, let data, _, _) = item.kind {
            if WorkstationItem.isImagePath(path) {
                if let image = await ThumbnailPipeline.shared.thumbnail(data: data, key: Self.stagedKey(item), maxPixelSize: pixels), !Task.isCancelled {
                    thumbnail = image
                }
            } else if snippet == nil, let text = await WorkstationSnippetCache.load(for: item, store: app.attachmentStore), !Task.isCancelled {
                snippet = text
            }
            return
        }
        guard let att = item.attachment else { return }
        switch item.kind {
        case .image, .pdf:
            if let image = await ThumbnailPipeline.shared.thumbnail(for: att, store: app.attachmentStore, maxPixelSize: pixels), !Task.isCancelled {
                thumbnail = image
            }
        case .textOrCode:
            if snippet == nil, let text = await WorkstationSnippetCache.load(for: item, store: app.attachmentStore), !Task.isCancelled {
                snippet = text
            }
        default:
            if item.isVideo, let image = await ThumbnailPipeline.shared.thumbnail(for: att, store: app.attachmentStore, maxPixelSize: pixels), !Task.isCancelled {
                thumbnail = image
            }
        }
    }
}

/// The first lines of text files, read once for both kinds of card.
@MainActor
enum WorkstationSnippetCache {
    private static var snippets: [String: String] = [:]

    private static func key(_ item: WorkstationItem) -> String {
        "\(item.id)#\(item.revision)"
    }

    static func snippet(for item: WorkstationItem) -> String? {
        snippets[key(item)]
    }

    static func load(for item: WorkstationItem, store: AttachmentStore) async -> String? {
        if let cached = snippets[key(item)] { return cached }
        var text: String?
        switch item.kind {
        case .stagedChange(let path, let data, _, _):
            guard !WorkstationItem.isImagePath(path) else { return nil }
            text = await Task.detached(priority: .utility) {
                String(data: data, encoding: .utf8).map { String($0.prefix(280)) }
            }.value
        case .textOrCode:
            guard let att = item.attachment else { return nil }
            if let slice = (try? await store.readSlice(for: att, offsetBytes: 0, maxBytes: 4_096))?.data,
               let str = AttachmentDataPreviewBody.readableText(from: slice, name: att.name) {
                text = String(str.prefix(280))
            }
        default:
            return nil
        }
        if let text {
            if snippets.count > 4_000 { snippets.removeAll() }
            snippets[key(item)] = text
        }
        return text
    }
}

/// Pictures and snippets for the drawn (lite) cards in view, loaded a few at a time, cancelled
/// when they leave, and handed over in batches so the drawing updates once per batch.
@Observable
@MainActor
final class WorkstationLiteMedia {
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var snippets: [String: String] = [:]

    @ObservationIgnored private var loads: [String: Task<Void, Never>] = [:]
    /// The size each running picture load asked for.
    @ObservationIgnored private var loadingPixels: [String: Int] = [:]
    @ObservationIgnored private var loadedPixels: [String: Int] = [:]
    @ObservationIgnored private var pendingThumbnails: [String: UIImage] = [:]
    @ObservationIgnored private var pendingSnippets: [String: String] = [:]
    @ObservationIgnored private var flushScheduled = false

    func want(_ items: [WorkstationItem], pixels: Int, store: AttachmentStore) {
        let wanted = Set(items.map(\.id))
        for (id, task) in loads where !wanted.contains(id) {
            task.cancel()
            loads[id] = nil
            loadingPixels[id] = nil
        }
        if thumbnails.count > wanted.count + 200 {
            thumbnails = thumbnails.filter { wanted.contains($0.key) }
            loadedPixels = loadedPixels.filter { wanted.contains($0.key) }
        }
        if snippets.count > 3_000 {
            snippets = snippets.filter { wanted.contains($0.key) }
        }
        for item in items {
            if let running = loads[item.id] {
                // A picture still loading at the old size (the zoom moved on): start again at this one.
                guard let started = loadingPixels[item.id], started != pixels else { continue }
                running.cancel()
                loads[item.id] = nil
                loadingPixels[item.id] = nil
            }
            if Self.wantsThumbnail(item), loadedPixels[item.id] != pixels {
                loadThumbnail(item, pixels: pixels, store: store)
            } else if Self.wantsSnippet(item), snippets[item.id] == nil {
                loadSnippet(item, store: store)
            }
        }
    }

    func clear() {
        for task in loads.values { task.cancel() }
        loads = [:]
        loadingPixels = [:]
        loadedPixels = [:]
        pendingThumbnails = [:]
        pendingSnippets = [:]
        if !thumbnails.isEmpty { thumbnails = [:] }
        if !snippets.isEmpty { snippets = [:] }
    }

    private static func wantsThumbnail(_ item: WorkstationItem) -> Bool {
        switch item.kind {
        case .image, .pdf: return item.attachment != nil
        case .stagedChange(let path, _, _, _): return WorkstationItem.isImagePath(path)
        default: return item.isVideo
        }
    }

    private static func wantsSnippet(_ item: WorkstationItem) -> Bool {
        switch item.kind {
        case .textOrCode: return item.attachment != nil
        case .stagedChange(let path, _, _, _): return !WorkstationItem.isImagePath(path)
        default: return false
        }
    }

    private func loadThumbnail(_ item: WorkstationItem, pixels: Int, store: AttachmentStore) {
        let id = item.id
        if let cached = WorkstationCanvasCard.cachedThumbnail(for: item, pixels: pixels) {
            deliver(thumbnail: cached, for: id)
            if ThumbnailPipeline.bucket(for: Int(max(cached.size.width, cached.size.height) * cached.scale)) >= pixels {
                loadedPixels[id] = pixels
                return
            }
        }
        loadingPixels[id] = pixels
        loads[id] = Task { [weak self] in
            let image: UIImage?
            if case .stagedChange(_, let data, _, _) = item.kind {
                image = await ThumbnailPipeline.shared.thumbnail(data: data, key: WorkstationCanvasCard.stagedKey(item), maxPixelSize: pixels)
            } else if let attachment = item.attachment {
                image = await ThumbnailPipeline.shared.thumbnail(for: attachment, store: store, maxPixelSize: pixels)
            } else {
                image = nil
            }
            guard let self, !Task.isCancelled else { return }
            self.loads[id] = nil
            self.loadingPixels[id] = nil
            self.loadedPixels[id] = pixels
            if let image { self.deliver(thumbnail: image, for: id) }
        }
    }

    private func loadSnippet(_ item: WorkstationItem, store: AttachmentStore) {
        let id = item.id
        if let cached = WorkstationSnippetCache.snippet(for: item) {
            deliver(snippet: cached, for: id)
            return
        }
        loads[id] = Task { [weak self] in
            let text = await WorkstationSnippetCache.load(for: item, store: store)
            guard let self, !Task.isCancelled else { return }
            self.loads[id] = nil
            if let text { self.deliver(snippet: text, for: id) }
        }
    }

    private func deliver(thumbnail: UIImage, for id: String) {
        pendingThumbnails[id] = thumbnail
        scheduleFlush()
    }

    private func deliver(snippet: String, for id: String) {
        pendingSnippets[id] = snippet
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        if !pendingThumbnails.isEmpty {
            thumbnails.merge(pendingThumbnails) { _, new in new }
            pendingThumbnails = [:]
        }
        if !pendingSnippets.isEmpty {
            snippets.merge(pendingSnippets) { _, new in new }
            pendingSnippets = [:]
        }
    }
}

// MARK: - Drawn layers

/// Cards between 18% and 45%: one drawing that paints each card in view exactly as a real card
/// looks (it draws the same card face at 100%, scaled). Taps, double taps and drags reach the
/// card under the finger through the board's spatial index.
private struct CanvasLiteCards: View {
    let entries: [CanvasCardEntry]
    let transform: CanvasViewTransform
    let viewport: CGSize
    let selectedID: String?
    let movingCard: CanvasMovingCard?
    let thumbnails: [String: UIImage]
    let snippets: [String: String]

    var body: some View {
        let zoom = transform.zoom
        let origin = transform.origin(in: viewport)
        let width = WorkstationCanvasLayout.cardWidth
        let height = WorkstationCanvasLayout.cardHeight
        Canvas { context, _ in
            for entry in entries {
                guard let face = context.resolveSymbol(id: entry.id) else { continue }
                var x = origin.x + (entry.center.x - width / 2) * zoom
                var y = origin.y + (entry.center.y - height / 2) * zoom
                if let movingCard, movingCard.id == entry.id {
                    x += movingCard.offset.width
                    y += movingCard.offset.height
                }
                var card = context
                card.translateBy(x: x, y: y)
                card.scaleBy(x: zoom, y: zoom)
                card.draw(face, at: .zero, anchor: .topLeading)
            }
        } symbols: {
            ForEach(entries) { entry in
                WorkstationCardFace(
                    item: entry.item,
                    zoom: 1,
                    isSelected: entry.id == selectedID,
                    thumbnail: thumbnails[entry.id],
                    snippet: snippets[entry.id],
                    showsLiveDiagram: false,
                    showsShadow: false
                )
                .equatable()
                .frame(width: width, height: height)
                .tag(entry.id)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
    }
}

private struct OverviewSymbol: Hashable {
    let icon: String
    let tint: WorkstationBadgeTint
}

/// Farther out (below 18%, with more than 24 cards), one drawing paints a miniature of each card
/// in view (icon and name), not a blank bar. Icons are drawn once and reused.
private struct CanvasOverviewMarks: View {
    let entries: [CanvasCardEntry]
    let transform: CanvasViewTransform
    let viewport: CGSize
    let selectedID: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let zoom = transform.zoom
        let origin = transform.origin(in: viewport)
        let isDark = colorScheme == .dark
        let symbols = Self.symbols(for: entries)
        Canvas { context, _ in
            let cardW = max(4, WorkstationCanvasLayout.cardWidth * zoom)
            let cardH = max(4, WorkstationCanvasLayout.cardHeight * zoom)
            let fill = isDark ? Color(white: 0.16) : Color.white.opacity(0.96)
            let ink = isDark ? Color.white.opacity(0.88) : Color.black.opacity(0.78)
            var rects: [CGRect] = []
            rects.reserveCapacity(entries.count)
            var backgrounds = Path()
            var tints: [WorkstationBadgeTint: Path] = [:]
            for entry in entries {
                let cx = origin.x + entry.center.x * zoom
                let cy = origin.y + entry.center.y * zoom
                let rect = CGRect(x: cx - cardW / 2, y: cy - cardH / 2, width: cardW, height: cardH)
                rects.append(rect)
                let radius = max(1, min(rect.width, rect.height) * 0.16)
                backgrounds.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
                let preview = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.70)
                tints[entry.item.badgeTint, default: Path()].addRoundedRect(in: preview, cornerSize: CGSize(width: radius, height: radius))
            }
            context.fill(backgrounds, with: .color(fill))
            for (tint, path) in tints {
                context.fill(path, with: .color(tint.color.opacity(0.16)))
            }
            for (entry, rect) in zip(entries, rects) {
                let preview = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.70)
                let iconSide = min(preview.width, preview.height) * 0.46
                if iconSide >= 3, let icon = context.resolveSymbol(id: OverviewSymbol(icon: entry.item.icon, tint: entry.item.badgeTint)) {
                    let scale = iconSide / max(icon.size.width, icon.size.height, 1)
                    var drawn = context
                    drawn.translateBy(x: preview.midX, y: preview.midY)
                    drawn.scaleBy(x: scale, y: scale)
                    drawn.draw(icon, at: .zero, anchor: .center)
                }
                if rect.height >= 18 {
                    let title = context.resolve(
                        Text(entry.item.name)
                            .font(.system(size: min(11, max(6, rect.height * 0.16)), weight: .semibold))
                            .foregroundColor(ink)
                    )
                    let titleRect = CGRect(
                        x: rect.minX + 3,
                        y: preview.maxY + 1,
                        width: max(1, rect.width - 6),
                        height: max(8, rect.maxY - preview.maxY - 2)
                    )
                    context.draw(title, in: titleRect)
                }
                if entry.id == selectedID {
                    let radius = max(1, min(rect.width, rect.height) * 0.16)
                    context.stroke(Path(roundedRect: rect, cornerRadius: radius), with: .color(entry.item.badgeColor), lineWidth: max(1, 1.5 * zoom))
                }
            }
        } symbols: {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol.icon)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(symbol.tint.color)
                    .tag(symbol)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
    }

    private static func symbols(for entries: [CanvasCardEntry]) -> [OverviewSymbol] {
        var seen = Set<OverviewSymbol>()
        var list: [OverviewSymbol] = []
        for entry in entries {
            let symbol = OverviewSymbol(icon: entry.item.icon, tint: entry.item.badgeTint)
            if seen.insert(symbol).inserted { list.append(symbol) }
        }
        return list
    }
}

private struct CanvasDotGrid: View {
    let pan: CGSize
    let zoom: CGFloat
    let isDark: Bool

    var body: some View {
        Canvas { context, size in
            let baseStep: CGFloat = zoom < 0.2 ? 64 : (zoom < 0.5 ? 36 : 24)
            let step = max(14, baseStep * max(zoom, 0.25))
            let startX = pan.width.truncatingRemainder(dividingBy: step)
            let startY = pan.height.truncatingRemainder(dividingBy: step)
            let dotColor = isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.10)
            var path = Path()
            var x = startX
            while x < size.width {
                var y = startY
                while y < size.height {
                    path.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    y += step
                }
                x += step
            }
            context.fill(path, with: .color(dotColor))
        }
    }
}

// MARK: - Arena-Style Expandable `Files` Folder Tree Tab

private struct WorkstationFilesTab: View {
    let canvas: WorkstationCanvasModel
    @Binding var query: String
    @Binding var expandedFolders: Set<String>
    let repoLoading: Bool
    let computerAvailable: Bool
    let machineName: String
    let computerLoading: Bool
    let computerFileCount: Int
    let onOpen: @MainActor (WorkstationItem) -> Void
    let onAddToChat: @MainActor (WorkstationItem) -> Void
    let onLoadComputer: @MainActor () -> Void

    @Environment(\.theme) private var theme

    private var stagedWorkstationItems: [WorkstationItem] { canvas.stagedItems }

    var body: some View {
        let listing = canvas.listing
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search all files in Workstation…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List {
                if !stagedWorkstationItems.isEmpty {
                    folderSection(id: "staged", title: "staged-changes", icon: "pencil.and.outline", folder: listing.staged, query: listing.query)
                }
                folderSection(id: "uploads", title: "uploads", icon: "tray.and.arrow.up.fill", folder: listing.uploads, query: listing.query)
                folderSection(id: "generated", title: "generated-media", icon: "sparkles.rectangle.stack.fill", folder: listing.generated, query: listing.query)
                if !canvas.diagramItems.isEmpty {
                    folderSection(id: "diagrams", title: "diagrams", icon: "point.3.connected.trianglepath.dotted", folder: listing.diagrams, query: listing.query)
                }
                if let repo = canvas.activeRepo {
                    Section {
                        folderToggle(id: "repo") {
                            folderHeaderLabel(
                                title: repo.ref.name,
                                subtitle: "\(canvas.repoItems.count) files · \(repo.branch)",
                                icon: "chevron.left.forwardslash.chevron.right"
                            )
                        }
                        if expandedFolders.contains("repo") {
                            if repoLoading {
                                HStack { ProgressView(); Text("Loading \(repo.ref.name)…").font(.footnote) }
                            } else if listing.repo.items.isEmpty {
                                Text("No matching files on \(repo.branch).")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryText)
                            } else {
                                // Every file, however many: the list only builds the rows on screen.
                                ForEach(listing.repo.items) { item in
                                    fileRow(item)
                                }
                            }
                        }
                    }
                }
                if computerAvailable {
                    Section {
                        folderToggle(id: "computer") {
                            folderHeaderLabel(
                                title: machineName,
                                subtitle: computerFileCount == 0 ? "Tap to inspect computer workspace" : "\(computerFileCount) items",
                                icon: "desktopcomputer"
                            )
                        } accessory: {
                            Button {
                                onLoadComputer()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.plain)
                        }
                        if expandedFolders.contains("computer") {
                            if computerLoading {
                                HStack { ProgressView(); Text("Checking Linux computer…").font(.footnote) }
                            } else if computerFileCount == 0 {
                                Button {
                                    onLoadComputer()
                                } label: {
                                    Label("Load files from \(machineName)", systemImage: "terminal")
                                        .font(.footnote.weight(.semibold))
                                }
                            } else {
                                ForEach(listing.computer.items) { item in
                                    fileRow(item)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .task(id: query) {
            // Search once the typing pauses; clearing the field shows everything at once.
            let pending = query
            if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            canvas.setFileQuery(pending)
        }
    }

    @ViewBuilder
    private func folderSection(id: String, title: String, icon: String, folder: WorkstationFolder, query: String) -> some View {
        if !folder.items.isEmpty || query.isEmpty {
            Section {
                folderToggle(id: id) {
                    folderHeaderLabel(title: title, subtitle: folder.summary, icon: icon)
                }
                if expandedFolders.contains(id) {
                    if folder.items.isEmpty {
                        Text("Empty")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(folder.items) { item in
                            fileRow(item)
                        }
                    }
                }
            }
        }
    }

    /// A folder's header row: tap to open or close it. Its files are the section's own rows, so
    /// the list builds only the ones on screen even for a repo of thousands of files.
    private func folderToggle<Title: View>(id: String, @ViewBuilder label: () -> Title) -> some View {
        folderToggle(id: id, label: label) { EmptyView() }
    }

    private func folderToggle<Title: View, Accessory: View>(
        id: String,
        @ViewBuilder label: () -> Title,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        let isOpen = expandedFolders.contains(id)
        return HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    toggleFolder(id)
                }
            } label: {
                HStack(spacing: 8) {
                    label()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            accessory()
        }
    }

    private func toggleFolder(_ id: String) {
        if expandedFolders.contains(id) {
            expandedFolders.remove(id)
        } else {
            expandedFolders.insert(id)
        }
    }

    private func folderHeaderLabel(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(subtitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func fileRow(_ item: WorkstationItem) -> some View {
        Button {
            onOpen(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.badgeColor)
                    .frame(width: 24, height: 24)
                    .background(item.badgeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onAddToChat(item)
                } label: {
                    Image(systemName: "plus.bubble")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(item.name) to chat")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Kiro-Style `Changes` / Reviews Tab

private struct WorkstationChangesTab: View {
    let session: ChatSession?
    /// Kept by the screen, so "Whole branch" stays picked across tab switches.
    @Binding var diffScope: Int
    @Binding var diffText: String

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    if let receipt = session.chat.saveReceipts?.last {
                        HStack(spacing: 10) {
                            if receipt.pullRequest != nil, receipt.resolution == nil {
                                Button("Add it") { Task { await session.addLastSave() } }
                                    .buttonStyle(.borderedProminent)
                                Button("Throw away", role: .destructive) { Task { await session.throwAwayLastSave() } }
                                    .buttonStyle(.bordered)
                            }
                            if receipt.undoneAt == nil, receipt.resolution == nil {
                                Button("Undo") { Task { await session.undoLastSave() } }
                                    .buttonStyle(.bordered)
                            }
                            if let status = session.mergeCheckStatus {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(status == "Checks passed" || status == "No automatic checks" ? .green : .orange)
                            }
                            Spacer()
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }

                    Picker("Changes", selection: $diffScope) {
                        Text("This turn").tag(0)
                        Text("Whole branch").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(16)

                    ScrollView {
                        CodeBlockView(language: "diff", code: diffText)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                    }
                }
                .task(id: diffScope) {
                    diffText = "Loading changes…"
                    diffText = diffScope == 0 ? await session.stagedDiff() : await session.branchDiff()
                }
            } else {
                ContentUnavailableView(
                    "No active chat changes",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Start a chat with a connected GitHub repo to review diffs and pull requests here.")
                )
            }
        }
    }
}

// MARK: - Preview sheet

private struct WorkstationItemPreviewSheet: View {
    let item: WorkstationItem
    let repo: ChatRepo?
    let repoCommit: String?
    var onAddToChat: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var attachmentData: Data?
    @State private var attachmentFileURL: URL?
    @State private var attachmentImage: UIImage?
    @State private var repoText: String?
    @State private var repoImage: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if let att = item.attachment {
                    if loading {
                        ProgressView("Opening \(item.name)…")
                    } else if let attachmentImage {
                        ZoomableImageCanvas(image: attachmentImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if (att.kind == .pdf || att.name.lowercased().hasSuffix(".pdf")), let attachmentFileURL {
                        PDFInlineReaderView(url: attachmentFileURL)
                    } else if let attachmentData {
                        AttachmentDataPreviewBody(
                            name: att.name,
                            kind: att.kind,
                            bytes: att.bytes,
                            data: attachmentData,
                            shareURL: attachmentFileURL
                        )
                    } else {
                        ContentUnavailableView("File unavailable", systemImage: "doc.badge.exclamationmark")
                    }
                } else if case .mermaid(let code) = item.kind {
                    ScrollView {
                        MermaidBlockView(code: code)
                            .padding(16)
                    }
                } else if let repoImage {
                    ZoomableImageCanvas(image: repoImage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let repoText {
                    ScrollView {
                        let lowerItemName = item.name.lowercased()
                        if lowerItemName.hasSuffix(".md") {
                            MarkdownView(text: repoText).padding(16)
                        } else if lowerItemName.hasSuffix(".mmd") || lowerItemName.hasSuffix(".mermaid") {
                            MermaidBlockView(code: repoText).padding(16)
                        } else {
                            CodeBlockView(language: (item.name as NSString).pathExtension, code: repoText).padding(16)
                        }
                    }
                } else if loading {
                    ProgressView("Loading \(item.name)…")
                } else {
                    ContentUnavailableView(item.name, systemImage: item.icon, description: Text(item.subtitle))
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        onAddToChat()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .accessibilityLabel("Add to chat")

                    if let att = item.attachment, attachmentFileURL != nil {
                        Button {
                            Task {
                                if let url = await ShareableAttachmentURL.prepare(attachment: att, store: app.attachmentStore) {
                                    SharePresenter.present(items: [url])
                                }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share or save")
                    }
                }
            }
            .task {
                await loadPreview()
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func loadPreview() async {
        defer { loading = false }
        if let att = item.attachment {
            if let resolvedURL = try? app.attachmentStore.fileURL(for: att),
               FileManager.default.fileExists(atPath: resolvedURL.path) {
                attachmentFileURL = resolvedURL
                if att.kind == .image {
                    attachmentImage = await ThumbnailPipeline.shared.thumbnail(for: att, store: app.attachmentStore, maxPixelSize: 2_400)
                } else if att.kind != .pdf && !att.name.lowercased().hasSuffix(".pdf") {
                    attachmentData = (try? await app.attachmentStore.readSlice(for: att, offsetBytes: 0, maxBytes: 256_000))?.data
                }
            }
            return
        }
        if case .stagedChange(let path, let data, _, _) = item.kind {
            if WorkstationItem.isImagePath(path) {
                repoImage = await ThumbnailPipeline.shared.thumbnail(data: data, key: "staged-full-\(item.id)-\(item.revision)", maxPixelSize: 2_048)
            } else {
                repoText = String(data: data, encoding: .utf8) ?? "Binary staged file (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."
            }
            return
        }
        if case .repoFile(let path) = item.kind, let repo, let github = app.repoClient(for: repo.ref) {
            do {
                let commit = if let repoCommit { repoCommit } else { try await github.resolveCommit(repo.ref, ref: repo.branch) }
                let ws = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
                switch try await ws.readFile(path) {
                case .text(let value, _):
                    repoText = value
                case .binary where WorkstationItem.isImagePath(path):
                    let data = try await github.fileContents(repo.ref, path: path, ref: commit)
                    repoImage = await ThumbnailPipeline.shared.thumbnail(data: data, key: "repo-\(commit)-\(path)", maxPixelSize: 2_048)
                case .binary:
                    repoText = "Binary file (\(item.subtitle))."
                case .tooLarge:
                    repoText = "This file is too large to preview inline."
                case .symlink(let dest):
                    repoText = "Symlink → \(dest)"
                case .folder, .missing:
                    repoText = "File unavailable."
                }
            } catch {
                repoText = "Couldn't read \(path): \(error.localizedDescription)"
            }
            return
        }
        if case .computerFile(let path) = item.kind, let control = app.connectors.computerControl() {
            repoText = try? await control.run("head -c 60000 -- \(shellSingleQuote(path))")
        }
    }

    private func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
