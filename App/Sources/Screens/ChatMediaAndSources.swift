import AgentCore
import PDFKit
import SwiftUI
import UIKit

// MARK: - Grok-Style Interactive Fanned Photo Stack in Chat

struct GrokPhotoStackView: View {
    let images: [AttachmentReference]
    @Environment(AppModel.self) private var app
    @State private var currentIndex = 0
    @State private var dragX: CGFloat = 0
    @State private var hasSwiped = false
    @State private var showingGallery = false

    private let cardWidth: CGFloat = 172
    private let cardHeight: CGFloat = 216

    var body: some View {
        if images.count == 1, let single = images.first {
            Button {
                showingGallery = true
            } label: {
                GrokStackPhotoCard(attachment: single, width: 204, height: 244, maxPixels: 900)
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showingGallery) {
                PhotoStackGallerySheet(images: images, initialIndex: 0)
            }
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                ZStack {
                    if images.count >= 3 {
                        let backTwo = images[(currentIndex + 2) % images.count]
                        GrokStackPhotoCard(attachment: backTwo, width: cardWidth, height: cardHeight, maxPixels: 480)
                            .scaleEffect(0.91)
                            .rotationEffect(.degrees(6.5))
                            .offset(x: 13, y: 4)
                            .allowsHitTesting(false)
                    }

                    if images.count >= 2 {
                        let backOne = images[(currentIndex + 1) % images.count]
                        GrokStackPhotoCard(attachment: backOne, width: cardWidth, height: cardHeight, maxPixels: 560)
                            .scaleEffect(0.95)
                            .rotationEffect(.degrees(-5.5))
                            .offset(x: -11, y: 2)
                            .allowsHitTesting(false)
                    }

                    let front = images[min(max(currentIndex, 0), max(0, images.count - 1))]
                    GrokStackPhotoCard(attachment: front, width: cardWidth, height: cardHeight, maxPixels: 820)
                        .offset(x: dragX, y: abs(dragX) * 0.04)
                        .rotationEffect(.degrees(Double(dragX / 18)))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture {
                            showingGallery = true
                        }
                        .gesture(
                            DragGesture(minimumDistance: 14)
                                .onChanged { value in
                                    guard abs(value.translation.width) > abs(value.translation.height) * 0.8 else { return }
                                    dragX = value.translation.width * 0.85
                                }
                                .onEnded { value in
                                    let velocity = value.predictedEndTranslation.width
                                    if value.translation.width < -38 || velocity < -95 {
                                        withAnimation(.snappy(duration: 0.26)) {
                                            currentIndex = (currentIndex + 1) % images.count
                                            dragX = 0
                                            hasSwiped = true
                                        }
                                        Haptics.selection()
                                    } else if value.translation.width > 38 || velocity > 95 {
                                        withAnimation(.snappy(duration: 0.26)) {
                                            currentIndex = (currentIndex - 1 + images.count) % images.count
                                            dragX = 0
                                            hasSwiped = true
                                        }
                                        Haptics.selection()
                                    } else {
                                        withAnimation(.snappy(duration: 0.22)) {
                                            dragX = 0
                                        }
                                    }
                                }
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                Button {
                    showingGallery = true
                } label: {
                    Text(hasSwiped ? "\(currentIndex + 1) of \(images.count) · \(images.count) images" : "\(images.count) images")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
            }
            .fullScreenCover(isPresented: $showingGallery) {
                PhotoStackGallerySheet(images: images, initialIndex: currentIndex)
            }
        }
    }
}

private struct GrokStackPhotoCard: View {
    let attachment: AttachmentReference
    let width: CGFloat
    let height: CGFloat
    let maxPixels: Int
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.raised)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 4)
        .task(id: attachment.id) {
            image = await ImageDownsampler.attachmentThumbnail(attachment, store: app.attachmentStore, maxPixelSize: maxPixels)
        }
    }
}

