import Foundation
import UIKit
import UniformTypeIdentifiers

/// Continuum's proven Files-picker pattern: UIKit instead of SwiftUI's `.fileImporter`, an
/// app-owned copy, a strongly retained delegate, and the bytes read before the temporary copy can
/// disappear. The singleton deliberately owns both the picker and its weak delegate (itself).
final class AttachmentFilePicker: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    @MainActor static let shared = AttachmentFilePicker()

    private var activePicker: UIDocumentPickerViewController?
    private var onPick: ((Data, String) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var outcomeDelivered = false

    @MainActor
    func present(onPick: @escaping (Data, String) -> Void, onFailure: @escaping (String) -> Void) {
        guard activePicker == nil else { return }
        guard AppPresenter.topmostViewController() != nil else {
            onFailure("There is no screen to show the file picker on.")
            return
        }
        self.onPick = onPick
        self.onFailure = onFailure
        outcomeDelivered = false

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.presentationController?.delegate = self
        activePicker = picker
        AppPresenter.whenSettled("file picker") { [weak self, weak picker] presenter in
            guard let self, let picker else { return }
            presenter.present(picker, animated: true)
            picker.presentationController?.delegate = self
        }
    }

    @objc func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            settle { _, fail in fail?("No file was picked.") }
            return
        }
        let name = url.lastPathComponent
        do {
            // `asCopy: true` gives this app a temporary copy. Read it before dismissing or hopping
            // to another task because a File Provider may remove it immediately afterwards.
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            settle { pick, _ in pick?(data, name) }
        } catch {
            settle { _, fail in fail?("\(name) couldn't be read: \(error.localizedDescription)") }
        }
    }

    /// Kept beside the modern array callback, as Continuum does, so a provider that delivers only
    /// the older callback still returns the selected file.
    @objc func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    @objc func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        settle { _, _ in }
    }

    @objc func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !outcomeDelivered else { return }
        settle { _, _ in }
    }

    private func settle(_ deliver: @escaping (((Data, String) -> Void)?, ((String) -> Void)?) -> Void) {
        guard !outcomeDelivered else { return }
        outcomeDelivered = true
        Task { @MainActor in
            let pick = self.onPick
            let failure = self.onFailure
            self.onPick = nil
            self.onFailure = nil
            self.activePicker = nil
            deliver(pick, failure)
        }
    }
}

/// Finds the live UIKit screen under SwiftUI and waits for menus/sheets to finish dismissing before
/// presenting another controller. This is the same presentation discipline Continuum uses.
@MainActor
enum AppPresenter {
    static func topmostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene else { return nil }
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        guard var top = window?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    static func whenSettled(
        _ what: String,
        attempt: Int = 0,
        _ body: @escaping @MainActor (UIViewController) -> Void
    ) {
        guard let top = topmostViewController() else { return }
        let busy = top.isBeingPresented || top.isBeingDismissed || top.transitionCoordinator != nil
            || top.presentedViewController?.isBeingDismissed == true
        if busy, attempt < 12 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                whenSettled(what, attempt: attempt + 1, body)
            }
            return
        }
        body(top)
    }
}
