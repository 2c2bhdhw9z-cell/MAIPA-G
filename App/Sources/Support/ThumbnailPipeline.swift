import AVFoundation
import AgentCore
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// The small pictures shown for files: photos, a PDF's first page, a video's opening frame.
///
/// - Sizes are rounded up to 128, 256, 512 or 1024 pixels, so cards at nearby zooms share one.
/// - Kept in memory (up to 160 MB / 1,500 pictures) and, up to 1024 pixels, on disk in Caches.
/// - Two cards asking for the same picture at the same size wait for one decode.
/// - At most four decodes run at once; one whose cards all scrolled away is dropped before it starts.
/// - Files are read straight from their path (no trip through the attachment store's queue),
///   decoded at the size needed rather than in full.
final class ThumbnailPipeline: @unchecked Sendable {
    static let shared = ThumbnailPipeline()

    static let buckets = [128, 256, 512, 1_024]

    /// The size a request is made at. Full-screen viewers ask for more than 1024 and get exactly that.
    static func bucket(for requested: Int) -> Int {
        for size in buckets where requested <= size {
            return size
        }
        return max(1, requested)
    }

    enum SourceKind: Sendable {
        case image
        case pdf
        case video
    }

    static func sourceKind(for attachment: AttachmentReference) -> SourceKind {
        let lowerName = attachment.name.lowercased()
        if attachment.kind == .image { return .image }
        if attachment.kind == .pdf || lowerName.hasSuffix(".pdf") { return .pdf }
        let ext = (lowerName as NSString).pathExtension
        if attachment.mimeType.lowercased().hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(ext) { return .video }
        return .image
    }

    /// The memory key for an attachment's picture (the same one ImageDownsampler has always used).
    static func key(for attachment: AttachmentReference) -> String {
        "att-\(attachment.id.uuidString)"
    }

    private let memory: NSCache<NSString, UIImage>
    private let work = ThumbnailWork()
    private let gate = ThumbnailDecodeGate(limit: 4)
    private let diskFolder: URL

    private init() {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 1_500
        cache.totalCostLimit = 160 * 1_024 * 1_024
        memory = cache
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("MAIPA-G/Thumbnails", isDirectory: true)
        diskFolder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            ThumbnailPipeline.shared.clearMemory()
        }
        Task.detached(priority: .background) {
            ThumbnailPipeline.trimDisk(folder)
        }
    }

    // MARK: Memory

    func clearMemory() {
        memory.removeAllObjects()
    }

    func cachedImage(key: String, maxPixelSize: Int) -> UIImage? {
        memory.object(forKey: "\(key)@\(maxPixelSize)" as NSString)
    }

    func store(_ image: UIImage, key: String, maxPixelSize: Int) {
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        memory.setObject(image, forKey: "\(key)@\(maxPixelSize)" as NSString, cost: max(1, pixels * 4))
    }

    /// The picture for this attachment at this size, if it's already in memory.
    func cachedThumbnail(for attachment: AttachmentReference, maxPixelSize: Int) -> UIImage? {
        cachedImage(key: Self.key(for: attachment), maxPixelSize: Self.bucket(for: maxPixelSize))
    }

    /// The picture at this size, or else the largest smaller one already in memory, to show
    /// at once while the sharper one loads.
    func bestCachedThumbnail(for attachment: AttachmentReference, maxPixelSize: Int) -> UIImage? {
        bestCachedImage(key: Self.key(for: attachment), maxPixelSize: maxPixelSize)
    }

    func bestCachedImage(key: String, maxPixelSize: Int) -> UIImage? {
        let wanted = Self.bucket(for: maxPixelSize)
        if let exact = cachedImage(key: key, maxPixelSize: wanted) { return exact }
        for size in Self.buckets.reversed() where size < wanted {
            if let smaller = cachedImage(key: key, maxPixelSize: size) { return smaller }
        }
        return nil
    }

    // MARK: Loading

    /// A photo, a PDF's first page or a video's frame for this attachment. Returns nil when
    /// the file can't be read, and when the asking task was cancelled (its card went away).
    func thumbnail(for attachment: AttachmentReference, store: AttachmentStore, maxPixelSize: Int) async -> UIImage? {
        let pixels = Self.bucket(for: maxPixelSize)
        let key = Self.key(for: attachment)
        if let cached = cachedImage(key: key, maxPixelSize: pixels) { return cached }
        guard let url = try? store.fileURL(for: attachment) else { return nil }
        let kind = Self.sourceKind(for: attachment)
        let diskName = "\(attachment.id.uuidString.lowercased())-\(attachment.bytes)-\(pixels)"
        return await work.run(ThumbnailJobKey(key: key, pixels: pixels)) { [self] in
            await self.make(kind: kind, url: url, key: key, pixels: pixels, diskName: diskName)
        }
    }

    /// A picture from bytes in memory (a staged file), decoded off the main thread.
    func thumbnail(data: Data, key: String, maxPixelSize: Int) async -> UIImage? {
        let pixels = Self.bucket(for: maxPixelSize)
        if let cached = cachedImage(key: key, maxPixelSize: pixels) { return cached }
        return await work.run(ThumbnailJobKey(key: key, pixels: pixels)) { [self] in
            guard await self.gate.acquire() else { return nil }
            let image = Task.isCancelled ? nil : ImageDownsampler.image(from: data, maxPixelSize: pixels)
            await self.gate.release()
            if let image { self.store(image, key: key, maxPixelSize: pixels) }
            return image
        }
    }

    private func make(kind: SourceKind, url: URL, key: String, pixels: Int, diskName: String) async -> UIImage? {
        guard await gate.acquire() else { return nil }
        let image = await decode(kind: kind, url: url, pixels: pixels, diskName: diskName)
        await gate.release()
        if let image { store(image, key: key, maxPixelSize: pixels) }
        return image
    }

    private func decode(kind: SourceKind, url: URL, pixels: Int, diskName: String) async -> UIImage? {
        if Task.isCancelled { return nil }
        let usesDisk = pixels <= Self.buckets[Self.buckets.count - 1]
        if usesDisk, let saved = readDisk(diskName) { return saved }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let image: UIImage?
        switch kind {
        case .image: image = Self.decodeImage(at: url, maxPixelSize: pixels)
        case .pdf: image = PDFDocument(url: url)?.page(at: 0).flatMap { ImageDownsampler.renderPDFPage($0, maxPixelSize: pixels) }
        case .video: image = await Self.videoPoster(at: url, maxPixelSize: pixels)
        }
        if usesDisk, let image { writeDisk(image, name: diskName) }
        return image
    }

    /// Decodes straight from the file at the size needed, already drawn, turned the right way up.
    static func decodeImage(at url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A frame from the first second of a video, the right way up.
    static func videoPoster(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var seconds = 0.0
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
            seconds = min(1.0, duration.seconds / 3)
        }
        guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: frame)
    }

    // MARK: Disk

    private func readDisk(_ name: String) -> UIImage? {
        for ext in ["jpg", "png"] {
            let url = diskFolder.appendingPathComponent("\(name).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let cg = CGImageSourceCreateImageAtIndex(source, 0, options) {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    private func writeDisk(_ image: UIImage, name: String) {
        guard let cg = image.cgImage else { return }
        let opaque: Bool
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: opaque = true
        default: opaque = false
        }
        let type = opaque ? UTType.jpeg : UTType.png
        let url = diskFolder.appendingPathComponent("\(name).\(opaque ? "jpg" : "png")")
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (output as Data).write(to: url, options: .atomic)
    }

    /// Keeps the disk copies small: past 150 MB, the oldest go until 100 MB is left.
    private static func trimDisk(_ folder: URL) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0
            total += size
            entries.append((url: file, size: size, date: values.contentModificationDate ?? .distantPast))
        }
        guard total > 150 * 1_024 * 1_024 else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > 100 * 1_024 * 1_024 else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

