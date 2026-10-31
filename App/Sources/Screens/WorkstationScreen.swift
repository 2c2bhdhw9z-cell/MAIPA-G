import AgentCore
import PDFKit
import PhotosUI
import SwiftUI
import UIKit

/// Unified Workstation combining Runable's infinite pan-and-zoom Canvas (upgraded to display EVERY
/// file type, not just images), Arena's Workspace folder tree, and Kiro's Changes/Reviews diff panel.
struct WorkstationScreen: View {
    enum Tab: String, CaseIterable, Identifiable {
        case canvas = "Canvas"
        case files = "Files"
        case changes = "Changes"
        case workflows = "Workflows"
        var id: String { rawValue }
    }

    enum CanvasTool: String {
        case pointer
        case hand
    }

    let target: ComposerTarget
    var initialTab: Tab = .canvas

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var tab: Tab = .canvas
    @State private var tool: CanvasTool = .pointer
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var dragPanDelta: CGSize = .zero
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectedItemID: String?
    @State private var previewingItem: WorkstationItem?

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

    @State private var diffScope = 0
    @State private var diffText = "Loading changes…"
    @State private var workflowSteerDrafts: [String: String] = [:]
    @State private var showingWorkflowsLibrary = false

    private static let zoomSteps: [CGFloat] = [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 1.0, 1.5, 2.0, 3.0]

    private var session: ChatSession? {
        if case .chat(let id) = target { return app.library.session(id) }
        return nil
    }

    private var activeRepo: ChatRepo? {
        app.repo(for: target)
    }

