import AgentCore
import Foundation
import ImageIO
import PDFKit
import UIKit

/// Decodes a thumbnail directly from compressed bytes and keeps an in-memory bounded cache so
/// scrolling past photo stacks, composer chips, generated images, or Canvas cards stays 120Hz smooth.
enum ImageDownsampler {
    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    nonisolated(unsafe) private static var registeredMemoryWarning = false

    private static func ensureMemoryObserver() {
        guard !registeredMemoryWarning else { return }
        registeredMemoryWarning = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            ImageDownsampler.clearMemoryCache()
        }
    }

    static func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    static func cachedImage(key: String, maxPixelSize: Int) -> UIImage? {
        memoryCache.object(forKey: "\(key)@\(maxPixelSize)" as NSString)
    }

    static func store(_ image: UIImage, key: String, maxPixelSize: Int) {
        ensureMemoryObserver()
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        memoryCache.setObject(image, forKey: "\(key)@\(maxPixelSize)" as NSString, cost: max(1, pixels * 4))
    }

    static func image(from data: Data, maxPixelSize: Int = 2_048, cacheKey: String? = nil) -> UIImage? {
        if let cacheKey, let cached = cachedImage(key: cacheKey, maxPixelSize: maxPixelSize) {
            return cached
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let decoded = UIImage(cgImage: cg)
        if let cacheKey {
            store(decoded, key: cacheKey, maxPixelSize: maxPixelSize)
        }
        return decoded
    }

    /// Loads and caches an attachment thumbnail off the main thread.
    static func attachmentThumbnail(
        _ attachment: AttachmentReference,
        store: AttachmentStore,
        maxPixelSize: Int
    ) async -> UIImage? {
        let key = "att-\(attachment.id.uuidString)"
        if let cached = cachedImage(key: key, maxPixelSize: maxPixelSize) {
            return cached
        }
        guard let data = try? await store.data(for: attachment) else { return nil }
        let isPDF = attachment.kind == .pdf || attachment.name.lowercased().hasSuffix(".pdf")
        return await Task.detached(priority: .userInitiated) {
            if isPDF {
                return Self.pdfThumbnail(from: data, maxPixelSize: maxPixelSize, cacheKey: key)
            }
            return Self.image(from: data, maxPixelSize: maxPixelSize, cacheKey: key)
        }.value
    }

    /// Renders page 1 of a PDF into a crisp preview image so PDFs appear visually on Canvas.
    static func pdfThumbnail(from data: Data, maxPixelSize: Int = 800, cacheKey: String? = nil) -> UIImage? {
        if let cacheKey, let cached = cachedImage(key: cacheKey, maxPixelSize: maxPixelSize) {
            return cached
        }
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(CGFloat(maxPixelSize) / max(bounds.width, bounds.height), 2.0)
        let targetSize = CGSize(width: max(40, bounds.width * scale), height: max(40, bounds.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: targetSize.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        if let cacheKey {
            store(rendered, key: cacheKey, maxPixelSize: maxPixelSize)
        }
        return rendered
    }
}
