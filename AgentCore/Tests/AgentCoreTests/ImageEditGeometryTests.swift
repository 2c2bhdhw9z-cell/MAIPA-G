import Testing
@testable import AgentCore

@Suite("Image editing brush coordinates")
struct ImageEditGeometryTests {
    @Test("Aspect-fit maps square, portrait, landscape, and letterboxed images")
    func aspectFitMapping() throws {
        let squareSource = ImageEditSize(width: 1000, height: 1000)
        let portraitSource = ImageEditSize(width: 800, height: 1200)
        let landscapeSource = ImageEditSize(width: 1600, height: 900)
        let canvas = ImageEditSize(width: 400, height: 300)

        let square = try #require(ImageEditGeometry.displayedImageRect(source: squareSource, canvas: canvas))
        #expect(square.minX == 50)
        #expect(square.minY == 0)
        #expect(square.width == 300)
        #expect(square.height == 300)

        let portrait = try #require(ImageEditGeometry.displayedImageRect(source: portraitSource, canvas: canvas))
        #expect(portrait.minX == 100)
        #expect(portrait.minY == 0)
        #expect(portrait.width == 200)
        #expect(portrait.height == 300)

        let landscape = try #require(ImageEditGeometry.displayedImageRect(source: landscapeSource, canvas: canvas))
        #expect(landscape.minX == 0)
        #expect(landscape.minY == 37.5)
        #expect(landscape.width == 400)
        #expect(landscape.height == 225)
        #expect(ImageEditGeometry.sourcePoint(for: ImageEditPoint(x: 25, y: 20), source: landscapeSource, canvas: canvas) == nil)
    }

    @Test("The same source point remains stable after resizing and zoom/pan")
    func stableAcrossViewportChanges() throws {
        let source = ImageEditSize(width: 2048, height: 1024)
        let normalized = ImageBrushPoint(x: 0.37, y: 0.62)
        let viewports: [(ImageEditSize, Double, ImageEditPoint)] = [
            (ImageEditSize(width: 400, height: 300), 1, ImageEditPoint(x: 0, y: 0)),
            (ImageEditSize(width: 700, height: 500), 1.6, ImageEditPoint(x: -35, y: 18)),
            (ImageEditSize(width: 320, height: 700), 2.25, ImageEditPoint(x: 22, y: -47))
        ]
        for (canvas, zoom, pan) in viewports {
            let rendered = try #require(ImageEditGeometry.canvasPoint(for: normalized, source: source, canvas: canvas, zoom: zoom, pan: pan))
            let mapped = try #require(ImageEditGeometry.sourcePoint(for: rendered, source: source, canvas: canvas, zoom: zoom, pan: pan))
            #expect(abs(mapped.x - normalized.x) < 0.000_001)
            #expect(abs(mapped.y - normalized.y) < 0.000_001)
        }
    }

    @Test("Brush can land on every image edge but letterbox touches are rejected")
    func edgeAndLetterboxHandling() throws {
        let source = ImageEditSize(width: 1200, height: 800)
        let canvas = ImageEditSize(width: 300, height: 300)
        let rect = try #require(ImageEditGeometry.displayedImageRect(source: source, canvas: canvas))
        #expect(ImageEditGeometry.sourcePoint(for: ImageEditPoint(x: rect.minX, y: rect.minY), source: source, canvas: canvas)?.x == 0)
        #expect(ImageEditGeometry.sourcePoint(for: ImageEditPoint(x: rect.maxX, y: rect.maxY), source: source, canvas: canvas)?.y == 1)
        #expect(ImageEditGeometry.sourcePoint(for: ImageEditPoint(x: 150, y: 20), source: source, canvas: canvas) == nil)
        #expect(ImageEditGeometry.displayedImageRect(source: ImageEditSize(width: 0, height: 5), canvas: canvas) == nil)
    }
}
