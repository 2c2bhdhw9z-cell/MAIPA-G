import AgentCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Observation

// Everything behind the Workstation that isn't drawing: the item lists, where each card sits,
// which cards are on screen, and how the view moves. None of it uses SwiftUI, so the Canvas can
// redraw for a gesture without rebuilding any of it, and it type-checks without an iPhone.

// MARK: - Items

/// One file on the Workstation: a card on the Canvas and a row in Files.
struct WorkstationItem: Identifiable, Hashable, Sendable {
    enum ItemKind: Hashable, Sendable {
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
    /// Changes whenever anything a card shows changes, so cards and lists compare two numbers
    /// instead of names, subtitles and staged file bytes.
    let revision: Int

    init(
        id: String,
        name: String,
        subtitle: String,
        bytes: Int,
        kind: ItemKind,
        attachment: AttachmentReference?,
        repoPath: String?,
        isRemovableDraft: Bool
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.bytes = bytes
        self.kind = kind
        self.attachment = attachment
        self.repoPath = repoPath
        self.isRemovableDraft = isRemovableDraft
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(subtitle)
        hasher.combine(bytes)
        hasher.combine(isRemovableDraft)
        hasher.combine(repoPath)
        hasher.combine(attachment)
        switch kind {
        case .image: hasher.combine(0)
        case .pdf: hasher.combine(1)
        case .textOrCode: hasher.combine(2)
        case .archiveOrBinary(let label):
            hasher.combine(3)
            hasher.combine(label)
        case .mermaid(let code):
            hasher.combine(4)
            hasher.combine(code)
        case .stagedChange(let path, let data, let isDelete, let existed):
            hasher.combine(5)
            hasher.combine(path)
            hasher.combine(isDelete)
            hasher.combine(existed)
            WorkstationItem.combineContent(of: data, into: &hasher)
        case .repoFile(let path):
            hasher.combine(6)
            hasher.combine(path)
        case .computerFile(let path):
            hasher.combine(7)
            hasher.combine(path)
        }
        revision = hasher.finalize()
    }

    static func == (lhs: WorkstationItem, rhs: WorkstationItem) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(revision)
    }

    /// The size and the first 64 KB: enough to notice any edit a card could show.
    static func combineContent(of data: Data, into hasher: inout Hasher) {
        hasher.combine(data.count)
        data.prefix(65_536).withUnsafeBytes { raw in
            hasher.combine(bytes: raw)
        }
    }

    static let textExtensions: Set<String> = ["md", "txt", "json", "swift", "py", "js", "ts", "yml", "yaml", "html", "css", "sh", "ips", "csv", "log", "xml"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func fromAttachment(_ att: AttachmentReference, source: String, removableDraft: Bool, sizeText: String) -> WorkstationItem {
        let ext = (att.name as NSString).pathExtension.lowercased()
        let itemKind: ItemKind
        if att.kind == .image {
            itemKind = .image
        } else if att.kind == .pdf || ext == "pdf" {
            itemKind = .pdf
        } else if att.kind == .text || textExtensions.contains(ext) {
            itemKind = .textOrCode
        } else {
            itemKind = .archiveOrBinary(ext.isEmpty ? "FILE" : ext.uppercased())
        }
        return WorkstationItem(
            id: "att:\(att.id.uuidString)",
            name: att.name,
            subtitle: "\(source) · \(sizeText)",
            bytes: att.bytes,
            kind: itemKind,
            attachment: att,
            repoPath: nil,
            isRemovableDraft: removableDraft
        )
    }

    /// Staged files whose bytes are a picture.
    static func isImagePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains(where: { lower.hasSuffix($0) })
    }

