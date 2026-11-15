import UIKit
import UserNotifications

@MainActor
final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var notifications: NativeNotifications? {
        didSet { if let pending { notifications?.receive(identifier: pending.id, sealed: pending.sealed); self.pending = nil } }
    }
    private var pending: (id: String, sealed: String)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Declare supported types at launch, before a first local alert is scheduled.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: NotificationPayload.categoryIdentifier, actions: [], intentIdentifiers: [], options: [])])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        notifications?.registered(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        notifications?.registrationFailed()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let localPreview = identifier.hasPrefix("native.preview.") && notification.request.trigger is UNTimeIntervalNotificationTrigger
        let sealed = notification.request.content.userInfo["sealed"] as? String
        Task { @MainActor [weak self] in
            completionHandler(localPreview ? [.banner, .sound] : self?.notifications?.presentation(sealed: sealed) ?? [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let isDefaultAction = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let sealed = response.notification.request.content.userInfo["sealed"] as? String
        let identifier = response.notification.request.identifier
        // UIKit updates its restoration snapshot from this completion. The async delegate
        // adapter can call it on a worker thread, so finish explicitly on the main actor.
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard isDefaultAction, let sealed, sealed.utf8.count <= 3_600, let self else { return }
            if let notifications = self.notifications { notifications.receive(identifier: identifier, sealed: sealed) }
            else { self.pending = (identifier, sealed) }
        }
    }
}
