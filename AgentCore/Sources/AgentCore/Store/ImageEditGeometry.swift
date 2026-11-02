import Foundation

/// Lightweight geometry types keep image-coordinate mapping testable without UIKit or SwiftUI.
public struct ImageEditPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct ImageEditSize: Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct ImageEditRect: Sendable, Hashable {
    public var minX: Double
    public var minY: Double
    public var width: Double
    public var height: Double
    public var maxX: Double { minX + width }
    public var maxY: Double { minY + height }
    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX; self.minY = minY; self.width = width; self.height = height
    }
    public func contains(_ point: ImageEditPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

/// Maps between the visible canvas and source pixels. The source image is aspect-fit, then
/// uniformly zoomed and panned; every brush point is returned in normalized source coordinates.
public enum ImageEditGeometry {
    public static func displayedImageRect(
        source: ImageEditSize,
        canvas: ImageEditSize,
        zoom: Double = 1,
        pan: ImageEditPoint = ImageEditPoint(x: 0, y: 0)
    ) -> ImageEditRect? {
        guard valid(source), valid(canvas), zoom.isFinite, zoom > 0,
              pan.x.isFinite, pan.y.isFinite else { return nil }
        let scale = min(canvas.width / source.width, canvas.height / source.height) * zoom
        let width = source.width * scale
        let height = source.height * scale
        return ImageEditRect(
            minX: (canvas.width - width) / 2 + pan.x,
            minY: (canvas.height - height) / 2 + pan.y,
            width: width,
            height: height
        )
    }

    public static func sourcePoint(
        for canvasPoint: ImageEditPoint,
        source: ImageEditSize,
        canvas: ImageEditSize,
        zoom: Double = 1,
        pan: ImageEditPoint = ImageEditPoint(x: 0, y: 0)
    ) -> ImageBrushPoint? {
        guard canvasPoint.x.isFinite, canvasPoint.y.isFinite,
              let rect = displayedImageRect(source: source, canvas: canvas, zoom: zoom, pan: pan),
              rect.contains(canvasPoint) else { return nil }
        return ImageBrushPoint(
            x: min(max((canvasPoint.x - rect.minX) / rect.width, 0), 1),
            y: min(max((canvasPoint.y - rect.minY) / rect.height, 0), 1)
        )
    }

    public static func canvasPoint(
        for sourcePoint: ImageBrushPoint,
        source: ImageEditSize,
        canvas: ImageEditSize,
        zoom: Double = 1,
        pan: ImageEditPoint = ImageEditPoint(x: 0, y: 0)
    ) -> ImageEditPoint? {
        guard sourcePoint.x.isFinite, sourcePoint.y.isFinite,
              (0...1).contains(sourcePoint.x), (0...1).contains(sourcePoint.y),
              let rect = displayedImageRect(source: source, canvas: canvas, zoom: zoom, pan: pan) else { return nil }
        return ImageEditPoint(x: rect.minX + sourcePoint.x * rect.width, y: rect.minY + sourcePoint.y * rect.height)
    }

    private static func valid(_ size: ImageEditSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