    private var storageKey: String {
        switch target {
        case .home: return "workstation.layout.home"
        case .chat(let id): return "workstation.layout.\(id.uuidString)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topHeader
            Divider().opacity(0.6)

            switch tab {
            case .canvas:
                canvasWorkspace
            case .files:
                filesWorkspace
            case .changes:
                changesWorkspace
            case .workflows:
                workflowsWorkspace
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            tab = initialTab
            loadSavedPositions()
        }
        .task(id: session?.chat.updatedAt) {
            if let session {
                stagedChanges = await session.currentStagedChanges()
            }
        }
        .task(id: activeRepo) {
            await loadRepoTreeIfNeeded()
        }
        .onChange(of: photoItems) { _, picked in
            guard !picked.isEmpty else { return }
            photoItems = []
            importPickedPhotos(picked)
        }
        .sheet(item: $previewingItem) { item in
            WorkstationItemPreviewSheet(
                item: item,
                repo: activeRepo,
                repoCommit: repoCommit,
                onAddToChat: { addItemToChat(item) }
            )
        }
        .sheet(isPresented: $showingWorkflowsLibrary) {
            WorkflowsScreen()
        }
        .alert("Workstation", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Top Header (`Canvas | Files | Changes`)

    private var topHeader: some View {
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

                Text("\(allItems.count) \(allItems.count == 1 ? "item" : "items") · \(formattedTotalBytes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)

                if !exportableAttachments.isEmpty {
                    Button {
                        exportAllLocalAttachments()
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
                    dismiss()
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
                tabButton(.canvas, badge: canvasItems.count)
                tabButton(.files, badge: allItems.count)
                tabButton(.changes, badge: pendingChangesCount)
                tabButton(.workflows, badge: session?.activeWorkflowRuns.count ?? 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.surface.opacity(0.6))
    }

    private func tabButton(_ candidate: Tab, badge: Int) -> some View {
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

    // MARK: - Infinite Pan & Zoom Canvas Tab (All File Types)

    private var canvasWorkspace: some View {
        GeometryReader { geo in
            let items = canvasItems
            let effectivePan = CGSize(
                width: pan.width + dragPanDelta.width,
                height: pan.height + dragPanDelta.height
            )

            ZStack {
                CanvasDotGrid(pan: effectivePan, zoom: zoom, isDark: colorScheme == .dark)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedItemID = nil
                    }
                    .gesture(canvasBackgroundPanGesture)

                if items.isEmpty {
                    emptyCanvasPlaceholder
                } else {
                    ZStack {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let pos = position(for: item.id, index: index)
                            WorkstationCanvasCard(
                                item: item,
                                isSelected: selectedItemID == item.id,
                                pointerEnabled: tool == .pointer,
                                zoom: zoom,
                                onSelect: {
                                    selectedItemID = item.id
                                    Haptics.selection()
                                },
                                onDoubleTap: {
                                    previewingItem = item
                                },
                                onMove: { delta in
                                    let current = position(for: item.id, index: index)
                                    positions[item.id] = CGPoint(
                                        x: current.x + delta.width / max(zoom, 0.01),
                                        y: current.y + delta.height / max(zoom, 0.01)
                                    )
                                },
                                onMoveEnd: {
                                    savePositions()
                                }
                            )
                            .position(
                                x: geo.size.width * 0.5 + effectivePan.width + pos.x * zoom,
                                y: geo.size.height * 0.46 + effectivePan.height + pos.y * zoom
                            )
                        }
                    }
                    .allowsHitTesting(tool == .pointer)
                }

                // Top controls: `Arrange` + `Center` on the left, `[ - | 100% | + ]` zoom pill on the right
                VStack {
                    HStack(spacing: 8) {
                        if !items.isEmpty {
                            HStack(spacing: 2) {
                                Button {
                                    arrangeAllCards(in: geo.size, items: items)
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
                                    centerOnCards(items: items)
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
                        zoomPill(viewport: geo.size, items: items)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                    Spacer()

                    if let selectedID = selectedItemID,
                       let selectedItem = items.first(where: { $0.id == selectedID }) {
                        selectionActionBar(for: selectedItem)
                            .padding(.bottom, 6)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    bottomCanvasDock(viewport: geo.size, items: items)
                        .padding(.bottom, 12)
                }
            }
            .clipped()
            .simultaneousGesture(canvasPinchGesture)
        }
    }

    private var canvasBackgroundPanGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                dragPanDelta = value.translation
            }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
                dragPanDelta = .zero
                saveViewport()
            }
    }

    private var canvasPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                zoom = min(max(baseZoom * scale, 0.01), 3.0)
            }
            .onEnded { _ in
                baseZoom = zoom
                saveViewport()
            }
    }

    private func zoomPill(viewport: CGSize, items: [WorkstationItem]) -> some View {
        HStack(spacing: 0) {
            Button {
                stepZoom(direction: -1)
            } label: {
                Image(systemName: "minus")
                    .font(.caption.weight(.bold))
                    .frame(width: 40, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")

            Button {
                withAnimation(.snappy(duration: 0.25)) {
                    zoom = 1.0
                    baseZoom = 1.0
                    pan = .zero
                }
                saveViewport()
                Haptics.selection()
            } label: {
                Text("\(max(1, Int((zoom * 100).rounded())))%")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 50, minHeight: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset zoom to 100%")

            Button {
                stepZoom(direction: 1)
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

    private func stepZoom(direction: Int) {
        let steps = Self.zoomSteps
        let targetZoom: CGFloat
        if direction < 0 {
            targetZoom = steps.last(where: { $0 < zoom - 0.015 }) ?? steps[0]
        } else {
            targetZoom = steps.first(where: { $0 > zoom + 0.015 }) ?? steps[steps.count - 1]
        }
        withAnimation(.snappy(duration: 0.22)) {
            zoom = targetZoom
            baseZoom = targetZoom
        }
        saveViewport()
        Haptics.selection()
    }

    private static func idealGridColumns(for count: Int) -> Int {
        if count <= 1 { return 1 }
        if count <= 3 { return 2 }
        if count <= 9 { return 3 }
        if count <= 16 { return 4 }
        if count <= 25 { return 5 }
        return min(8, max(5, Int(ceil(sqrt(Double(count) * 1.3)))))
    }

    private func arrangeAllCards(in viewport: CGSize, items: [WorkstationItem]) {
        guard !items.isEmpty else { return }
        positions.removeAll()
        let cols = Self.idealGridColumns(for: items.count)
        let spacingX: CGFloat = 232
        let spacingY: CGFloat = 252
        let originX = -CGFloat(cols - 1) * spacingX * 0.5
        for (idx, item) in items.enumerated() {
            let col = idx % cols
            let row = idx / cols
            positions[item.id] = CGPoint(
                x: originX + CGFloat(col) * spacingX,
                y: CGFloat(row) * spacingY - 60
            )
        }
        savePositions()

        var minX: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = -.greatestFiniteMagnitude
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxY: CGFloat = -.greatestFiniteMagnitude
        for (idx, item) in items.enumerated() {
            let p = position(for: item.id, index: idx)
            minX = min(minX, p.x - 115)
            maxX = max(maxX, p.x + 115)
            minY = min(minY, p.y - 130)
            maxY = max(maxY, p.y + 130)
        }
        let spanW = max(240, maxX - minX)
        let spanH = max(260, maxY - minY)
        let scaleX = max(0.18, (viewport.width - 36) / spanW)
        let scaleY = max(0.18, (viewport.height - 150) / spanH)
        let fitted = min(max(min(scaleX, scaleY), 0.20), 1.0)
        let midX = (minX + maxX) * 0.5
        let midY = (minY + maxY) * 0.5
        withAnimation(.snappy(duration: 0.28)) {
            zoom = fitted
            baseZoom = fitted
            pan = CGSize(width: -midX * fitted, height: -midY * fitted)
        }
        saveViewport()
        Haptics.selection()
    }

    private func centerOnCards(items: [WorkstationItem]) {
        guard !items.isEmpty else {
            withAnimation(.snappy(duration: 0.25)) { pan = .zero }
            saveViewport()
            return
        }
        var minX: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = -.greatestFiniteMagnitude
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxY: CGFloat = -.greatestFiniteMagnitude
        for (idx, item) in items.enumerated() {
            let p = position(for: item.id, index: idx)
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        let midX = (minX + maxX) * 0.5
        let midY = (minY + maxY) * 0.5
        let comfortableZoom = min(max(zoom, 0.45), 1.25)
        withAnimation(.snappy(duration: 0.25)) {
            zoom = comfortableZoom
            baseZoom = comfortableZoom
            pan = CGSize(width: -midX * comfortableZoom, height: -midY * comfortableZoom)
        }
        saveViewport()
        Haptics.selection()
    }

    private func selectionActionBar(for item: WorkstationItem) -> some View {
        HStack(spacing: 6) {
            Button {
                previewingItem = item
            } label: {
                Label("Open", systemImage: "eye")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                addItemToChat(item)
            } label: {
                Label("Add to chat", systemImage: "plus.bubble")
                    .padding(.horizontal, 8)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if item.attachment != nil {
                Button {
                    shareItem(item)
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
                    removeDraftItem(item)
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

    private func bottomCanvasDock(viewport: CGSize, items: [WorkstationItem]) -> some View {
        HStack(spacing: 6) {
            dockButton(icon: "cursorarrow", active: tool == .pointer, label: "Select & move cards") {
                tool = .pointer
                Haptics.selection()
            }
            dockButton(icon: "hand.raised", active: tool == .hand, label: "Pan canvas") {
                tool = .hand
                Haptics.selection()
            }
            Divider().frame(height: 22).padding(.horizontal, 2)
            dockButton(icon: "plus", active: false, label: "Add any file") {
                Haptics.selection()
                pickFilesForWorkstation()
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

            if !items.isEmpty {
                dockButton(icon: "square.grid.2x2", active: false, label: "Arrange cards into grid") {
                    arrangeAllCards(in: viewport, items: items)
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
                    pickFilesForWorkstation()
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

    // MARK: - Arena-Style Expandable `Files` Folder Tree Tab

    private var filesWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search all files in Workstation…", text: $fileQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !fileQuery.isEmpty {
                    Button { fileQuery = "" } label: {
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
                    folderSection(
                        id: "staged",
                        title: "staged-changes",
                        icon: "pencil.and.outline",
                        items: filteredItems(stagedWorkstationItems)
                    )
                }
                folderSection(
                    id: "uploads",
                    title: "uploads",
                    icon: "tray.and.arrow.up.fill",
                    items: filteredItems(uploadItems)
                )
                folderSection(
                    id: "generated",
                    title: "generated-media",
                    icon: "sparkles.rectangle.stack.fill",
                    items: filteredItems(generatedItems)
                )
                if !diagramItems.isEmpty {
                    folderSection(
                        id: "diagrams",
                        title: "diagrams",
                        icon: "point.3.connected.trianglepath.dotted",
                        items: filteredItems(diagramItems)
                    )
                }
                if let repo = activeRepo {
                    Section {
                        DisclosureGroup(isExpanded: bindingForFolder("repo")) {
                            if repoLoading {
                                HStack { ProgressView(); Text("Loading \(repo.ref.name)…").font(.footnote) }
                            } else {
                                let items = filteredItems(repoWorkstationItems)
                                if items.isEmpty {
                                    Text("No matching files on \(repo.branch).")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.secondaryText)
                                } else {
                                    ForEach(items.prefix(250)) { item in
                                        fileRow(item)
                                    }
                                }
                            }
                        } label: {
                            folderHeaderLabel(
                                title: repo.ref.name,
                                subtitle: "\(repoEntries.filter(\.isFile).count) files · \(repo.branch)",
                                icon: "chevron.left.forwardslash.chevron.right"
                            )
                        }
                    }
                }
                if app.connectors.computerControl() != nil {
                    Section {
                        DisclosureGroup(isExpanded: bindingForFolder("computer")) {
                            if computerLoading {
                                HStack { ProgressView(); Text("Checking Linux computer…").font(.footnote) }
                            } else if computerFiles.isEmpty {
                                Button {
                                    Task { await loadComputerFiles() }
                                } label: {
                                    Label("Load files from \(app.settings.chatComputerMachineName)", systemImage: "terminal")
                                        .font(.footnote.weight(.semibold))
                                }
                            } else {
                                ForEach(filteredItems(computerWorkstationItems)) { item in
                                    fileRow(item)
                                }
                            }
                        } label: {
                            HStack {
                                folderHeaderLabel(
                                    title: app.settings.chatComputerMachineName,
                                    subtitle: computerFiles.isEmpty ? "Tap to inspect computer workspace" : "\(computerFiles.count) items",
                                    icon: "desktopcomputer"
                                )
                                Spacer()
                                Button {
                                    Task { await loadComputerFiles() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func folderSection(id: String, title: String, icon: String, items: [WorkstationItem]) -> some View {
        if !items.isEmpty || fileQuery.isEmpty {
            Section {
                DisclosureGroup(isExpanded: bindingForFolder(id)) {
                    if items.isEmpty {
                        Text("Empty")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(items) { item in
                            fileRow(item)
                        }
                    }
                } label: {
                    let bytes = items.reduce(0) { $0 + $1.bytes }
                    let sizeText = bytes > 0 ? " · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" : ""
                    folderHeaderLabel(
                        title: title,
                        subtitle: "\(items.count) \(items.count == 1 ? "file" : "files")\(sizeText)",
                        icon: icon
                    )
                }
            }
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
            previewingItem = item
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
                    addItemToChat(item)
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

    private func bindingForFolder(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolders.contains(id) },
            set: { open in
                if open { expandedFolders.insert(id) }
                else { expandedFolders.remove(id) }
            }
        )
    }

    // MARK: - Kiro-Style `Changes` / Reviews Tab

    private var changesWorkspace: some View {
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

    // MARK: - Kiro Workflows Tab (Live Step Tree, Transcript, Steer, & Stopped-State Model Switcher)

    private var workflowsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chat Workflows")
                            .font(.rounded(.headline, weight: .bold))
                        Text("Inspect live step trees, steer active runs, or switch the default AI while paused.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        showingWorkflowsLibrary = true
                    } label: {
                        Label("Library", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }

                if let session, !session.activeWorkflowRuns.isEmpty {
                    ActiveWorkflowsInlineCard(
                        runs: session.activeWorkflowRuns,
                        onPause: { session.pauseWorkflowRun($0) },
                        onResume: { id, ans in session.resumeWorkflowRun(id, answer: ans) },
                        onStop: { session.stopWorkflowRun($0) },
                        onRetry: { session.retryWorkflowRun($0) },
                        onOpenWorkstation: {}
                    )

                    ForEach(session.activeWorkflowRuns) { run in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(run.definition.name) · Controls & Transcript")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if let defaultModel = run.checkpoint.defaultModelID {
                                    Text(app.openRouter.displayName(forModelID: defaultModel))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(theme.accent)
                                }
                            }

                            if !run.isRunning {
                                let candidateModels = (app.openRouter.models).filter { !$0.isFree && $0.id != ModelChoice.freeID }.prefix(24)
                                if !candidateModels.isEmpty {
                                    Menu {
                                        ForEach(Array(candidateModels)) { model in
                                            Button {
                                                session.setWorkflowRunModel(run.id, modelID: model.id, effort: .max)
                                            } label: {
                                                Text(model.shortName)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "cpu")
                                                .foregroundStyle(theme.accent)
                                            Text("Switch default AI: \(app.openRouter.displayName(forModelID: run.checkpoint.defaultModelID ?? ModelChoice.autoID))")
                                                .font(.caption.weight(.semibold))
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Theme.raised, in: Capsule())
                                        .overlay(Capsule().strokeBorder(Theme.stroke))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            HStack(spacing: 8) {
                                TextField(
                                    "Steer the agent for upcoming steps…",
                                    text: Binding(
                                        get: { workflowSteerDrafts[run.id] ?? "" },
                                        set: { workflowSteerDrafts[run.id] = $0 }
                                    )
                                )
                                .font(.footnote)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))

                                Button("Steer") {
                                    let note = (workflowSteerDrafts[run.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !note.isEmpty else { return }
                                    session.steerWorkflowRun(run.id, note: note)
                                    workflowSteerDrafts[run.id] = ""
                                    Haptics.selection()
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderedProminent)
                                .buttonBorderShape(.capsule)
                            }

                            if !run.checkpoint.steeringNotes.isEmpty {
                                Text("Active steering notes: " + run.checkpoint.steeringNotes.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondaryText)
                            }

                            if !run.checkpoint.outputs.isEmpty {
                                Divider()
                                Text("Step Outputs (\(run.checkpoint.outputs.count))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryText)
                                ForEach(Array(run.checkpoint.outputs.enumerated()), id: \.offset) { _, output in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(output.title)
                                                .font(.caption.weight(.bold))
                                            if let model = output.model {
                                                Text("· \(app.openRouter.displayName(forModelID: model))")
                                                    .font(.caption2)
                                                    .foregroundStyle(Theme.secondaryText)
                                            }
                                            Spacer()
                                        }
                                        Text(String(output.text.prefix(1_600)))
                                            .font(.caption)
                                            .foregroundStyle(.primary.opacity(0.9))
                                            .textSelection(.enabled)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            }
                        }
                        .padding(12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
                    }
                } else {
                    ContentUnavailableView(
                        "No active workflows in this chat",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Ask the AI to design or run a multi-step workflow, or open the Workflows library.")
                    )
                    .padding(.vertical, 28)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Data Aggregation Across Attachments, Generated Media, Diagrams, Repo, & Computer

    private var uploadItems: [WorkstationItem] {
        var seen: Set<UUID> = []
        var list: [WorkstationItem] = []

        for att in localAddedAttachments where !seen.contains(att.id) {
            seen.insert(att.id)
            list.append(WorkstationItem.fromAttachment(att, source: "Draft upload", removableDraft: true))
        }

        if let session {
            for att in session.workstationFiles where !seen.contains(att.id) {
                seen.insert(att.id)
                list.append(WorkstationItem.fromAttachment(att, source: "Workstation artifact", removableDraft: false))
            }
            for att in session.draftAttachments where !seen.contains(att.id) {
                seen.insert(att.id)
                list.append(WorkstationItem.fromAttachment(att, source: "Draft upload", removableDraft: true))
            }
            for msg in session.chat.messages {
                if case .user(let u) = msg.body {
                    for att in u.attachments where !seen.contains(att.id) {
                        seen.insert(att.id)
                        list.append(WorkstationItem.fromAttachment(att, source: "Chat upload", removableDraft: false))
                    }
                }
            }
        } else {
            for att in app.home.attachments where !seen.contains(att.id) {
                seen.insert(att.id)
                list.append(WorkstationItem.fromAttachment(att, source: "Draft upload", removableDraft: true))
            }
        }
        return list
    }

    private var generatedItems: [WorkstationItem] {
        guard let session else { return [] }
        var list: [WorkstationItem] = []
        for msg in session.chat.messages {
            guard let turn = msg.assistantTurn else { continue }
            for step in turn.steps {
                for img in step.generatedImages ?? [] {
                    list.append(WorkstationItem.fromAttachment(img.attachment, source: "Generated picture", removableDraft: false))
                }
            }
        }
        return list
    }

    private var diagramItems: [WorkstationItem] {
        guard let session else { return [] }
        var list: [WorkstationItem] = []
        var idx = 1
        for msg in session.chat.messages {
            guard let turn = msg.assistantTurn else { continue }
            for step in turn.steps {
                let blocks = Self.extractMermaidBlocks(from: step.text)
                for code in blocks {
                    list.append(WorkstationItem(
                        id: "mermaid-\(step.id.uuidString)-\(idx)",
                        name: "Diagram \(idx).mmd",
                        subtitle: "Mermaid chart · \(code.count) chars",
                        bytes: code.utf8.count,
                        kind: .mermaid(code),
                        attachment: nil,
                        repoPath: nil,
                        isRemovableDraft: false
                    ))
                    idx += 1
                }
            }
        }
        return list
    }

    private var stagedWorkstationItems: [WorkstationItem] {
        stagedChanges.map { change in
            let fileName = change.path.split(separator: "/").last.map(String.init) ?? change.path
            switch change {
            case .write(let path, let data, let existed):
                return WorkstationItem(
                    id: "staged:\(path)",
                    name: fileName,
                    subtitle: "\(existed ? "Edited" : "Created") · \(path)",
                    bytes: data.count,
                    kind: .stagedChange(path: path, data: data, isDelete: false, existed: existed),
                    attachment: nil,
                    repoPath: path,
                    isRemovableDraft: false
                )
            case .delete(let path, let previous):
                return WorkstationItem(
                    id: "staged:\(path)",
                    name: fileName,
                    subtitle: "Deleted · \(path)",
                    bytes: previous.count,
                    kind: .stagedChange(path: path, data: previous, isDelete: true, existed: true),
                    attachment: nil,
                    repoPath: path,
                    isRemovableDraft: false
                )
            }
        }
    }

    private var repoWorkstationItems: [WorkstationItem] {
        guard let repo = activeRepo else { return [] }
        return repoEntries.filter(\.isFile).map { entry in
            let fileName = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            return WorkstationItem(
                id: "repo:\(entry.path)",
                name: fileName,
                subtitle: "\(repo.ref.name)/\(entry.path)",
                bytes: entry.size ?? 0,
                kind: .repoFile(entry.path),
                attachment: nil,
                repoPath: entry.path,
                isRemovableDraft: false
            )
        }
    }

    private var computerWorkstationItems: [WorkstationItem] {
        computerFiles.map { path in
            let fileName = path.split(separator: "/").last.map(String.init) ?? path
            return WorkstationItem(
                id: "computer:\(path)",
                name: fileName,
                subtitle: "\(app.settings.chatComputerMachineName):\(path)",
                bytes: 0,
                kind: .computerFile(path),
                attachment: nil,
                repoPath: nil,
                isRemovableDraft: false
            )
        }
    }

    /// Items placed visually on the Canvas: staged changes, all uploads (every format!), generated pictures,
    /// Mermaid diagrams, and up to 24 key repo files so even a 2,000-file repo stays snappy.
    private var canvasItems: [WorkstationItem] {
        let stagedPaths = Set(stagedWorkstationItems.compactMap(\.repoPath))
        var combined = stagedWorkstationItems + uploadItems + generatedItems + diagramItems
        if combined.count < 40 {
            combined += Array(repoWorkstationItems.filter { item in
                guard let p = item.repoPath else { return true }
                return !stagedPaths.contains(p)
            }.prefix(24))
        }
        return combined
    }

    private var allItems: [WorkstationItem] {
        stagedWorkstationItems + uploadItems + generatedItems + diagramItems + repoWorkstationItems + computerWorkstationItems
    }

    private var exportableAttachments: [AttachmentReference] {
        (uploadItems + generatedItems).compactMap(\.attachment)
    }

    private var formattedTotalBytes: String {
        let total = allItems.reduce(0) { $0 + $1.bytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private var pendingChangesCount: Int {
        if !stagedChanges.isEmpty { return stagedChanges.count }
        guard let session else { return 0 }
        if let receipt = session.chat.saveReceipts?.last, receipt.resolution == nil, receipt.undoneAt == nil {
            return 1
        }
        return 0
    }

    private func filteredItems(_ source: [WorkstationItem]) -> [WorkstationItem] {
        let q = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return source }
        return source.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    private static func extractMermaidBlocks(from markdown: String) -> [String] {
        guard markdown.contains("```mermaid") || markdown.contains("```mmd") else { return [] }
        var results: [String] = []
        let lines = markdown.components(separatedBy: .newlines)
        var inside = false
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if !inside && (trimmed == "```mermaid" || trimmed == "```mmd") {
                inside = true
                current = []
            } else if inside && trimmed == "```" {
                inside = false
                let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { results.append(joined) }
            } else if inside {
                current.append(line)
            }
        }
        return results
    }

    // MARK: - Positions & Actions

    private func position(for id: String, index: Int) -> CGPoint {
        if let saved = positions[id] { return saved }
        let cols = Self.idealGridColumns(for: max(1, canvasItems.count))
        let col = index % cols
        let row = index / cols
        let spacingX: CGFloat = 236
        let spacingY: CGFloat = 258
        let originX = -CGFloat(cols - 1) * spacingX * 0.5
        return CGPoint(x: originX + CGFloat(col) * spacingX, y: CGFloat(row) * spacingY - 90)
    }

    private func loadSavedPositions() {
        if let vp = UserDefaults.standard.array(forKey: "\(storageKey).viewport") as? [Double], vp.count == 3 {
            let savedZoom = min(max(CGFloat(vp[0]), 0.01), 3.0)
            zoom = savedZoom
            baseZoom = savedZoom
            pan = CGSize(width: vp[1], height: vp[2])
        }
        guard let raw = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Double]] else { return }
        var loaded: [String: CGPoint] = [:]
        for (k, pair) in raw where pair.count == 2 {
            loaded[k] = CGPoint(x: pair[0], y: pair[1])
        }
        positions = loaded
    }

    private func saveViewport() {
        UserDefaults.standard.set([Double(zoom), Double(pan.width), Double(pan.height)], forKey: "\(storageKey).viewport")
    }

    private func savePositions() {
        var encoded: [String: [Double]] = [:]
        for (k, pt) in positions {
            encoded[k] = [Double(pt.x), Double(pt.y)]
        }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

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
        if let path = item.repoPath, let repo = activeRepo {
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
        if selectedItemID == item.id { selectedItemID = nil }
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
        let items = exportableAttachments
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
            var idx = uploadItems.filter { $0.attachment?.kind == .image }.count + 1
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
        guard let repo = activeRepo, let github = app.github.client else {
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

// MARK: - Workstation Item Model & Universal Visual Canvas Card

struct WorkstationItem: Identifiable, Hashable {
    enum ItemKind: Hashable {
        case image
        case pdf
        case textOrCode
        case archiveOrBinary(String)
        case mermaid(String)
        case stagedChange(path: String, data: Data, isDelete: Bool, existed: Bool)
        case repoFile(String)
        case computerFile(String)
    }

    let id: String
    let name: String
    let subtitle: String
    let bytes: Int
    let kind: ItemKind
    let attachment: AttachmentReference?
    let repoPath: String?
    let isRemovableDraft: Bool

    static func fromAttachment(_ att: AttachmentReference, source: String, removableDraft: Bool) -> WorkstationItem {
        let ext = (att.name as NSString).pathExtension.lowercased()
        let itemKind: ItemKind
        if att.kind == .image {
            itemKind = .image
        } else if att.kind == .pdf || ext == "pdf" {
            itemKind = .pdf
        } else if att.kind == .text || ["md", "txt", "json", "swift", "py", "js", "ts", "yml", "yaml", "html", "css", "sh", "ips", "csv", "log", "xml"].contains(ext) {
            itemKind = .textOrCode
        } else {
            itemKind = .archiveOrBinary(ext.isEmpty ? "FILE" : ext.uppercased())
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(att.bytes), countStyle: .file)
        return WorkstationItem(
            id: "att:\(att.id.uuidString)",
            name: att.name,
            subtitle: "\(source) · \(sizeStr)",
            bytes: att.bytes,
            kind: itemKind,
            attachment: att,
            repoPath: nil,
            isRemovableDraft: removableDraft
        )
    }

    var icon: String {
        switch kind {
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .textOrCode: return "doc.text.fill"
        case .archiveOrBinary(let ext):
            if ["ZIP", "IPA", "TAR", "GZ"].contains(ext) { return "doc.zipper" }
            if ["P12", "CER", "MOBILEPROVISION"].contains(ext) { return "key.fill" }
            if ["DOCX", "XLSX", "PPTX"].contains(ext) { return "doc.viewfinder" }
            return "shippingbox.fill"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        case .stagedChange(_, _, let isDelete, let existed):
            return isDelete ? "trash.fill" : (existed ? "pencil.line" : "doc.badge.plus")
        case .repoFile: return "chevron.left.forwardslash.chevron.right"
        case .computerFile: return "terminal.fill"
        }
    }

    var badgeText: String {
        if case .stagedChange(_, _, let isDelete, let existed) = kind {
            return isDelete ? "DEL" : (existed ? "EDIT" : "NEW")
        }
        let ext = (name as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        switch kind {
        case .image: return "IMG"
        case .pdf: return "PDF"
        case .textOrCode: return "TXT"
        case .archiveOrBinary(let label): return label
        case .mermaid: return "CHART"
        case .stagedChange: return "EDIT"
        case .repoFile: return "REPO"
        case .computerFile: return "VM"
        }
    }

    var badgeColor: Color {
        switch kind {
        case .image: return .blue
        case .pdf: return .red
        case .textOrCode: return .mint
        case .archiveOrBinary: return .orange
        case .mermaid: return .purple
        case .stagedChange(_, _, let isDelete, let existed):
            return isDelete ? .red : (existed ? .orange : .green)
        case .repoFile: return .indigo
        case .computerFile: return .teal
        }
    }
}

private struct WorkstationCanvasCard: View {
    let item: WorkstationItem
    let isSelected: Bool
    let pointerEnabled: Bool
    let zoom: CGFloat
    var onSelect: () -> Void
    var onDoubleTap: () -> Void
    var onMove: (CGSize) -> Void
    var onMoveEnd: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var thumbnail: UIImage?
    @State private var snippet: String?
    @State private var liveDrag: CGSize = .zero

    private let cardWidth: CGFloat = 208
    private let previewHeight: CGFloat = 152

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea
                .frame(width: cardWidth, height: previewHeight)
                .clipped()

            HStack(spacing: 7) {
                Text(item.badgeText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(item.badgeColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: cardWidth, alignment: .leading)
            .background(Theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Theme.stroke, lineWidth: isSelected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.26 : 0.14), radius: isSelected ? 14 : 7, x: 0, y: 4)
        .scaleEffect(zoom)
        .offset(liveDrag)
        .onTapGesture(count: 2, perform: onDoubleTap)
        .onTapGesture(count: 1, perform: onSelect)
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
                    onMove(delta)
                    onMoveEnd()
                }
        )
        .task(id: item.id) {
            if case .stagedChange(let path, let data, _, _) = item.kind {
                let lower = path.lowercased()
                if [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains(where: { lower.hasSuffix($0) }) {
                    thumbnail = ImageDownsampler.image(from: data, maxPixelSize: 640)
                } else if let str = String(data: data, encoding: .utf8) {
                    snippet = String(str.prefix(420))
                }
                return
            }
            guard let att = item.attachment else { return }
            switch item.kind {
            case .image, .pdf:
                thumbnail = await ImageDownsampler.attachmentThumbnail(att, store: app.attachmentStore, maxPixelSize: 640)
            case .textOrCode:
                if let slice = (try? await app.attachmentStore.readSlice(for: att, offsetBytes: 0, maxBytes: 8_192))?.data,
                   let str = AttachmentDataPreviewBody.readableText(from: slice, name: att.name) {
                    snippet = String(str.prefix(420))
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            Theme.raised
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardWidth, height: previewHeight)
            } else if case .mermaid(let code) = item.kind {
                MermaidBlockView(code: code, compactCardMode: true)
                    .frame(width: cardWidth, height: previewHeight)
            } else if let snippet {
                if item.name.lowercased().hasSuffix(".mmd") || item.name.lowercased().hasSuffix(".mermaid") {
                    MermaidBlockView(code: snippet, compactCardMode: true)
                        .frame(width: cardWidth, height: previewHeight)
                } else {
                    Text(snippet)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.86))
                        .padding(10)
                        .frame(width: cardWidth, height: previewHeight, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(item.badgeColor)
                    Text(item.badgeText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
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
                    attachmentImage = await ImageDownsampler.attachmentThumbnail(att, store: app.attachmentStore, maxPixelSize: 2_400)
                } else if att.kind != .pdf && !att.name.lowercased().hasSuffix(".pdf") {
                    attachmentData = (try? await app.attachmentStore.readSlice(for: att, offsetBytes: 0, maxBytes: 256_000))?.data
                }
            }
            return
        }
        if case .stagedChange(let path, let data, _, _) = item.kind {
            let lower = path.lowercased()
            if [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains(where: { lower.hasSuffix($0) }) {
                repoImage = ImageDownsampler.image(from: data, maxPixelSize: 2_048)
            } else {
                repoText = String(data: data, encoding: .utf8) ?? "Binary staged file (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))."
            }
            return
        }
        if case .repoFile(let path) = item.kind, let repo, let github = app.github.client {
            do {
                let commit = if let repoCommit { repoCommit } else { try await github.resolveCommit(repo.ref, ref: repo.branch) }
                let ws = RepoWorkspace(repo: repo.ref, branch: repo.branch, commit: commit, github: github, store: app.snapshots)
                let lower = path.lowercased()
                switch try await ws.readFile(path) {
                case .text(let value, _):
                    repoText = value
                case .binary where [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains(where: { lower.hasSuffix($0) }):
                    let data = try await github.fileContents(repo.ref, path: path, ref: commit)
                    repoImage = ImageDownsampler.image(from: data, maxPixelSize: 2_048)
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