    /// A video the card can show a frame of.
    var isVideo: Bool {
        guard let attachment else { return false }
        if attachment.mimeType.lowercased().hasPrefix("video/") { return true }
        return Self.videoExtensions.contains((attachment.name as NSString).pathExtension.lowercased())
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

    /// The badge colour, by name; WorkstationScreen turns it into a SwiftUI colour.
    var badgeTint: WorkstationBadgeTint {
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

enum WorkstationBadgeTint: String, Hashable, Sendable, CaseIterable {
    case blue, red, mint, orange, purple, green, indigo, teal
}

// MARK: - What the Workstation is built from

/// Plain copies of everything the Workstation lists. Arrays are copy-on-write, so taking one is cheap.
struct WorkstationSources: Sendable {
    var hasSession = false
    var localAdded: [AttachmentReference] = []
    var workstationFiles: [AttachmentReference] = []
    var draftAttachments: [AttachmentReference] = []
    var homeAttachments: [AttachmentReference] = []
    var messages: [ChatMessage] = []
    var staged: [StagedChange] = []
    var repoName: String?
    var repoCommit: String?
    var repoEntries: [GitTreeEntry] = []
    var machineName = ""
    var computerFiles: [String] = []

    /// One number per group of items, from ids, counts and lengths only: a reply streaming in
    /// changes `diagramText` and nothing else, so no other list is rebuilt for it.
    func signature() -> WorkstationSourceSignature {
        var uploads = Hasher()
        uploads.combine(hasSession)
        Self.combineIDs(localAdded, into: &uploads)
        Self.combineIDs(workstationFiles, into: &uploads)
        Self.combineIDs(draftAttachments, into: &uploads)
        Self.combineIDs(homeAttachments, into: &uploads)
        var generated = Hasher()
        var diagrams = Hasher()
        for message in messages {
            switch message.body {
            case .user(let user):
                guard !user.attachments.isEmpty else { continue }
                uploads.combine(message.id)
                uploads.combine(user.attachments.count)
                uploads.combine(user.attachments.first?.id)
                uploads.combine(user.attachments.last?.id)
            case .assistant(let turn):
                for step in turn.steps {
                    diagrams.combine(step.id)
                    diagrams.combine(step.text.utf8.count)
                    if let images = step.generatedImages, !images.isEmpty {
                        generated.combine(step.id)
                        for image in images {
                            generated.combine(image.attachment.id)
                            generated.combine(image.attachment.bytes)
                            generated.combine(image.attachment.mimeType)
                        }
                    }
                }
            }
        }
        var staged = Hasher()
        staged.combine(self.staged.count)
        for change in self.staged {
            switch change {
            case .write(let path, let data, let existed):
                staged.combine(0)
                staged.combine(path)
                staged.combine(existed)
                WorkstationItem.combineContent(of: data, into: &staged)
            case .delete(let path, let previous):
                staged.combine(1)
                staged.combine(path)
                staged.combine(previous.count)
            }
        }
        var repo = Hasher()
        repo.combine(repoName)
        repo.combine(repoCommit)
        repo.combine(repoEntries.count)
        repo.combine(repoEntries.first?.path)
        repo.combine(repoEntries.last?.path)
        var computer = Hasher()
        computer.combine(machineName)
        computer.combine(computerFiles)
        return WorkstationSourceSignature(
            uploads: uploads.finalize(),
            generated: generated.finalize(),
            diagramText: diagrams.finalize(),
            staged: staged.finalize(),
            repo: repo.finalize(),
            computer: computer.finalize()
        )
    }

    private static func combineIDs(_ attachments: [AttachmentReference], into hasher: inout Hasher) {
        hasher.combine(attachments.count)
        for attachment in attachments {
            hasher.combine(attachment.id)
        }
    }
}

struct WorkstationSourceSignature: Equatable, Sendable {
    var uploads: Int
    var generated: Int
    var diagramText: Int
    var staged: Int
    var repo: Int
    var computer: Int
}

enum WorkstationItemGroup: Hashable, Sendable {
    case staged, uploads, generated, diagrams, repo, computer
}

/// One folder in Files, already filtered, with its size worked out once.
struct WorkstationFolder: Sendable {
    var items: [WorkstationItem] = []
    var bytes = 0
    var bytesText = ""

    var summary: String {
        let sizeText = bytes > 0 ? " · \(bytesText)" : ""
        return "\(items.count) \(items.count == 1 ? "file" : "files")\(sizeText)"
    }
}

/// Everything the Files tab shows for one search.
struct WorkstationListing: Sendable {
    var query = ""
    var staged = WorkstationFolder()
    var uploads = WorkstationFolder()
    var generated = WorkstationFolder()
    var diagrams = WorkstationFolder()
    var repo = WorkstationFolder()
    var computer = WorkstationFolder()
}

/// Builds the item lists from plain values, off the main thread.
enum WorkstationItemBuilder {
    struct Cache: Sendable {
        /// Attachment cards by source, so 8,000 sizes are formatted once, not on every change.
        var attachmentItems: [String: WorkstationItem] = [:]
        /// Each reply step's diagrams, found once per change to that step's text.
        var mermaid: [UUID: MermaidStep] = [:]
    }

    /// Kept between openings of the Workstation, so opening it again doesn't format every size again.
    @MainActor static var sharedCache = Cache()

    struct Output: Sendable {
        var staged: [WorkstationItem]?
        var uploads: [WorkstationItem]?
        var generated: [WorkstationItem]?
        var diagrams: [WorkstationItem]?
        var repo: [WorkstationItem]?
        var computer: [WorkstationItem]?
        var cache: Cache
    }

    struct MermaidStep: Sendable {
        var textLength: Int
        var blocks: [String]
    }

    struct Lists: Sendable {
        var staged: [WorkstationItem]
        var uploads: [WorkstationItem]
        var generated: [WorkstationItem]
        var diagrams: [WorkstationItem]
        var repo: [WorkstationItem]
        var computer: [WorkstationItem]
    }

    static func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func build(_ sources: WorkstationSources, groups: Set<WorkstationItemGroup>, cache: Cache) -> Output {
        var cache = cache
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        var output = Output(cache: cache)
        if groups.contains(.staged) {
            output.staged = stagedItems(sources.staged)
        }
        if groups.contains(.uploads) {
            output.uploads = uploadItems(sources, cache: &cache, formatter: formatter)
        }
        if groups.contains(.generated) {
            output.generated = generatedItems(sources.messages, cache: &cache, formatter: formatter)
        }
        if groups.contains(.diagrams) {
            output.diagrams = diagramItems(sources.messages, cache: &cache.mermaid)
        }
        if groups.contains(.repo) {
            output.repo = repoItems(sources)
        }
        if groups.contains(.computer) {
            output.computer = computerItems(sources)
        }
        output.cache = cache
        return output
    }

    private static func attachmentItem(
        _ att: AttachmentReference,
        source: String,
        removableDraft: Bool,
        cache: inout Cache,
        formatter: ByteCountFormatter
    ) -> WorkstationItem {
        let key = "\(source)|\(removableDraft ? 1 : 0)|\(att.id.uuidString)"
        if let cached = cache.attachmentItems[key], cached.attachment == att {
            return cached
        }
        let item = WorkstationItem.fromAttachment(
            att,
            source: source,
            removableDraft: removableDraft,
            sizeText: formatter.string(fromByteCount: Int64(att.bytes))
        )
        cache.attachmentItems[key] = item
        return item
    }

    static func uploadItems(_ sources: WorkstationSources, cache: inout Cache, formatter: ByteCountFormatter) -> [WorkstationItem] {
        var seen: Set<UUID> = []
        var list: [WorkstationItem] = []
        for att in sources.localAdded where seen.insert(att.id).inserted {
            list.append(attachmentItem(att, source: "Draft upload", removableDraft: true, cache: &cache, formatter: formatter))
        }
        if sources.hasSession {
            for att in sources.workstationFiles where seen.insert(att.id).inserted {
                list.append(attachmentItem(att, source: "Workstation artifact", removableDraft: false, cache: &cache, formatter: formatter))
            }
            for att in sources.draftAttachments where seen.insert(att.id).inserted {
                list.append(attachmentItem(att, source: "Draft upload", removableDraft: true, cache: &cache, formatter: formatter))
            }
            for message in sources.messages {
                guard case .user(let user) = message.body else { continue }
                for att in user.attachments where seen.insert(att.id).inserted {
                    list.append(attachmentItem(att, source: "Chat upload", removableDraft: false, cache: &cache, formatter: formatter))
                }
            }
        } else {
            for att in sources.homeAttachments where seen.insert(att.id).inserted {
                list.append(attachmentItem(att, source: "Draft upload", removableDraft: true, cache: &cache, formatter: formatter))
            }
        }
        return list
    }

    static func generatedItems(_ messages: [ChatMessage], cache: inout Cache, formatter: ByteCountFormatter) -> [WorkstationItem] {
        var list: [WorkstationItem] = []
        for message in messages {
            guard let turn = message.assistantTurn else { continue }
            for step in turn.steps {
                for image in step.generatedImages ?? [] {
                    let source = image.isVideo ? "Made video" : (image.isFile ? "Sent file" : "Generated picture")
                    list.append(attachmentItem(image.attachment, source: source, removableDraft: false, cache: &cache, formatter: formatter))
                }
            }
        }
        return list
    }

    /// Diagrams, numbered across the whole chat. Each reply step's blocks are found once per
    /// change to that step's text, not on every redraw.
    static func diagramItems(_ messages: [ChatMessage], cache: inout [UUID: MermaidStep]) -> [WorkstationItem] {
        var list: [WorkstationItem] = []
        var idx = 1
        for message in messages {
            guard let turn = message.assistantTurn else { continue }
            for step in turn.steps {
                let length = step.text.utf8.count
                let blocks: [String]
                if let cached = cache[step.id], cached.textLength == length {
                    blocks = cached.blocks
                } else {
                    blocks = extractMermaidBlocks(from: step.text)
                    cache[step.id] = MermaidStep(textLength: length, blocks: blocks)
                }
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

    static func stagedItems(_ changes: [StagedChange]) -> [WorkstationItem] {
        changes.map { change in
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

    static func repoItems(_ sources: WorkstationSources) -> [WorkstationItem] {
        guard let repoName = sources.repoName else { return [] }
        var list: [WorkstationItem] = []
        list.reserveCapacity(sources.repoEntries.count)
        for entry in sources.repoEntries where entry.isFile {
            let fileName = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
            list.append(WorkstationItem(
                id: "repo:\(entry.path)",
                name: fileName,
                subtitle: "\(repoName)/\(entry.path)",
                bytes: entry.size ?? 0,
                kind: .repoFile(entry.path),
                attachment: nil,
                repoPath: entry.path,
                isRemovableDraft: false
            ))
        }
        return list
    }

    static func computerItems(_ sources: WorkstationSources) -> [WorkstationItem] {
        sources.computerFiles.map { path in
            let fileName = path.split(separator: "/").last.map(String.init) ?? path
            return WorkstationItem(
                id: "computer:\(path)",
                name: fileName,
                subtitle: "\(sources.machineName):\(path)",
                bytes: 0,
                kind: .computerFile(path),
                attachment: nil,
                repoPath: nil,
                isRemovableDraft: false
            )
        }
    }

    static func extractMermaidBlocks(from markdown: String) -> [String] {
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

    /// The Files tab for one search: the same name-or-path match as always, with each folder's
    /// size added up once.
    static func listing(_ lists: Lists, query: String) -> WorkstationListing {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        func folder(_ source: [WorkstationItem]) -> WorkstationFolder {
            let items: [WorkstationItem]
            if query.isEmpty {
                items = source
            } else {
                items = source.filter {
                    $0.name.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query)
                }
            }
            let bytes = items.reduce(0) { $0 + $1.bytes }
            return WorkstationFolder(items: items, bytes: bytes, bytesText: bytes > 0 ? formatter.string(fromByteCount: Int64(bytes)) : "")
        }
        return WorkstationListing(
            query: query,
            staged: folder(lists.staged),
            uploads: folder(lists.uploads),
            generated: folder(lists.generated),
            diagrams: folder(lists.diagrams),
            repo: folder(lists.repo),
            computer: folder(lists.computer)
        )
    }
}

// MARK: - Geometry

/// The view onto the canvas: how far in, and where. A card at canvas point `p` is drawn at
/// `origin + p * zoom`, the origin being the viewport's centre (46% down) moved by `pan`.
struct CanvasViewTransform: Equatable, Sendable {
    var zoom: CGFloat
    var pan: CGSize

    func origin(in viewport: CGSize) -> CGPoint {
        CGPoint(
            x: viewport.width * 0.5 + pan.width,
            y: viewport.height * WorkstationCanvasLayout.originYFraction + pan.height
        )
    }

    func screenPoint(_ canvasPoint: CGPoint, viewport: CGSize) -> CGPoint {
        let o = origin(in: viewport)
        return CGPoint(x: o.x + canvasPoint.x * zoom, y: o.y + canvasPoint.y * zoom)
    }

    func canvasPoint(_ screenPoint: CGPoint, viewport: CGSize) -> CGPoint {
        let o = origin(in: viewport)
        let z = max(zoom, WorkstationCanvasLayout.minZoom)
        return CGPoint(x: (screenPoint.x - o.x) / z, y: (screenPoint.y - o.y) / z)
    }

    /// The part of the canvas on screen, grown by a margin given in screen points.
    func visibleCanvasRect(viewport: CGSize, marginX: CGFloat, marginY: CGFloat) -> CGRect {
        let topLeft = canvasPoint(CGPoint(x: -marginX, y: -marginY), viewport: viewport)
        let bottomRight = canvasPoint(CGPoint(x: viewport.width + marginX, y: viewport.height + marginY), viewport: viewport)
        return CGRect(x: topLeft.x, y: topLeft.y, width: max(0, bottomRight.x - topLeft.x), height: max(0, bottomRight.y - topLeft.y))
    }

    /// Zoomed by `magnification` (kept within the canvas limits) with the canvas point under
    /// `anchor` staying under it: the fingers' spot stays put while pinching.
    func zoomed(by magnification: CGFloat, anchor: CGPoint, viewport: CGSize) -> CanvasViewTransform {
        let newZoom = WorkstationCanvasLayout.clampZoom(zoom * magnification)
        let under = canvasPoint(anchor, viewport: viewport)
        let newOrigin = CGPoint(x: anchor.x - under.x * newZoom, y: anchor.y - under.y * newZoom)
        return CanvasViewTransform(
            zoom: newZoom,
            pan: CGSize(
                width: newOrigin.x - viewport.width * 0.5,
                height: newOrigin.y - viewport.height * WorkstationCanvasLayout.originYFraction
            )
        )
    }

    func translated(by delta: CGSize) -> CanvasViewTransform {
        CanvasViewTransform(zoom: zoom, pan: CGSize(width: pan.width + delta.width, height: pan.height + delta.height))
    }
}

/// A move of the view that plays over time: zoom buttons, Arrange, Center, double tap, and the
/// glide after a flick. Worked out from the clock on each frame, so a touch can stop it exactly
/// where it is.
struct CanvasViewportAnimation: Equatable, Sendable {
    enum Curve: Equatable, Sendable {
        /// Eases out over the duration.
        case easeOut(duration: Double)
        /// Slows down like a flicked scroll view: covers the whole distance, quickly at first.
        case glide(timeConstant: Double)
    }

    var from: CanvasViewTransform
    var to: CanvasViewTransform
    /// A screen point that stays still while zooming (double tap); nil moves zoom and pan evenly.
    var anchor: CGPoint?
    var viewport: CGSize
    var start: Date
    var curve: Curve

    var duration: Double {
        switch curve {
        case .easeOut(let duration):
            return max(0.01, duration)
        case .glide(let timeConstant):
            // Long enough that what's left at the end is under half a point.
            let distance = Double(hypot(to.pan.width - from.pan.width, to.pan.height - from.pan.height))
            return max(0.05, timeConstant * max(1, log(max(distance, 1) / 0.5)))
        }
    }

    func isFinished(at date: Date) -> Bool {
        date.timeIntervalSince(start) >= duration
    }

    func value(at date: Date) -> CanvasViewTransform {
        let elapsed = min(max(date.timeIntervalSince(start), 0), duration)
        if elapsed >= duration { return to }
        let progress: CGFloat
        switch curve {
        case .easeOut(let total):
            let u = elapsed / max(total, 0.01)
            progress = CGFloat(1 - pow(1 - u, 3))
        case .glide(let timeConstant):
            progress = CGFloat(1 - exp(-elapsed / max(timeConstant, 0.01)))
        }
        if let anchor, from.zoom > 0, to.zoom > 0 {
            let zoom = from.zoom * pow(to.zoom / from.zoom, progress)
            return from.zoomed(by: zoom / from.zoom, anchor: anchor, viewport: viewport)
        }
        return CanvasViewTransform(
            zoom: from.zoom + (to.zoom - from.zoom) * progress,
            pan: CGSize(
                width: from.pan.width + (to.pan.width - from.pan.width) * progress,
                height: from.pan.height + (to.pan.height - from.pan.height) * progress
            )
        )
    }
}

/// Card sizes, zoom limits and grid layouts. Pure functions, safe off the main thread.
/// `idealGridColumns(for:)` lives with the Canvas screen in WorkstationScreen.swift.
enum WorkstationCanvasLayout {
    static let cardWidth: CGFloat = 208
    static let cardHeight: CGFloat = 196
    static let previewHeight: CGFloat = 152
    static let minZoom: CGFloat = 0.01
    static let maxZoom: CGFloat = 3.0
    static let originYFraction: CGFloat = 0.46
    static let zoomSteps: [CGFloat] = [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 1.0, 1.5, 2.0, 3.0]
    /// Below this, with many cards, each card is a small mark (icon and name).
    static let overviewZoom: CGFloat = 0.18
    /// From here in, cards are full views you can touch; between the two, one drawing paints
    /// cards that look the same.
    static let fullCardZoom: CGFloat = 0.45

    enum Detail: Equatable, Sendable {
        case overview
        case lite
        case full
    }

    static func detail(zoom: CGFloat, itemCount: Int) -> Detail {
        if zoom < overviewZoom && itemCount > 24 { return .overview }
        if zoom < fullCardZoom { return .lite }
        return .full
    }

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, minZoom), maxZoom)
    }

    /// A card's rectangle on the canvas, from its centre.
    static func cardRect(at center: CGPoint) -> CGRect {
        CGRect(x: center.x - cardWidth / 2, y: center.y - cardHeight / 2, width: cardWidth, height: cardHeight)
    }

    /// Where cards without a place of their own go: slot 0, 1, 2… across `columns`, row by row.
    /// The columns are fixed when the grid is made, so a new card never moves the others.
    struct SlotGrid: Codable, Equatable, Sendable {
        var columns: Int
        var spacingX: CGFloat
        var spacingY: CGFloat
        var offsetY: CGFloat
        /// The next slot to try.
        var cursor: Int

        func point(forSlot slot: Int) -> CGPoint {
            let cols = max(1, columns)
            let col = slot % cols
            let row = slot / cols
            let originX = -CGFloat(cols - 1) * spacingX * 0.5
            return CGPoint(x: originX + CGFloat(col) * spacingX, y: CGFloat(row) * spacingY + offsetY)
        }

        /// The grid cards used to fall into, sized by how many there were: used once for a
        /// Workstation that has never been saved here, so its cards open where they were.
        static func original(count: Int) -> SlotGrid {
            SlotGrid(columns: WorkstationCanvasLayout.idealGridColumns(for: max(1, count)), spacingX: 236, spacingY: 258, offsetY: -90, cursor: 0)
        }
    }

    struct Arrangement: Sendable {
        var positions: [String: CGPoint]
        var grid: SlotGrid
        var bounds: CGRect
    }

    /// Arrange: every card into one roughly square grid, in list order. O(n).
    static func arrange(ids: [String]) -> Arrangement {
        let cols = idealGridColumns(for: max(1, ids.count))
        var grid = SlotGrid(columns: cols, spacingX: 232, spacingY: 252, offsetY: -60, cursor: 0)
        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(ids.count)
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for (slot, id) in ids.enumerated() {
            let p = grid.point(forSlot: slot)
            positions[id] = p
            minX = min(minX, p.x - 115)
            maxX = max(maxX, p.x + 115)
            minY = min(minY, p.y - 130)
            maxY = max(maxY, p.y + 130)
        }
        grid.cursor = ids.count
        let bounds = ids.isEmpty ? CGRect.zero : CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return Arrangement(positions: positions, grid: grid, bounds: bounds)
    }

    /// The zoom and pan that fit `bounds` (canvas points) on screen, as Arrange always has.
    static func fitted(_ bounds: CGRect, viewport: CGSize) -> CanvasViewTransform {
        let spanW = max(240, bounds.width)
        let spanH = max(260, bounds.height)
        let scaleX = (viewport.width - 36) / spanW
        let scaleY = (viewport.height - 150) / spanH
        let fitted = min(max(min(scaleX, scaleY), 0.04), 1.0)
        return CanvasViewTransform(zoom: fitted, pan: CGSize(width: -bounds.midX * fitted, height: -bounds.midY * fitted))
    }
}

// MARK: - Which cards are where

/// Cards bucketed into 512-point squares of the canvas, so finding what's on screen, or which
/// card is under a finger, looks at a few squares instead of every card.
struct CanvasSpatialIndex: Sendable {
    static let cellSize: CGFloat = 512

    struct Cell: Hashable, Sendable {
        var x: Int
        var y: Int
    }

    struct CellRange: Equatable, Sendable {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int

        var cellCount: Int { (maxX - minX + 1) * (maxY - minY + 1) }

        func clamped(to other: CellRange) -> CellRange? {
            let range = CellRange(minX: max(minX, other.minX), maxX: min(maxX, other.maxX), minY: max(minY, other.minY), maxY: min(maxY, other.maxY))
            return range.minX <= range.maxX && range.minY <= range.maxY ? range : nil
        }

        func union(_ other: CellRange) -> CellRange {
            CellRange(minX: min(minX, other.minX), maxX: max(maxX, other.maxX), minY: min(minY, other.minY), maxY: max(maxY, other.maxY))
        }
    }

    /// Each card's canvas rectangle, in the same order as the canvas items (`.null` until placed).
    private(set) var rects: [CGRect] = []
    private var cells: [Cell: [Int]] = [:]
    private var occupied: CellRange?

    init() {}

    init(rects: [CGRect]) {
        self.rects = rects
        for (index, rect) in rects.enumerated() where !rect.isNull {
            add(index, rect)
        }
    }

    var count: Int { rects.count }

    static func cellRange(for rect: CGRect) -> CellRange? {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        func cell(_ value: CGFloat) -> Int {
            Int(min(max((value / cellSize).rounded(.down), -1_000_000), 1_000_000))
        }
        return CellRange(minX: cell(rect.minX), maxX: cell(rect.maxX), minY: cell(rect.minY), maxY: cell(rect.maxY))
    }

    func center(of index: Int) -> CGPoint? {
        guard rects.indices.contains(index), !rects[index].isNull else { return nil }
        return CGPoint(x: rects[index].midX, y: rects[index].midY)
    }

    mutating func move(_ index: Int, to rect: CGRect) {
        guard rects.indices.contains(index) else { return }
        remove(index)
        rects[index] = rect
        if !rect.isNull { add(index, rect) }
    }

    private mutating func add(_ index: Int, _ rect: CGRect) {
        guard let range = Self.cellRange(for: rect) else { return }
        for y in range.minY...range.maxY {
            for x in range.minX...range.maxX {
                cells[Cell(x: x, y: y), default: []].append(index)
            }
        }
        occupied = occupied.map { $0.union(range) } ?? range
    }

    private mutating func remove(_ index: Int) {
        let old = rects[index]
        guard let range = Self.cellRange(for: old) else { return }
        for y in range.minY...range.maxY {
            for x in range.minX...range.maxX {
                let cell = Cell(x: x, y: y)
                cells[cell]?.removeAll { $0 == index }
                if cells[cell]?.isEmpty == true { cells[cell] = nil }
            }
        }
    }

    /// Cards overlapping `rect`, lowest first (the order they're drawn, so the last is on top).
    func indices(intersecting rect: CGRect) -> [Int] {
        guard let wanted = Self.cellRange(for: rect), let occupied, let range = wanted.clamped(to: occupied) else { return [] }
        if range.cellCount * 2 > rects.count {
            // Most of the canvas is in view: one pass over every card is cheaper and already in order.
            var found: [Int] = []
            for index in rects.indices where rects[index].intersects(rect) {
                found.append(index)
            }
            return found
        }
        var found: [Int] = []
        for y in range.minY...range.maxY {
            for x in range.minX...range.maxX {
                guard let list = cells[Cell(x: x, y: y)] else { continue }
                for index in list where rects[index].intersects(rect) {
                    found.append(index)
                }
            }
        }
        found.sort()
        var unique: [Int] = []
        unique.reserveCapacity(found.count)
        var last = -1
        for index in found where index != last {
            unique.append(index)
            last = index
        }
        return unique
    }

    /// The card drawn on top at `point`, the one a finger there touches.
    func topmost(at point: CGPoint) -> Int? {
        guard let range = Self.cellRange(for: CGRect(origin: point, size: .zero)),
              let list = cells[Cell(x: range.minX, y: range.minY)] else { return nil }
        var best: Int?
        for index in list where rects[index].contains(point) {
            if best.map({ index > $0 }) ?? true { best = index }
        }
        return best
    }

    func intersectsAny(_ rect: CGRect) -> Bool {
        guard let wanted = Self.cellRange(for: rect), let occupied, let range = wanted.clamped(to: occupied) else { return false }
        for y in range.minY...range.maxY {
            for x in range.minX...range.maxX {
                guard let list = cells[Cell(x: x, y: y)] else { continue }
                if list.contains(where: { rects[$0].intersects(rect) }) { return true }
            }
        }
        return false
    }

    /// The smallest rectangle around every card's centre, or nil when nothing is placed.
    var centersBounds: CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var any = false
        for rect in rects where !rect.isNull {
            any = true
            minX = min(minX, rect.midX)
            maxX = max(maxX, rect.midX)
            minY = min(minY, rect.midY)
            maxY = max(maxY, rect.midY)
        }
        return any ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
    }
}

/// A card on screen: what it is and where its centre is on the canvas.
struct CanvasCardEntry: Identifiable, Sendable {
    let item: WorkstationItem
    let center: CGPoint
    var id: String { item.id }
}

// MARK: - Saved card places

struct WorkstationLayoutSnapshot: Sendable {
    var positions: [String: CGPoint]
    var slotGrid: WorkstationCanvasLayout.SlotGrid?
    var sequence: Int
}

struct WorkstationLoadedLayout: Sendable {
    /// nil when this Workstation has no layout file yet.
    var positions: [String: CGPoint]?
    var slotGrid: WorkstationCanvasLayout.SlotGrid?
    /// Places saved by older builds in UserDefaults, still read for any card the file lacks.
    var legacy: [String: CGPoint]
}

/// Reads and writes card places as one small JSON file per Workstation in Application Support,
/// off the main thread. Older builds kept them in UserDefaults, which wrote 8,000 entries on the
/// main thread after every move.
actor WorkstationLayoutStore {
    static let shared = WorkstationLayoutStore()

    private struct File: Codable {
        var version: Int
        var positions: [String: [Double]]
        var slotGrid: WorkstationCanvasLayout.SlotGrid?
    }

    private var lastWritten: [URL: Int] = [:]

    static func fileURL(for storageKey: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("MAIPA-G", isDirectory: true)
            .appendingPathComponent("WorkstationLayouts", isDirectory: true)
            .appendingPathComponent("\(storageKey).json")
    }

    func load(from url: URL, legacyKey: String) -> WorkstationLoadedLayout {
        var legacy: [String: CGPoint] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: [Double]] {
            legacy.reserveCapacity(raw.count)
            for (key, pair) in raw where pair.count == 2 {
                legacy[key] = CGPoint(x: pair[0], y: pair[1])
            }
        }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return WorkstationLoadedLayout(positions: nil, slotGrid: nil, legacy: legacy)
        }
        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(file.positions.count)
        for (key, pair) in file.positions where pair.count == 2 {
            positions[key] = CGPoint(x: pair[0], y: pair[1])
        }
        return WorkstationLoadedLayout(positions: positions, slotGrid: file.slotGrid, legacy: legacy)
    }

    func save(_ snapshot: WorkstationLayoutSnapshot, to url: URL) {
        // Writes can arrive out of order; never let an older one replace a newer one.
        if let last = lastWritten[url], last >= snapshot.sequence { return }
        lastWritten[url] = snapshot.sequence
        var encoded: [String: [Double]] = [:]
        encoded.reserveCapacity(snapshot.positions.count)
        for (key, point) in snapshot.positions {
            encoded[key] = [Double(point.x), Double(point.y)]
        }
        let file = File(version: 1, positions: encoded, slotGrid: snapshot.slotGrid)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - The model

/// The Workstation's state. The item lists are rebuilt only when what they're made from changes,
/// off the main thread; card places live in a spatial index; the view's zoom and pan change only
/// when a gesture or animation ends, so a gesture redraws the board and nothing else.
@Observable
@MainActor
final class WorkstationCanvasModel {
    enum Tool: String, Sendable {
        case pointer
        case hand
    }

    // Lists, as Files shows them, and the canvas's list (each item once).
    private(set) var stagedItems: [WorkstationItem] = []
    private(set) var uploadItems: [WorkstationItem] = []
    private(set) var generatedItems: [WorkstationItem] = []
    private(set) var diagramItems: [WorkstationItem] = []
    private(set) var repoItems: [WorkstationItem] = []
    private(set) var computerItems: [WorkstationItem] = []
    /// Everything on the canvas, each item once, in drawing order (later cards on top).
    private(set) var items: [WorkstationItem] = []
    /// Goes up whenever `items` changes.
    private(set) var itemsRevision = 0
    /// All items, duplicates included, as the header has always counted them.
    private(set) var allCount = 0
    private(set) var totalBytesText = WorkstationItemBuilder.formattedBytes(0)
    private(set) var exportableAttachments: [AttachmentReference] = []
    private(set) var listing = WorkstationListing()
    private(set) var pendingChangesCount = 0
    private(set) var activeRepo: ChatRepo?
    private(set) var hasBuiltItems = false

    // The canvas.
    var tool: Tool = .pointer
    /// Where the view rests (during an animation, where it's heading).
    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGSize = .zero
    private(set) var animation: CanvasViewportAnimation?
    var selectedItemID: String?
    var previewingItem: WorkstationItem?
    private(set) var index = CanvasSpatialIndex()
    private(set) var isLayoutReady = false
    /// Goes up whenever every card's place is worked out again (layout loaded, items changed,
    /// Arrange), so whatever depends on which cards are where can ask again.
    private(set) var layoutRevision = 0

    @ObservationIgnored private var positions: [String: CGPoint] = [:]
    @ObservationIgnored private var legacyPositions: [String: CGPoint] = [:]
    @ObservationIgnored private var slotGrid: WorkstationCanvasLayout.SlotGrid?
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    @ObservationIgnored private var storageKey: String?
    @ObservationIgnored private var layoutURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveSequence = 0
    @ObservationIgnored private var lastSignature: WorkstationSourceSignature?
    @ObservationIgnored private var pendingSources: WorkstationSources?
    @ObservationIgnored private var pendingGroups: Set<WorkstationItemGroup> = []
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var builderCache = WorkstationItemBuilder.sharedCache
    @ObservationIgnored private var appliedQuery = ""
    @ObservationIgnored private var filterToken = 0
    @ObservationIgnored private var animationToken = 0
    @ObservationIgnored private var arrangeToken = 0
    @ObservationIgnored private var zoomBeforeDoubleTap: CGFloat?
    @ObservationIgnored private var lastPinchEnded = Date.distantPast

    init() {}

    // MARK: Setup and sources

    /// Reads this Workstation's saved view at once and its card places in the background.
    func configure(storageKey key: String) {
        guard storageKey != key else { return }
        storageKey = key
        loadViewport(key)
        let url = WorkstationLayoutStore.fileURL(for: key)
        layoutURL = url
        Task { [weak self] in
            let loaded = await WorkstationLayoutStore.shared.load(from: url, legacyKey: key)
            guard let self, self.storageKey == key else { return }
            self.applyLoadedLayout(loaded)
        }
    }

    /// Takes the latest sources. Only the groups whose ids, counts or lengths changed are rebuilt.
    func sync(_ sources: WorkstationSources, pendingChanges: Int, activeRepo repo: ChatRepo?) {
        sync(sources, signature: sources.signature(), pendingChanges: pendingChanges, activeRepo: repo)
    }

    /// The same, with the signature the caller already worked out from these sources.
    func sync(_ sources: WorkstationSources, signature: WorkstationSourceSignature, pendingChanges: Int, activeRepo repo: ChatRepo?) {
        if pendingChangesCount != pendingChanges { pendingChangesCount = pendingChanges }
        if activeRepo != repo { activeRepo = repo }
        let previous = lastSignature
        guard signature != previous else { return }
        lastSignature = signature
        var groups = Set<WorkstationItemGroup>()
        if previous?.staged != signature.staged { groups.insert(.staged) }
        if previous?.uploads != signature.uploads { groups.insert(.uploads) }
        if previous?.generated != signature.generated { groups.insert(.generated) }
        if previous?.repo != signature.repo { groups.insert(.repo) }
        if previous?.computer != signature.computer { groups.insert(.computer) }
        if previous?.diagramText != signature.diagramText { groups.insert(.diagrams) }
        guard !groups.isEmpty else { return }
        pendingSources = sources
        pendingGroups.formUnion(groups)
        if buildTask == nil { startBuild() }
    }

    private func startBuild() {
        guard let sources = pendingSources else { return }
        let groups = pendingGroups
        pendingSources = nil
        pendingGroups = []
        let cache = builderCache
        buildTask = Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) {
                WorkstationItemBuilder.build(sources, groups: groups, cache: cache)
            }.value
            guard let self else { return }
            var cache = output.cache
            if cache.attachmentItems.count > 40_000 || cache.mermaid.count > 40_000 { cache = WorkstationItemBuilder.Cache() }
            self.builderCache = cache
            WorkstationItemBuilder.sharedCache = cache
            // A list is replaced only if something in it really changed (a reply growing word by
            // word rebuilds the diagram list and almost always finds it the same).
            var changed = !self.hasBuiltItems
            if let list = output.staged, !Self.same(list, self.stagedItems) { self.stagedItems = list; changed = true }
            if let list = output.uploads, !Self.same(list, self.uploadItems) { self.uploadItems = list; changed = true }
            if let list = output.generated, !Self.same(list, self.generatedItems) { self.generatedItems = list; changed = true }
            if let list = output.diagrams, !Self.same(list, self.diagramItems) { self.diagramItems = list; changed = true }
            if let list = output.repo, !Self.same(list, self.repoItems) { self.repoItems = list; changed = true }
            if let list = output.computer, !Self.same(list, self.computerItems) { self.computerItems = list; changed = true }
            self.buildTask = nil
            if changed { self.mergeItems() }
            if self.pendingSources != nil { self.startBuild() }
        }
    }

    private func mergeItems() {
        let lists = [stagedItems, uploadItems, generatedItems, diagramItems, repoItems, computerItems]
        var seen = Set<String>()
        var merged: [WorkstationItem] = []
        var count = 0
        var totalBytes = 0
        for list in lists {
            count += list.count
            for item in list {
                totalBytes += item.bytes
                if seen.insert(item.id).inserted { merged.append(item) }
            }
        }
        if allCount != count { allCount = count }
        let bytesText = WorkstationItemBuilder.formattedBytes(totalBytes)
        if totalBytesText != bytesText { totalBytesText = bytesText }
        let exportable = (uploadItems + generatedItems).compactMap(\.attachment)
        if exportable != exportableAttachments { exportableAttachments = exportable }
        if !Self.same(merged, items) {
            items = merged
            var byID: [String: Int] = [:]
            byID.reserveCapacity(merged.count)
            for (offset, item) in merged.enumerated() { byID[item.id] = offset }
            indexByID = byID
            itemsRevision &+= 1
            rebuildIndex()
        }
        if !hasBuiltItems { hasBuiltItems = true }
        refilter(appliedQuery)
    }

    private static func same(_ lhs: [WorkstationItem], _ rhs: [WorkstationItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) where a != b { return false }
        return true
    }

    // MARK: Files search

    /// Filters Files off the main thread. The view calls this after the typing has paused.
    func setFileQuery(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != appliedQuery else { return }
        appliedQuery = query
        refilter(query)
    }

    private func refilter(_ query: String) {
        filterToken &+= 1
        let token = filterToken
        let lists = WorkstationItemBuilder.Lists(
            staged: stagedItems,
            uploads: uploadItems,
            generated: generatedItems,
            diagrams: diagramItems,
            repo: repoItems,
            computer: computerItems
        )
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                WorkstationItemBuilder.listing(lists, query: query)
            }.value
            guard let self, token == self.filterToken else { return }
            self.listing = result
        }
    }

