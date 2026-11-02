import Foundation

/// A single-channel 8-bit mask. For the documented FLUX Fill convention, 0 (black) preserves and
/// 255 (white) marks pixels for replacement.
public struct ImageEditMaskRaster: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var pixels: Data
    public init(width: Int, height: Int, pixels: Data) {
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public enum ImageEditMaskRasterError: Error, Sendable, Equatable {
    case invalidDimensions
    case tooManyPixels
    case tooComplex
    case invalidStroke
}

public enum ImageEditMaskRasterizer {
    public static let maximumPixels = 32_000_000
    public static let maximumDimension = 8_192
    public static let maximumRasterWorkUnits = 50_000_000

    public static func validate(_ mask: ImageEditMask) throws {
        let width = mask.sourcePixelWidth
        let height = mask.sourcePixelHeight
        guard width > 0, height > 0, width <= Int.max / height else { throw ImageEditMaskRasterError.invalidDimensions }
        guard width <= maximumDimension, height <= maximumDimension else { throw ImageEditMaskRasterError.tooManyPixels }
        guard width * height <= maximumPixels else { throw ImageEditMaskRasterError.tooManyPixels }
        guard !mask.strokes.isEmpty else { throw ImageEditMaskRasterError.invalidStroke }
        for stroke in mask.strokes {
            guard stroke.radius.isFinite, stroke.radius > 0, stroke.radius <= 0.5,
                  stroke.feather.isFinite, (0...1).contains(stroke.feather),
                  !stroke.points.isEmpty, stroke.points.count <= 100_000,
                  stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
                throw ImageEditMaskRasterError.invalidStroke
            }
        }
    }

    public static func rasterize(_ mask: ImageEditMask) throws -> ImageEditMaskRaster {
        try validate(mask)
        let width = mask.sourcePixelWidth
        let height = mask.sourcePixelHeight
        let count = width * height
        var pixels = [UInt8](repeating: 0, count: count)
        var remainingWork = maximumRasterWorkUnits
        for stroke in mask.strokes {
            let radius = max(0.5, stroke.radius * Double(min(width, height)))
            let points = stroke.points.map { (x: $0.x * Double(width - 1), y: $0.y * Double(height - 1)) }
            if points.count == 1 {
                try stamp(centerX: points[0].x, centerY: points[0].y, radius: radius, width: width, height: height, pixels: &pixels, remainingWork: &remainingWork)
            } else {
                for index in 1..<points.count {
                    let from = points[index - 1]
                    let to = points[index]
                    let distance = hypot(to.x - from.x, to.y - from.y)
                    let steps = max(1, Int(ceil(distance / max(radius * 0.5, 0.5))))
                    for step in 0...steps {
                        let t = Double(step) / Double(steps)
                        try stamp(
                            centerX: from.x + (to.x - from.x) * t,
                            centerY: from.y + (to.y - from.y) * t,
                            radius: radius,
                            width: width,
                            height: height,
                            pixels: &pixels,
                            remainingWork: &remainingWork
                        )
                    }
                }
            }
        }
        return ImageEditMaskRaster(width: width, height: height, pixels: Data(pixels))
    }

    private static func stamp(
        centerX: Double,
        centerY: Double,
        radius: Double,
        width: Int,
        height: Int,
        pixels: inout [UInt8],
        remainingWork: inout Int
    ) throws {
        let minimumX = max(0, Int(floor(centerX - radius)))
        let maximumX = min(width - 1, Int(ceil(centerX + radius)))
        let minimumY = max(0, Int(floor(centerY - radius)))
        let maximumY = min(height - 1, Int(ceil(centerY + radius)))
        let work = (maximumX - minimumX + 1) * (maximumY - minimumY + 1)
        guard work <= remainingWork else { throw ImageEditMaskRasterError.tooComplex }
        remainingWork -= work
        let squaredRadius = radius * radius
        for y in minimumY...maximumY {
            for x in minimumX...maximumX {
                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                if dx * dx + dy * dy <= squaredRadius {
                    pixels[y * width + x] = 255
                }
            }
        }
    }
}
