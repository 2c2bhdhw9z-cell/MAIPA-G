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
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.92) {
                owner.onPhoto(data)
            }
            owner.isPresented = false
        }
    }
}