    // MARK: Lookups

    func item(withID id: String) -> WorkstationItem? {
        guard let offset = indexByID[id], items.indices.contains(offset) else { return nil }
        return items[offset]
    }

    var selectedItem: WorkstationItem? {
        guard let selectedItemID else { return nil }
        return item(withID: selectedItemID)
    }

    /// The card on top under a screen point.
    func item(at screenPoint: CGPoint, viewport: CGSize, transform: CanvasViewTransform) -> WorkstationItem? {
        let point = transform.canvasPoint(screenPoint, viewport: viewport)
        guard let offset = index.topmost(at: point), items.indices.contains(offset) else { return nil }
        return items[offset]
    }

    /// Cards overlapping a canvas rectangle, in drawing order.
    func entries(in canvasRect: CGRect) -> [CanvasCardEntry] {
        let found = index.indices(intersecting: canvasRect)
        var entries: [CanvasCardEntry] = []
        entries.reserveCapacity(found.count)
        for offset in found where items.indices.contains(offset) {
            guard let center = index.center(of: offset) else { continue }
            entries.append(CanvasCardEntry(item: items[offset], center: center))
        }
        return entries
    }

    // MARK: Card places

    private func applyLoadedLayout(_ loaded: WorkstationLoadedLayout) {
        legacyPositions = loaded.legacy
        positions = loaded.positions ?? [:]
        slotGrid = loaded.slotGrid
        isLayoutReady = true
        rebuildIndex()
    }

