import CryptoKit
import Foundation
import Observation
import OSLog
import UIKit
import UserNotifications

@Observable
@MainActor
final class NativeNotifications {
    struct Destination: Identifiable {
        let id: String
        let push: OpenedPush
    }

    private(set) var permission: UNAuthorizationStatus = .notDetermined
    private(set) var enabled = UserDefaults.standard.bool(forKey: "native.notifications.enabled")
    private(set) var isBusy = false
    private(set) var problem: LocalizedStringResource?
    private(set) var pendingOpen: Destination?
    var routeFailed = false
    var visibleAgentID: String?
    private weak var connection: AgentConnection?
    private let keys = NotificationKeyStore()
    private var token: String?
    private var active = true
    private var lastRegistration: String?
    private var registration: Task<Void, Never>?
    private var generation = 0
    private var handled: [String] = []

    /// A deployment declaration for a private account relay. Empty for the upstream account service.
    var relayReady: Bool {
        let topic = Bundle.main.object(forInfoDictionaryKey: "OpenBotPushRelayTopic") as? String
        return topic == Bundle.main.bundleIdentifier && topic?.isEmpty == false
    }
    var hostSupportsPush: Bool { connection?.supportsPush == true }
    var isAllowed: Bool { [.authorized, .provisional, .ephemeral].contains(permission) }

    func bind(_ connection: AgentConnection) { self.connection = connection }