struct PhotoStackGallerySheet: View {
    let images: [AttachmentReference]
    let initialIndex: Int
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(images: [AttachmentReference], initialIndex: Int) {
        self.images = images
        self.initialIndex = initialIndex
        _selection = State(initialValue: min(max(initialIndex, 0), max(0, images.count - 1)))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(images.enumerated()), id: \.element.id) { idx, item in
                    ZoomableGalleryPhoto(attachment: item)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(images.count > 1 ? "\(selection + 1) of \(images.count)" : (images.first?.name ?? "Photo"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())

                Spacer()

                Button {
                    shareCurrentPhoto()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func shareCurrentPhoto() {
        let index = min(max(selection, 0), max(0, images.count - 1))
        guard images.indices.contains(index) else { return }
        let att = images[index]
        Task {
            guard let data = try? await app.attachmentStore.data(for: att) else { return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(att.name)
            try? data.write(to: tempURL, options: .atomic)
            SharePresenter.present(items: [tempURL])
        }
    }
}

private struct ZoomableGalleryPhoto: View {
    let attachment: AttachmentReference
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = min(max(baseScale * value, 1), 5)
                            }
                            .onEnded { _ in
                                if scale < 1.05 {
                                    withAnimation(.snappy) { scale = 1 }
                                    baseScale = 1
                                } else {
                                    baseScale = scale
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            if scale > 1.1 {
                                scale = 1
                                baseScale = 1
                            } else {
                                scale = 2.5
                                baseScale = 2.5
                            }
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attachment.id) {
            image = await ImageDownsampler.attachmentThumbnail(attachment, store: app.attachmentStore, maxPixelSize: 2_048)
        }
    }
}

// MARK: - Non-Image File Pill + Preview Sheet

struct ChatFileAttachmentPill: View {
    let attachment: AttachmentReference
    @Environment(\.theme) private var theme
    @State private var showingPreview = false

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 22, height: 22)
                    .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.bytes), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPreview) {
            AttachmentQuickPreviewSheet(attachment: attachment)
        }
    }

    private var icon: String {
        if attachment.kind == .pdf { return "doc.richtext.fill" }
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "txt", "rtf": return "doc.text.fill"
        case "zip", "ipa", "tar", "gz": return "doc.zipper"
        case "p12", "cer", "mobileprovision": return "key.fill"
        case "swift", "py", "js", "ts", "json", "yml", "yaml", "html", "css", "sh": return "chevron.left.forwardslash.chevron.right"
        case "csv", "xlsx", "xls": return "tablecells.fill"
        default: return "doc.fill"
        }
    }
}

struct AttachmentQuickPreviewSheet: View {
    let attachment: AttachmentReference
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var data: Data?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView("Opening \(attachment.name)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let data {
                    AttachmentDataPreviewBody(name: attachment.name, kind: attachment.kind, bytes: attachment.bytes, data: data)
                } else {
                    ContentUnavailableView("File unavailable", systemImage: "doc.badge.exclamationmark")
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let data else { return }
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent(attachment.name)
                        try? data.write(to: url, options: .atomic)
                        SharePresenter.present(items: [url])
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(data == nil)
                }
            }
            .task {
                data = try? await app.attachmentStore.data(for: attachment)
                loaded = true
            }
        }
        .presentationDragIndicator(.visible)
    }
}

struct AttachmentDataPreviewBody: View {
    let name: String
    let kind: AttachmentKind
    let bytes: Int
    let data: Data

