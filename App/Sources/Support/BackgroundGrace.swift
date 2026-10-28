import UIKit

/// Asks iOS for a little more time when the app is sent to the background, so a reply that is
/// still coming in can finish (usually up to about 30 seconds). If time runs out first,
/// `onExpire` runs so the reply can be saved as stopped rather than lost.
@MainActor
final class BackgroundGrace {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpire()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