    func refresh() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if isAllowed { await prepareAuthorizedNotifications() }
        if enabled && isAllowed && relayReady { UIApplication.shared.registerForRemoteNotifications() }
        scheduleSync()
    }

    func requestPermission() async {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        let epoch = generation
        defer { isBusy = false }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            let currentPermission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard epoch == generation else { return }
            permission = currentPermission
            enabled = isAllowed
            UserDefaults.standard.set(enabled, forKey: "native.notifications.enabled")
            if isAllowed { await prepareAuthorizedNotifications() }
            if enabled && relayReady { UIApplication.shared.registerForRemoteNotifications() }
            scheduleSync()
        } catch { if epoch == generation { problem = "native.error.generic" } }
    }

    func disable() async {
        guard !isBusy else { return }
        isBusy = true
        problem = nil
        let epoch = generation
        defer { isBusy = false }
        enabled = false
        UserDefaults.standard.set(false, forKey: "native.notifications.enabled")
        if UIApplication.shared.isRegisteredForRemoteNotifications { UIApplication.shared.unregisterForRemoteNotifications() }
        token = nil
        await enqueueSync(force: true, reportFailure: true).value
        guard epoch == generation else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func preview() async {
        guard enabled, isAllowed, !isBusy else { return }
        isBusy = true
        problem = nil
        let epoch = generation
        defer { isBusy = false }
        let identifier = "native.preview." + UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = "OpenBot"
        content.categoryIdentifier = NotificationPayload.categoryIdentifier
        content.body = String(localized: "native.notifications.testBody")
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
            if epoch != generation { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier]) }
        } catch {
            let code = (error as NSError).code
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenBot", category: "NativeNotifications")
                .error("Local notification scheduling failed; code \(code, privacy: .public)")
            if epoch == generation { problem = "native.error.generic" }
        }
    }

    private func prepareAuthorizedNotifications() async {
        let center = UNUserNotificationCenter.current()
        // Repeat the declaration after the first authorization transition. A launch-time
        // declaration alone can precede creation of the system's local notification source.
        center.setNotificationCategories([UNNotificationCategory(
            identifier: NotificationPayload.categoryIdentifier, actions: [], intentIdentifiers: [], options: [])])
        _ = await center.notificationCategories()
    }

    func registered(_ data: Data) {
        guard enabled, isAllowed, relayReady, (8...256).contains(data.count) else { return }
        token = data.map { String(format: "%02x", $0) }.joined()
        scheduleSync()
    }

    func registrationFailed() { recordFailure("device-registration") }

    func connected() {
        lastRegistration = nil
        Task { await refresh() }
    }

    func setActive(_ value: Bool) async {
        active = value
        // Tell the host before pausing RTC. Its held-event policy also handles sudden suspension.
        await enqueueSync(force: true).value
        if value { await refresh() }
    }

    func retain(_ scopes: Set<String>) {
        do {
            let old = try keys.load()
            let retained = old.filter { scopes.contains($0.scope) }
            if retained.count != old.count { try keys.save(retained) }
        } catch { recordFailure("key-retention") }
    }

    func clear() {
        problem = nil
        generation += 1
        registration?.cancel(); registration = nil
        lastRegistration = nil; token = nil; pendingOpen = nil; visibleAgentID = nil
        if UIApplication.shared.isRegisteredForRemoteNotifications { UIApplication.shared.unregisterForRemoteNotifications() }
        do { try keys.clear() }
        catch { recordFailure("key-removal"); problem = "native.error.generic" }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func presentation(sealed: String?) -> UNNotificationPresentationOptions {
        guard enabled, isAllowed, connection?.isAuthenticated == true, let sealed,
              let records = try? keys.load(), let value = NotificationPayload.open(sealed, secrets: records),
              value.kind != "failed" else { return [] }
        if connection?.hostID == value.hostID && visibleAgentID == value.agentID { return [] }
        return [.banner, .list, .sound]
    }

    func receive(identifier: String, sealed: String) {
        guard connection?.isAuthenticated == true, !handled.contains(identifier),
              let records = try? keys.load(), let value = NotificationPayload.open(sealed, secrets: records),
              value.kind != "failed" else { return }
        handled.append(identifier)
        handled = Array(handled.suffix(100))
        pendingOpen = Destination(id: identifier, push: value)
    }

    func finishOpening(_ id: String, success: Bool) {
        guard pendingOpen?.id == id else { return }
        pendingOpen = nil
        routeFailed = !success
    }

    private func scheduleSync() { _ = enqueueSync(force: false) }

    @discardableResult
    private func enqueueSync(force: Bool, reportFailure: Bool = false) -> Task<Void, Never> {
        let previous = registration
        let epoch = generation
        let next = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, epoch == self.generation else { return }
            await self.sync(force: force, reportFailure: reportFailure)
        }
        registration = next
        return next
    }

    private func sync(force: Bool, reportFailure: Bool) async {
        guard let connection, connection.canSend, connection.supportsPush,
              let scope = connection.workspaceID, let host = connection.hostID else { return }
        let epoch = generation
        do {
            if !enabled || !isAllowed {
                if lastRegistration != "removed:\(scope)" {
                    try await connection.removePushRegistration()
                    if epoch == generation { lastRegistration = "removed:\(scope)" }
                }
                return
            }
            var records = try keys.load()
            let record: NotificationSecret
            if let old = records.first(where: { $0.scope == scope }) { record = old }
            else {
                record = NotificationSecret(scope: scope, hostID: host, name: connection.hostName,
                                            secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
                records.append(record)
                try keys.save(records)
            }
            guard relayReady, let token, let environment = PushEnvironment.current() else { return }
            let stamp = [scope, token, active ? "here" : "away"].joined(separator: ":")
            if !force && stamp == lastRegistration { return }
            try Task.checkCancellation()
            try await connection.registerPush(scope: scope, token: token, secret: NotificationPayload.encode(record.secret),
                                              environment: environment, away: !active)
            if epoch == generation { lastRegistration = stamp }
        } catch is CancellationError { }
        catch is NotificationKeyStore.Failure {
            recordFailure("key-storage")
            if reportFailure && epoch == generation { problem = "native.error.generic" }
        }
        catch {
            recordFailure("registration-sync")
            if reportFailure && epoch == generation { problem = "native.error.generic" }
        }
    }

    private func recordFailure(_ operation: String) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenBot", category: "NativeNotifications")
            .error("Notification operation failed: \(operation, privacy: .public)")
    }
}

/// Physical-device tokens use the provisioning profile, not Debug/Release assumptions.
nonisolated enum PushEnvironment {
    static func current() -> String? {
        #if targetEnvironment(simulator)
        return "development"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bytes = try? Data(contentsOf: url), bytes.count <= 1_048_576,
              let start = bytes.range(of: Data("<?xml".utf8)),
              let end = bytes.range(of: Data("</plist>".utf8)), start.lowerBound < end.upperBound,
              let profile = try? PropertyListSerialization.propertyList(from: bytes[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String,
              ["production", "development"].contains(environment) else { return nil }
        return environment
        #endif
    }
}
