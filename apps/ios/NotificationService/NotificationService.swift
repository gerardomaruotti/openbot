import Foundation
import UserNotifications

/// All work is local and synchronous; the completion handler is never retained.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { handler(request.content); return }
        // Never display unverified sender text or trust a plaintext routing dictionary.
        content.title = "OpenBot"
        content.body = String(localized: "native.notifications.generic")
        content.subtitle = ""
        content.categoryIdentifier = NotificationPayload.categoryIdentifier
        if let sealed = content.userInfo["sealed"] as? String,
           let records = try? NotificationKeyStore().load(),
           let value = NotificationPayload.open(sealed, secrets: records) {
            if value.kind == "failed" {
                // Older hosts can still send failure alerts. Keep their diagnostics out of
                // notification previews and deliver them without an interruption or sound.
                content.title = "OpenBot"
                content.body = String(localized: "native.notifications.quietUpdate")
                content.subtitle = ""
                content.sound = nil
                content.interruptionLevel = .passive
            } else {
                content.title = value.title
                content.body = value.body
                content.subtitle = value.serverName ?? ""
            }
            content.threadIdentifier = value.scope + "/" + value.agentID
        }
        // Keep the seal: the app verifies it again when a person taps the notification.
        handler(content)
    }
}