    /// Puts every card in the index, giving cards seen for the first time a place of their own.
    private func rebuildIndex() {
        guard isLayoutReady else { return }
        var rects: [CGRect] = []
        rects.reserveCapacity(items.count)
        var unplaced: [Int] = []
        for (offset, item) in items.enumerated() {
            if let point = positions[item.id] ?? legacyPositions[item.id] {
                positions[item.id] = point
                rects.append(WorkstationCanvasLayout.cardRect(at: point))
            } else {
                rects.append(.null)
                unplaced.append(offset)
            }
        }
        var fresh = CanvasSpatialIndex(rects: rects)
        if slotGrid == nil, !items.isEmpty {
            // Never saved here: cards without a saved place go where the original count-sized
            // grid put them, once, so they open exactly where they were. From now on the grid is
            // fixed, and every place is written to the layout file.
            var grid = WorkstationCanvasLayout.SlotGrid.original(count: items.count)
            for offset in unplaced {
                let point = grid.point(forSlot: offset)
                positions[items[offset].id] = point
                fresh.move(offset, to: WorkstationCanvasLayout.cardRect(at: point))
            }
            grid.cursor = items.count
            slotGrid = grid
            scheduleLayoutSave()
        } else if var grid = slotGrid, !unplaced.isEmpty {
            // New cards take the next free slot; cards already placed never move.
            for offset in unplaced {
                let point = Self.nextFreeSlot(&grid, in: fresh)
                positions[items[offset].id] = point
                fresh.move(offset, to: WorkstationCanvasLayout.cardRect(at: point))
            }
            slotGrid = grid
            scheduleLayoutSave()
        }
        index = fresh
        layoutRevision &+= 1
    }

