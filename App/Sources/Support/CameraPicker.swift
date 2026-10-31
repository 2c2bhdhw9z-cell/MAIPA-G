import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The iPhone camera, kept separate from Photo Library so "Take Photo" really opens the camera.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPhoto: (Data) -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.owner = self
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var owner: CameraPicker

        init(owner: CameraPicker) { self.owner = owner }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            owner.isPresented = false
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let capturedImage = info[.originalImage] as? UIImage
            let callback = owner.onPhoto
            // Dismiss immediately so the camera close animation never stalls while encoding 48 MP photos.
            owner.isPresented = false
            guard let capturedImage else { return }
            let box = UncheckedImageBox(image: capturedImage)
            Task { @MainActor in
                guard let data = await Self.encodeCameraJPEG(box) else { return }
                callback(data)
            }
        }

        nonisolated private static func encodeCameraJPEG(_ box: UncheckedImageBox) async -> Data? {
            await Task.detached(priority: .userInitiated) {
                let maxDim: CGFloat = 2_048
                let size = box.image.size
                let scale = min(1.0, maxDim / max(max(size.width, size.height), 1))
                let targetSize = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = 1.0
                let scaled = scale < 1.0
                    ? UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                        box.image.draw(in: CGRect(origin: .zero, size: targetSize))
                    }
                    : box.image
                return scaled.jpegData(compressionQuality: 0.86)
            }.value
        }
    }

    private struct UncheckedImageBox: @unchecked Sendable {
        let image: UIImage
    }
}