struct ThumbnailJobKey: Hashable, Sendable {
    let key: String
    let pixels: Int
}

/// One decode per picture and size, however many cards wait for it. When every card waiting
/// has gone, the decode is cancelled.
actor ThumbnailWork {
    private final class Job {
        let task: Task<UIImage?, Never>
        var waiters: Set<UInt64> = []

        init(task: Task<UIImage?, Never>) {
            self.task = task
        }
    }

    private var jobs: [ThumbnailJobKey: Job] = [:]
    private var nextWaiter: UInt64 = 0

    func run(_ key: ThumbnailJobKey, make: @escaping @Sendable () async -> UIImage?) async -> UIImage? {
        if Task.isCancelled { return nil }
        let job: Job
        if let existing = jobs[key] {
            job = existing
        } else {
            job = Job(task: Task.detached(priority: .userInitiated) { await make() })
            jobs[key] = job
        }
        nextWaiter &+= 1
        let waiter = nextWaiter
        job.waiters.insert(waiter)
        let image = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            Task { await self.leave(key, waiter: waiter) }
        }
        job.waiters.remove(waiter)
        if job.waiters.isEmpty, jobs[key] === job { jobs[key] = nil }
        return Task.isCancelled ? nil : image
    }

    private func leave(_ key: ThumbnailJobKey, waiter: UInt64) {
        guard let job = jobs[key], job.waiters.remove(waiter) != nil, job.waiters.isEmpty else { return }
        job.task.cancel()
        jobs[key] = nil
    }
}

/// At most `limit` decodes at once; the rest wait their turn, and leave the queue if cancelled.
actor ThumbnailDecodeGate {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID: UInt64 = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// True once a slot is taken (call `release()` after); false if cancelled while waiting.
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        nextID &+= 1
        let id = nextID
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiting.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Cancelled just as a slot came free: hand it on rather than decode for nobody.
        if granted, Task.isCancelled {
            release()
            return false
        }
        return granted
    }

    func release() {
        if waiting.isEmpty {
            running = max(0, running - 1)
        } else {
            // The slot passes straight to the next in line.
            let next = waiting.removeFirst()
            next.continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let position = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: position)
        waiter.continuation.resume(returning: false)
    }
}
