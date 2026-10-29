import Foundation
import UserNotifications

@MainActor
final class Notifications {
    private var asked = false

    func requestIfNeeded(enabled: Bool) {
        guard enabled, !asked, !PreviewScenes.isActive else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, enabled: Bool) {
        guard enabled, !PreviewScenes.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