    private static func nextFreeSlot(_ grid: inout WorkstationCanvasLayout.SlotGrid, in index: CanvasSpatialIndex) -> CGPoint {
        for _ in 0..<200_000 {
            let point = grid.point(forSlot: grid.cursor)
            grid.cursor += 1
            if !index.intersectsAny(WorkstationCanvasLayout.cardRect(at: point).insetBy(dx: -6, dy: -6)) {
                return point
            }
        }
        let point = grid.point(forSlot: grid.cursor)
        grid.cursor += 1
        return point
    }

    /// Moves a card by a distance in canvas points (a drag divided by the zoom).
    func moveCard(_ id: String, by delta: CGSize) {
        guard let offset = indexByID[id], let current = positions[id] ?? index.center(of: offset) else { return }
        let moved = CGPoint(x: current.x + delta.width, y: current.y + delta.height)
        positions[id] = moved
        index.move(offset, to: WorkstationCanvasLayout.cardRect(at: moved))
        scheduleLayoutSave()
    }

    /// Saves card places a second after the last change, off the main thread.
    private func scheduleLayoutSave() {
        guard layoutURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.writeLayoutNow()
        }
    }

    private func writeLayoutNow() {
        guard let url = layoutURL else { return }
        saveSequence += 1
        let snapshot = WorkstationLayoutSnapshot(positions: positions, slotGrid: slotGrid, sequence: saveSequence)
        Task {
            await WorkstationLayoutStore.shared.save(snapshot, to: url)
        }
    }

    /// Writes a pending save now (the Workstation is closing).
    func flushLayout() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        writeLayoutNow()
    }

    // MARK: The view

    var restingTransform: CanvasViewTransform {
        CanvasViewTransform(zoom: zoom, pan: pan)
    }

    /// Where the view is at `date`, part way through an animation or at rest.
    func displayedTransform(at date: Date) -> CanvasViewTransform {
        if let animation { return animation.value(at: date) }
        return restingTransform
    }

    /// Stops an animation where it is (a finger touched down).
    func interruptAnimation() {
        guard let animation else { return }
        let shown = animation.value(at: Date())
        self.animation = nil
        animationToken &+= 1
        zoom = shown.zoom
        pan = shown.pan
        saveViewport()
    }

    private func loadViewport(_ key: String) {
        guard let saved = UserDefaults.standard.array(forKey: "\(key).viewport") as? [Double], saved.count == 3 else { return }
        zoom = WorkstationCanvasLayout.clampZoom(CGFloat(saved[0]))
        pan = CGSize(width: saved[1], height: saved[2])
    }

    func saveViewport() {
        guard let storageKey else { return }
        UserDefaults.standard.set([Double(zoom), Double(pan.width), Double(pan.height)], forKey: "\(storageKey).viewport")
    }

    /// A pan ends. `liveMagnification` is a pinch still going on at the same time; with none
    /// running, a flick keeps gliding toward where the drag was heading.
    func commitPan(translation: CGSize, predictedEndTranslation: CGSize, viewport: CGSize, liveMagnification: CGFloat?) {
        let magnification = max(liveMagnification ?? 1, 0.01)
        pan.width += translation.width / magnification
        pan.height += translation.height / magnification
        zoomBeforeDoubleTap = nil
        let pinching = liveMagnification != nil || Date().timeIntervalSince(lastPinchEnded) < 0.25
        var remaining = CGSize(
            width: predictedEndTranslation.width - translation.width,
            height: predictedEndTranslation.height - translation.height
        )
        remaining.width = min(max(remaining.width, -viewport.width * 1.5), viewport.width * 1.5)
        remaining.height = min(max(remaining.height, -viewport.height * 1.5), viewport.height * 1.5)
        guard !pinching, hypot(remaining.width, remaining.height) > 24 else {
            saveViewport()
            return
        }
        animate(to: restingTransform.translated(by: remaining), anchor: nil, viewport: viewport, curve: .glide(timeConstant: 0.32))
    }

    /// A pinch ends: zoom around the fingers' starting point.
    func commitPinch(magnification: CGFloat, anchor: CGPoint, viewport: CGSize) {
        let next = restingTransform.zoomed(by: magnification, anchor: anchor, viewport: viewport)
        zoom = next.zoom
        pan = next.pan
        lastPinchEnded = Date()
        zoomBeforeDoubleTap = nil
        saveViewport()
    }

    /// Double tap on the canvas: in to 100% around the tap, or back out if already in.
    func doubleTapZoom(at point: CGPoint, viewport: CGSize) {
        let current = displayedTransform(at: Date())
        let targetZoom: CGFloat
        if current.zoom >= 0.99 {
            targetZoom = zoomBeforeDoubleTap ?? max(WorkstationCanvasLayout.minZoom, current.zoom / 2.5)
            zoomBeforeDoubleTap = nil
        } else {
            zoomBeforeDoubleTap = current.zoom
            targetZoom = 1.0
        }
        let target = current.zoomed(by: targetZoom / max(current.zoom, WorkstationCanvasLayout.minZoom), anchor: point, viewport: viewport)
        animate(to: target, anchor: point, viewport: viewport, curve: .easeOut(duration: 0.3))
    }

    func stepZoom(direction: Int, viewport: CGSize) {
        let steps = WorkstationCanvasLayout.zoomSteps
        let current = zoom
        let targetZoom: CGFloat
        if direction < 0 {
            targetZoom = steps.last(where: { $0 < current - 0.015 }) ?? steps[0]
        } else {
            targetZoom = steps.first(where: { $0 > current + 0.015 }) ?? steps[steps.count - 1]
        }
        zoomBeforeDoubleTap = nil
        animate(to: CanvasViewTransform(zoom: targetZoom, pan: pan), anchor: nil, viewport: viewport, curve: .easeOut(duration: 0.22))
    }

    func resetZoom(viewport: CGSize) {
        zoomBeforeDoubleTap = nil
        animate(to: CanvasViewTransform(zoom: 1, pan: .zero), anchor: nil, viewport: viewport, curve: .easeOut(duration: 0.25))
    }

    /// Center: the middle of all cards, at a comfortable zoom.
    func centerOnCards(viewport: CGSize) {
        zoomBeforeDoubleTap = nil
        guard !items.isEmpty, let bounds = index.centersBounds else {
            animate(to: CanvasViewTransform(zoom: zoom, pan: .zero), anchor: nil, viewport: viewport, curve: .easeOut(duration: 0.25))
            return
        }
        let comfortable = min(max(zoom, 0.45), 1.25)
        let target = CanvasViewTransform(zoom: comfortable, pan: CGSize(width: -bounds.midX * comfortable, height: -bounds.midY * comfortable))
        animate(to: target, anchor: nil, viewport: viewport, curve: .easeOut(duration: 0.25))
    }

    /// Arrange: lays the grid out off the main thread, then applies it in one go and fits it on screen.
    func arrange(viewport: CGSize) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        arrangeToken &+= 1
        let token = arrangeToken
        Task { [weak self] in
            let arrangement = await Task.detached(priority: .userInitiated) {
                WorkstationCanvasLayout.arrange(ids: ids)
            }.value
            guard let self, token == self.arrangeToken else { return }
            self.positions = arrangement.positions
            self.slotGrid = arrangement.grid
            self.rebuildIndex()
            self.scheduleLayoutSave()
            self.zoomBeforeDoubleTap = nil
            self.animate(
                to: WorkstationCanvasLayout.fitted(arrangement.bounds, viewport: viewport),
                anchor: nil,
                viewport: viewport,
                curve: .easeOut(duration: 0.28)
            )
        }
    }

    /// Starts a view animation from wherever the view is now. The resting zoom and pan are set
    /// to the end at once (and saved); the board draws the in-between frames from the clock.
    func animate(to target: CanvasViewTransform, anchor: CGPoint?, viewport: CGSize, curve: CanvasViewportAnimation.Curve) {
        let now = Date()
        let from = displayedTransform(at: now)
        let clamped = CanvasViewTransform(zoom: WorkstationCanvasLayout.clampZoom(target.zoom), pan: target.pan)
        animationToken &+= 1
        let token = animationToken
        let next = CanvasViewportAnimation(from: from, to: clamped, anchor: anchor, viewport: viewport, start: now, curve: curve)
        animation = next
        zoom = clamped.zoom
        pan = clamped.pan
        saveViewport()
        let duration = next.duration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.03))
            guard let self, token == self.animationToken else { return }
            self.animation = nil
        }
    }
}
