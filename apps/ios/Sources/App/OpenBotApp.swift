import SwiftUI

@main
struct OpenBotApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var delegate
    @State private var store = ConversationStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ConversationListScreen(store: store)
                .modifier(AppHapticsHost())
                .tint(MessagesStyle.accent)
                .background(alignment: .bottomTrailing) {
                    HostTransportView(transport: store.connection.transport)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .task {
                    await store.connection.restore()
                    delegate.notifications = store.notifications
                    await store.notifications.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await store.setActive(false) } }
                    else if phase == .active { Task { await store.setActive(true) } }
                }
        }
    }
}
