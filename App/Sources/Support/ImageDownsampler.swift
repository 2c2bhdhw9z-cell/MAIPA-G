import AgentCore
import Foundation
import ImageIO
import PDFKit
import UIKit

/// Decodes a thumbnail directly from compressed bytes. Pictures are kept in ThumbnailPipeline's
/// memory cache, so scrolling past photo stacks, composer chips, generated images, or Canvas
/// cards stays smooth.
enum ImageDownsampler {
    static func clearMemoryCache() {
        ThumbnailPipeline.shared.clearMemory()
    }

    static func cachedImage(key: String, maxPixelSize: Int) -> UIImage? {
        ThumbnailPipeline.shared.cachedImage(key: key, maxPixelSize: maxPixelSize)
    }

    static func store(_ image: UIImage, key: String, maxPixelSize: Int) {
        ThumbnailPipeline.shared.store(image, key: key, maxPixelSize: maxPixelSize)
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

    /// Loads an attachment thumbnail off the main thread, through ThumbnailPipeline. The load
    /// carries on if the caller goes away, as it always has; views that can be cancelled call
    /// `ThumbnailPipeline.shared.thumbnail(for:store:maxPixelSize:)` instead.
    static func attachmentThumbnail(
        _ attachment: AttachmentReference,
        store: AttachmentStore,
        maxPixelSize: Int
    ) async -> UIImage? {
        if let cached = ThumbnailPipeline.shared.cachedThumbnail(for: attachment, maxPixelSize: maxPixelSize) {
            return cached
        }
        return await Task {
            await ThumbnailPipeline.shared.thumbnail(for: attachment, store: store, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Renders page 1 of a PDF into a crisp preview image so PDFs appear visually on Canvas.
    static func pdfThumbnail(from data: Data, maxPixelSize: Int = 800, cacheKey: String? = nil) -> UIImage? {
        if let cacheKey, let cached = cachedImage(key: cacheKey, maxPixelSize: maxPixelSize) {
            return cached
        }
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0),
              let rendered = renderPDFPage(page, maxPixelSize: maxPixelSize) else { return nil }
        if let cacheKey {
            store(rendered, key: cacheKey, maxPixelSize: maxPixelSize)
        }
        return rendered
    }

    /// One PDF page drawn on white, its longer side `maxPixelSize` pixels at most.
    static func renderPDFPage(_ page: PDFPage, maxPixelSize: Int) -> UIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(CGFloat(maxPixelSize) / max(bounds.width, bounds.height), 2.0)
        let targetSize = CGSize(width: max(40, bounds.width * scale), height: max(40, bounds.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: targetSize.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }
}
