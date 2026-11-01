import Foundation
import UIKit

/// Asks iOS for background execution time when a reply, sub-agent batch, or save is in progress. If
/// iOS expires the assertion before the work finishes, `onExpire` hops safely to `@MainActor` without
/// assuming UIKit invoked the expiration block on the main thread.
@MainActor
final class BackgroundGrace {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String, onExpire: @escaping @MainActor @Sendable () -> Void) {
        identifier = Self.beginTask(name: name, owner: self, onExpire: onExpire)
    }

    nonisolated private static func beginTask(
        name: String,
        owner: BackgroundGrace,
        onExpire: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        MainActor.assumeIsolated {
            UIApplication.shared.beginBackgroundTask(withName: name) { [weak owner] in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        onExpire()
                        owner?.end()
                    }
                } else {
                    Task { @MainActor [weak owner] in
                        onExpire()
                        owner?.end()
                    }
                }
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
