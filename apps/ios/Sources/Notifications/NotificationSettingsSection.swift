import SwiftUI
import UIKit

struct NotificationSettingsSection: View {
    let notifications: NativeNotifications
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsActionProblem = false
    @State private var actionID = UUID()
    @State private var isVisible = false

    var body: some View {
        Section {
            if notifications.isAllowed {
                if notifications.enabled {
                    Label("native.notifications.allowed", systemImage: "bell.badge")
                    Button("native.notifications.test") {
                        perform { await notifications.preview(); return notifications.problem == nil }
                    }
                    Button("native.notifications.turnOff") {
                        perform { await notifications.disable(); return notifications.problem == nil }
                    }
                } else {
                    Label("native.notifications.off", systemImage: "bell.slash")
                    Button("native.notifications.resume") {
                        perform { await notifications.requestPermission(); return notifications.problem == nil }
                    }
                }
            } else if notifications.permission == .denied {
                Text("native.notifications.denied").foregroundStyle(.secondary)
                Button("native.notifications.openSettings") {
                    perform {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return false }
                        return await UIApplication.shared.open(url)
                    }
                }
            } else {
                Button("native.notifications.turnOn") {
                    perform { await notifications.requestPermission(); return notifications.problem == nil }
                }
            }
            if showsActionProblem { Text("native.error.generic").foregroundStyle(.red) }
        } header: {
            Text("native.notifications.title")
        }
        .disabled(notifications.isBusy)
        .onAppear { isVisible = true; showsActionProblem = false }
        .onDisappear { isVisible = false; actionID = UUID(); showsActionProblem = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { showsActionProblem = false } }
        .task { await notifications.refresh() }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Bool) {
        let request = UUID()
        actionID = request
        showsActionProblem = false
        Task { @MainActor in
            let succeeded = await operation()
            guard isVisible, scenePhase == .active, actionID == request else { return }
            showsActionProblem = !succeeded
        }
    }
}
