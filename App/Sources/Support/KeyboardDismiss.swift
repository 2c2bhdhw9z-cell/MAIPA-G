import SwiftUI
import UIKit

/// Dismisses any open iPhone keyboard when the person swipes down, taps outside a text field, or
/// switches to another sheet, menu, or chat — with no floating "Done" bar needed.
@MainActor
enum KeyboardDismiss {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    static func installIfNeeded(in window: UIWindow) {
        if window.gestureRecognizers?.contains(where: { $0 is OutsideTapGestureRecognizer }) == true {
            return
        }
        let delegate = GestureDelegate.shared

        let tap = OutsideTapGestureRecognizer(target: delegate, action: #selector(GestureDelegate.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = delegate
        window.addGestureRecognizer(tap)

        let swipe = DownwardSwipeGestureRecognizer(target: delegate, action: #selector(GestureDelegate.handlePan(_:)))
        swipe.cancelsTouchesInView = false
        swipe.delaysTouchesBegan = false
        swipe.delaysTouchesEnded = false
        swipe.delegate = delegate
        window.addGestureRecognizer(swipe)
    }

    private final class OutsideTapGestureRecognizer: UITapGestureRecognizer {}
    private final class DownwardSwipeGestureRecognizer: UIPanGestureRecognizer {}

    @MainActor
    private final class GestureDelegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = GestureDelegate()
        private var dismissedDuringCurrentPan = false

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            KeyboardDismiss.dismiss()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                dismissedDuringCurrentPan = false
            case .changed:
                guard !dismissedDuringCurrentPan, let view = recognizer.view else { return }
                let translation = recognizer.translation(in: view)
                let velocity = recognizer.velocity(in: view)
                if translation.y > 24, velocity.y > 180, abs(translation.y) > abs(translation.x) * 1.4 {
                    dismissedDuringCurrentPan = true
                    KeyboardDismiss.dismiss()
                }
            default:
                dismissedDuringCurrentPan = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer is OutsideTapGestureRecognizer {
                var current: UIView? = touch.view
                while let view = current {
                    if view is UITextField || view is UITextView {
                        return false
                    }
                    let typeName = String(describing: type(of: view))
                    if typeName.contains("Keyboard")
                        || typeName.contains("TUICandidate")
                        || typeName.contains("UIInput")
                        || typeName.contains("EditMenu")
                        || typeName.contains("CalloutBar")
                        || typeName.contains("Autocomplete")
                    {
                        return false
                    }
                    current = view.superview
                }
                return true
            }
            if gestureRecognizer is DownwardSwipeGestureRecognizer {
                var current: UIView? = touch.view
                while let view = current {
                    let typeName = String(describing: type(of: view))
                    if typeName.contains("Keyboard")
                        || typeName.contains("TUICandidate")
                        || typeName.contains("UIInput")
                    {
                        return false
                    }
                    current = view.superview
                }
                return true
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

struct KeyboardDismissAttachment: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                KeyboardDismiss.installIfNeeded(in: window)
            }
        }
    }
}