    var body: some View {
        if kind == .image, let image = ImageDownsampler.image(from: data, maxPixelSize: 2_400) {
            ZoomableImageCanvas(image: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .pdf || name.lowercased().hasSuffix(".pdf") {
            PDFInlineReaderView(data: data)
        } else if let text = Self.readableText(from: data, name: name) {
            ScrollView {
                if name.lowercased().hasSuffix(".md") {
                    MarkdownView(text: String(text.prefix(80_000)))
                        .padding(16)
                } else {
                    CodeBlockView(language: (name as NSString).pathExtension, code: String(text.prefix(80_000)))
                        .padding(16)
                }
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.headline)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \((name as NSString).pathExtension.uppercased()) file")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                Button {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try? data.write(to: url, options: .atomic)
                    SharePresenter.present(items: [url])
                } label: {
                    Label("Save or Share File", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func readableText(from data: Data, name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        let binaryExts: Set<String> = ["zip", "ipa", "p12", "cer", "mobileprovision", "png", "jpg", "jpeg", "webp", "gif", "mp4", "mov", "mp3", "wav", "docx", "xlsx", "pptx"]
        if binaryExts.contains(ext) { return nil }
        guard let str = String(data: data.prefix(250_000), encoding: .utf8), !str.contains("\0") else { return nil }
        return str
    }
}

/// Fitted, centered UIScrollView image viewer (`1.0×` fit on open, pinch `1.0×–5.0×`, double-tap zoom).
struct ZoomableImageCanvas: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> FittingZoomScrollView {
        let scroll = FittingZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 5.0
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scroll.imageView = imageView
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ uiView: FittingZoomScrollView, context: Context) {
        if uiView.imageView?.image !== image {
            uiView.imageView?.image = image
            uiView.zoomScale = 1.0
            uiView.setNeedsLayout()
        }
    }

    final class FittingZoomScrollView: UIScrollView {
        weak var imageView: UIImageView?
        private var lastBoundsSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let imageView, bounds.width > 0, bounds.height > 0 else { return }
            if bounds.size != lastBoundsSize {
                lastBoundsSize = bounds.size
                zoomScale = 1.0
                let inset: CGFloat = 12
                let targetFrame = CGRect(
                    x: inset,
                    y: inset,
                    width: max(1, bounds.width - inset * 2),
                    height: max(1, bounds.height - inset * 2)
                )
                imageView.frame = targetFrame
                contentSize = bounds.size
            }
            centerContent()
        }

        func centerContent() {
            guard let imageView else { return }
            let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
            let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
            imageView.center = CGPoint(
                x: contentSize.width * 0.5 + offsetX,
                y: contentSize.height * 0.5 + offsetY
            )
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? FittingZoomScrollView)?.centerContent()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? FittingZoomScrollView, let imageView else { return }
            if scroll.zoomScale > 1.05 {
                scroll.setZoomScale(1.0, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let targetScale: CGFloat = 2.5
                let w = scroll.bounds.width / targetScale
                let h = scroll.bounds.height / targetScale
                let rect = CGRect(x: point.x - w * 0.5, y: point.y - h * 0.5, width: w, height: h)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

struct PDFInlineReaderView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - Runable-Style `[ 🌐 N sources ]` Pill & Sheet

struct TurnSourceItem: Identifiable, Hashable {
    var id: String { url }
    let title: String
    let url: String
    let domain: String

    static func collect(from turn: AssistantTurn) -> [TurnSourceItem] {
        var seen: Set<String> = []
        var items: [TurnSourceItem] = []

        func add(url rawURL: String, title: String?) {
            let trimmed = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'()[]<>.,;"))
            guard let parsed = URL(string: trimmed),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "https" || scheme == "http"),
                  let host = parsed.host?.lowercased(),
                  !host.isEmpty
            else { return }
            let cleanHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let canonical = parsed.absoluteString
            guard !seen.contains(canonical) else { return }
            seen.insert(canonical)
            let displayTitle: String
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != canonical {
                displayTitle = t
            } else {
                let pathLabel = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                displayTitle = pathLabel.isEmpty ? cleanHost : "\(cleanHost)/\(pathLabel)"
            }
            items.append(TurnSourceItem(title: displayTitle, url: canonical, domain: cleanHost))
        }

        for step in turn.steps {
            for citation in step.citations ?? [] {
                add(url: citation.url, title: citation.title)
            }
            for call in step.toolCalls {
                let lowerName = call.name.lowercased()
                let isSourceTool = lowerName.contains("web")
                    || lowerName.contains("search")
                    || lowerName.contains("url")
                    || lowerName.contains("wikipedia")
                    || lowerName.contains("arxiv")
                    || lowerName.contains("hacker")
                    || lowerName.contains("reddit")
                    || lowerName.contains("jina")
                    || lowerName.contains("brave")
                    || lowerName.contains("perplexity")
                    || lowerName.contains("tavily")
                    || lowerName.contains("exa")
                    || lowerName.contains("firecrawl")
                    || lowerName.contains("news")
                guard isSourceTool else { continue }
                extractURLs(from: call.arguments).forEach { add(url: $0, title: nil) }
                if let res = call.result {
                    extractURLs(from: String(res.prefix(24_000))).prefix(18).forEach { add(url: $0, title: nil) }
                }
            }
        }
        return items
    }

    private static func extractURLs(from text: String) -> [String] {
        guard text.contains("http") else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: nsRange).compactMap { match in
            match.url?.absoluteString
        }
    }
}

struct TurnSourcesPill: View {
    let sources: [TurnSourceItem]
    var action: () -> Void

    private var distinctDomains: [String] {
        var seen: Set<String> = []
        var list: [String] = []
        for s in sources where !seen.contains(s.domain) {
            seen.insert(s.domain)
            list.append(s.domain)
            if list.count == 3 { break }
        }
        return list
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                HStack(spacing: -5) {
                    ForEach(Array(distinctDomains.enumerated()), id: \.offset) { _, domain in
                        SourceDomainBadge(domain: domain, size: 17)
                    }
                }
                Text("\(sources.count) \(sources.count == 1 ? "source" : "sources")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(sources.count) sources")
    }
}

struct SourceDomainBadge: View {
    let domain: String
    var size: CGFloat = 20

    private var letter: String {
        String(domain.first ?? "w").uppercased()
    }

    private var color: Color {
        var hash: UInt64 = 5381
        for b in domain.utf8 { hash = ((hash << 5) &+ hash) &+ UInt64(b) }
        let palette: [Color] = [.blue, .purple, .indigo, .teal, .orange, .pink, .mint]
        return palette[Int(hash % UInt64(palette.count))]
    }

    var body: some View {
        ZStack {
            Circle().fill(color)
            Text(letter)
                .font(.system(size: size * 0.54, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.4))
    }
}

struct TurnSourcesSheet: View {
    let sources: [TurnSourceItem]
    var onOpenURL: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(sources) { item in
                    Button {
                        if let url = URL(string: item.url) {
                            onOpenURL(url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SourceDomainBadge(domain: item.domain, size: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(item.domain)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = item.url
                            Haptics.selection()
                        } label: {
                            Label("Copy link", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("\(sources.count) \(sources.count == 1 ? "Source" : "Sources")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Message & Turn Timestamps

@MainActor
enum MessageTimestampFormatter {
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let monthDayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f
    }()

    static func shortTime(_ date: Date) -> String {
        timeOnly.string(from: date)
    }

    static func sectionHeader(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return "Today \(timeOnly.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(timeOnly.string(from: date))"
        }
        return monthDayAndTime.string(from: date)
    }

    static func turnFooterTime(finishedAt: Date, durationSeconds: Int?, preferRelative: Bool) -> String {
        let whenText: String
        if preferRelative {
            whenText = relativeString(for: finishedAt)
        } else if Calendar.current.isDateInToday(finishedAt) {
            whenText = timeOnly.string(from: finishedAt)
        } else if Calendar.current.isDateInYesterday(finishedAt) {
            whenText = "Yesterday \(timeOnly.string(from: finishedAt))"
        } else {
            whenText = monthDayAndTime.string(from: finishedAt)
        }
        if let durationSeconds, durationSeconds > 0 {
            return "\(formatDuration(durationSeconds)) · \(whenText)"
        }
        return whenText
    }

    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let mins = seconds / 60
        let rem = seconds % 60
        return rem == 0 ? "\(mins)m" : "\(mins)m \(rem)s"
    }

    private static func relativeString(for date: Date) -> String {
        let diff = max(0, Int(Date().timeIntervalSince(date)))
        if diff < 45 { return "just now" }
        if diff < 3600 { return "\(max(1, diff / 60))m ago" }
        if diff < 86_400 { return "\(max(1, diff / 3600))h ago" }
        return "\(max(1, diff / 86_400))d ago"
    }
}

@MainActor
enum SharePresenter {
    static func present(items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        }
        top.present(vc, animated: true)
    }
}
