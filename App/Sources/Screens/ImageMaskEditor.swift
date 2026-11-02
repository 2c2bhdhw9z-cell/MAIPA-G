import AgentCore
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Brush-mask editor. Brush coordinates are stored in normalized source-image space, never in
/// screen points, so resize, zoom, and pan cannot move the selected region.
struct ImageMaskEditor: View {
    let source: AttachmentReference
    let image: UIImage
    let onPrepare: (Data, ImageEditMask, String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var originalPixelSize: (width: Int, height: Int)?
    @State private var strokes: [ImageBrushStroke] = []
    @State private var activeStroke: ImageBrushStroke?
    @State private var instruction = ""
    @State private var brushRadius = 0.035
    @State private var zoom = 1.0
    @State private var pan = ImageEditPoint(x: 0, y: 0)
    @State private var panAtGestureStart = ImageEditPoint(x: 0, y: 0)
    @State private var zoomAtGestureStart = 1.0
    @State private var navigationMode = false
    @State private var prepared = false
    @State private var confirmDiscard = false
    @State private var error: String?

    private var pixelWidth: Int { originalPixelSize?.width ?? image.cgImage?.width ?? Int(image.size.width * image.scale) }
    private var pixelHeight: Int { originalPixelSize?.height ?? image.cgImage?.height ?? Int(image.size.height * image.scale) }
    private var sourceSize: ImageEditSize { ImageEditSize(width: Double(pixelWidth), height: Double(pixelHeight)) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Editing \(source.name). Painted areas are the parts that will change. Use Navigate to zoom or move the picture; brush marks remain attached to the image.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Painted areas are the parts that will change. Orange fill and dashed outlines show selected areas.")

                GeometryReader { proxy in
                    let canvas = ImageEditSize(width: Double(proxy.size.width), height: Double(proxy.size.height))
                    Canvas { context, size in
                        let canvasSize = ImageEditSize(width: Double(size.width), height: Double(size.height))
                        guard let imageRect = ImageEditGeometry.displayedImageRect(
                            source: sourceSize,
                            canvas: canvasSize,
                            zoom: zoom,
                            pan: pan
                        ) else { return }
                        let rect = CGRect(x: CGFloat(imageRect.minX), y: CGFloat(imageRect.minY), width: CGFloat(imageRect.width), height: CGFloat(imageRect.height))
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.92)))
                        context.clip(to: Path(rect))
                        context.draw(Image(uiImage: image), in: rect)
                        for stroke in strokes + (activeStroke.map { [$0] } ?? []) {
                            draw(stroke, in: &context, imageRect: imageRect)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(brushGesture(canvas: canvas), including: navigationMode ? .none : .all)
                    .simultaneousGesture(panGesture, including: navigationMode ? .all : .none)
                    .simultaneousGesture(magnificationGesture, including: navigationMode ? .all : .none)
                    .accessibilityLabel("Image mask canvas. Painted areas will be changed by the edit.")
                }
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.16)))

                HStack(spacing: 10) {
                    Toggle(isOn: $navigationMode) {
                        Label(navigationMode ? "Navigate" : "Brush", systemImage: navigationMode ? "hand.draw" : "paintbrush.pointed.fill")
                    }
                    .toggleStyle(.button)
                    .accessibilityHint(navigationMode ? "Turn off navigation to paint the edit mask." : "Turn on navigation to pan and zoom the source image.")
                    if navigationMode {
                        Button("Reset view") { withAnimation { zoom = 1; zoomAtGestureStart = 1; pan = ImageEditPoint(x: 0, y: 0); panAtGestureStart = pan } }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Undo") { undo() }
                            .buttonStyle(.bordered)
                            .disabled(strokes.isEmpty && activeStroke == nil)
                        Button("Clear") { strokes.removeAll(); activeStroke = nil }
                            .buttonStyle(.bordered)
                            .disabled(strokes.isEmpty && activeStroke == nil)
                    }
                }

                if !navigationMode {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Brush size")
                            Spacer()
                            Text("\(Int(brushRadius * 200))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $brushRadius, in: 0.01...0.12)
                            .accessibilityLabel("Brush size")
                    }
                }

                TextField("Describe the change…", text: $instruction, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Edit instruction")

                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("Prepare edit mask") { prepareMask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(originalPixelSize == nil || (strokes.isEmpty && activeStroke == nil) || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if originalPixelSize == nil {
                    Text("Checking the full-size source image…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Preparing a mask is local. The provider request and any charge must wait for the verified provider to be enabled and your approval.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Brush edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancelEditor() } }
            }
            .interactiveDismissDisabled((!strokes.isEmpty || activeStroke != nil || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !prepared)
            .confirmationDialog("Discard this unsent mask?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard mask", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your brush marks and instruction have not been sent or saved.")
            }
            .alert("Mask prepared", isPresented: $prepared) {
                Button("Done", role: .cancel) { dismiss() }
            } message: {
                Text("The painted mask was prepared locally. No image was uploaded and no edit was requested.")
            }
            .task { await loadOriginalPixelSize() }
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                pan = ImageEditPoint(x: panAtGestureStart.x + Double(value.translation.width), y: panAtGestureStart.y + Double(value.translation.height))
            }
            .onEnded { _ in panAtGestureStart = pan }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = min(max(zoomAtGestureStart * Double(value), 1), 6) }
            .onEnded { _ in zoomAtGestureStart = zoom }
    }

    private func brushGesture(canvas: ImageEditSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let point = ImageEditGeometry.sourcePoint(
                    for: ImageEditPoint(x: Double(value.location.x), y: Double(value.location.y)),
                    source: sourceSize,
                    canvas: canvas,
                    zoom: zoom,
                    pan: pan
                ) else {
                    if let current = activeStroke, !current.points.isEmpty { strokes.append(current) }
                    activeStroke = nil
                    return
                }
                if activeStroke == nil {
                    activeStroke = ImageBrushStroke(points: [point], radius: brushRadius)
                } else if activeStroke?.points.last != point {
                    activeStroke?.points.append(point)
                }
            }
            .onEnded { _ in
                if let current = activeStroke, !current.points.isEmpty { strokes.append(current) }
                activeStroke = nil
            }
    }

    private func draw(_ stroke: ImageBrushStroke, in context: inout GraphicsContext, imageRect: ImageEditRect) {
        let points = stroke.points.map { ImageEditPoint(x: $0.x, y: $0.y) }
        guard !points.isEmpty else { return }
        let screenPoints = points.map { ImageEditPoint(x: imageRect.minX + $0.x * imageRect.width, y: imageRect.minY + $0.y * imageRect.height) }
        let radius = stroke.radius * min(sourceSize.width, sourceSize.height) * min(imageRect.width / sourceSize.width, imageRect.height / sourceSize.height)
        let lineWidth = max(3, radius * 2)
        var path = Path()
        path.move(to: CGPoint(x: CGFloat(screenPoints[0].x), y: CGFloat(screenPoints[0].y)))
        if screenPoints.count == 1 {
            path.addLine(to: CGPoint(x: CGFloat(screenPoints[0].x + 0.01), y: CGFloat(screenPoints[0].y + 0.01)))
        } else {
            for point in screenPoints.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
        }
        context.stroke(path, with: .color(.orange.opacity(0.45)), style: StrokeStyle(lineWidth: CGFloat(lineWidth), lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: CGFloat(max(1, lineWidth * 0.08)), lineCap: .round, lineJoin: .round, dash: [4, 4]))
        if screenPoints.count == 1 {
            let dot = CGRect(x: CGFloat(screenPoints[0].x - lineWidth / 2), y: CGFloat(screenPoints[0].y - lineWidth / 2), width: CGFloat(lineWidth), height: CGFloat(lineWidth))
            context.fill(Path(ellipseIn: dot), with: .color(.orange.opacity(0.45)))
            context.stroke(Path(ellipseIn: dot), with: .color(.white.opacity(0.95)), lineWidth: CGFloat(max(1, lineWidth * 0.08)))
        }
    }

    private func cancelEditor() {
        if !strokes.isEmpty || activeStroke != nil || !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confirmDiscard = true
        } else {
            dismiss()
        }
    }

    private func undo() {
        if activeStroke != nil { activeStroke = nil }
        else if !strokes.isEmpty { strokes.removeLast() }
    }

    @MainActor
    private func loadOriginalPixelSize() async {
        do {
            let bytes = try await app.attachmentStore.data(for: source)
            guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
                error = "The original picture dimensions could not be read. The mask was not prepared."
                return
            }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let swapsAxes = (5...8).contains(orientation)
            let width = swapsAxes ? rawHeight : rawWidth
            let height = swapsAxes ? rawWidth : rawHeight
            guard width > 0, height > 0,
                  width <= ImageEditMaskRasterizer.maximumDimension,
                  height <= ImageEditMaskRasterizer.maximumDimension,
                  width <= ImageEditMaskRasterizer.maximumPixels / height else {
                error = "This original picture is too large for safe mask preparation. The mask was not prepared."
                return
            }
            originalPixelSize = (width, height)
        } catch {
            self.error = "The original picture could not be read safely. The mask was not prepared."
        }
    }

    private func prepareMask() {
        let allStrokes = strokes + (activeStroke.map { [$0] } ?? [])
        guard pixelWidth > 0, pixelHeight > 0, !allStrokes.isEmpty else { error = "Paint an area before preparing the mask."; return }
        let geometry = ImageEditMask(sourcePixelWidth: pixelWidth, sourcePixelHeight: pixelHeight, strokes: allStrokes)
        do {
            let raster = try ImageEditMaskRasterizer.rasterize(geometry)
            let colorSpace = CGColorSpaceCreateDeviceGray()
            guard let provider = CGDataProvider(data: raster.pixels as CFData),
                  let cgImage = CGImage(
                    width: raster.width,
                    height: raster.height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 8,
                    bytesPerRow: raster.width,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ),
                  let data = UIImage(cgImage: cgImage).pngData(), !data.isEmpty else {
                error = "The mask image could not be encoded."
                return
            }
            onPrepare(data, geometry, instruction.trimmingCharacters(in: .whitespacesAndNewlines))
            prepared = true
        } catch ImageEditMaskRasterError.tooManyPixels {
            error = "This picture is too large for a safe local mask. A supported resize policy is not available yet."
        } catch {
            self.error = "The brush mask could not be prepared safely."
        }
    }

}
