import Foundation
import UIKit
import UniformTypeIdentifiers

/// Continuum's proven Files-picker pattern: UIKit instead of SwiftUI's `.fileImporter`, an
/// app-owned staged file copy on disk (never loading 250 MB files into RAM simultaneously),
/// and a strongly retained delegate.
final class AttachmentFilePicker: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    @MainActor static let shared = AttachmentFilePicker()

    struct PickedTempFile: Sendable {
        let url: URL
        let name: String
    }

    private var activePicker: UIDocumentPickerViewController?
    private var onPick: (([PickedTempFile]) -> Void)?
    private var onFailure: ((String) -> Void)?
    private var outcomeDelivered = false

    @MainActor
    func present(onPick: @escaping ([PickedTempFile]) -> Void, onFailure: @escaping (String) -> Void) {
        if let stale = activePicker, stale.presentingViewController == nil && !stale.isBeingPresented {
            activePicker = nil
            self.onPick = nil
            self.onFailure = nil
            outcomeDelivered = false
        }
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
        picker.allowsMultipleSelection = true
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
        guard !urls.isEmpty else {
            settle { _, fail in fail?("No file was picked.") }
            return
        }
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("maipag-picked-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var picked: [PickedTempFile] = []
        var failed: [String] = []
        for (index, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let stagedURL = stagingDir.appendingPathComponent("\(index)-\(name.isEmpty ? "file" : name)")
            do {
                // Move or hard-copy the File Provider's temporary file on disk right away without
                // reading multi-hundred-MB files into RAM.
                if (try? FileManager.default.moveItem(at: url, to: stagedURL)) == nil {
                    try FileManager.default.copyItem(at: url, to: stagedURL)
                }
                picked.append(PickedTempFile(url: stagedURL, name: name))
            } catch {
                failed.append("\(name) (\(error.localizedDescription))")
            }
        }
        settle { pick, fail in
            if !picked.isEmpty { pick?(picked) }
            if !failed.isEmpty {
                fail?("Couldn't read: \(failed.joined(separator: ", "))")
            }
        }
    }

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

    private func settle(_ deliver: @escaping ((([PickedTempFile]) -> Void)?, ((String) -> Void)?) -> Void) {
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
