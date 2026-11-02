import Testing
@testable import AgentCore

@Suite("Brush mask rasterization")
struct ImageEditMaskRasterizerTests {
    @Test("Mask matches the recorded dimensions and uses black-preserve, white-edit polarity")
    func dimensionsAndPolarity() throws {
        let mask = ImageEditMask(
            sourcePixelWidth: 11,
            sourcePixelHeight: 9,
            strokes: [ImageBrushStroke(points: [ImageBrushPoint(x: 0.5, y: 0.5)], radius: 0.2)]
        )
        let raster = try ImageEditMaskRasterizer.rasterize(mask)
        #expect(raster.width == 11)
        #expect(raster.height == 9)
        #expect(raster.pixels.count == 99)
        #expect(raster.pixels[4 * 11 + 5] == 255)
        #expect(raster.pixels[0] == 0)
        #expect(raster.pixels[8 * 11 + 10] == 0)
    }

    @Test("Edge points stay in bounds and continuous strokes do not leave gaps")
    func edgesAndContinuity() throws {
        let mask = ImageEditMask(
            sourcePixelWidth: 32,
            sourcePixelHeight: 16,
            strokes: [
                ImageBrushStroke(points: [ImageBrushPoint(x: 0, y: 0)], radius: 0.08),
                ImageBrushStroke(points: [ImageBrushPoint(x: 0.1, y: 0.5), ImageBrushPoint(x: 0.9, y: 0.5)], radius: 0.04)
            ]
        )
        let raster = try ImageEditMaskRasterizer.rasterize(mask)
        #expect(raster.pixels[0] == 255)
        #expect(raster.pixels[15 * 32 + 31] == 0)
        for x in 4...27 { #expect(raster.pixels[7 * 32 + x] == 255) }
    }

    @Test("Unsafe dimensions and malformed geometry are rejected")
    func rejectsUnsafeInput() {
        #expect(throws: ImageEditMaskRasterError.self) {
            try ImageEditMaskRasterizer.rasterize(ImageEditMask(sourcePixelWidth: 0, sourcePixelHeight: 8, strokes: []))
        }
        #expect(throws: ImageEditMaskRasterError.self) {
            try ImageEditMaskRasterizer.rasterize(ImageEditMask(sourcePixelWidth: 6000, sourcePixelHeight: 6000, strokes: []))
        }
        #expect(throws: ImageEditMaskRasterError.self) {
            try ImageEditMaskRasterizer.rasterize(ImageEditMask(
                sourcePixelWidth: 8,
                sourcePixelHeight: 8,
                strokes: [ImageBrushStroke(points: [ImageBrushPoint(x: 1.2, y: 0.5)], radius: 0.1)]
            ))
        }
    }
}
