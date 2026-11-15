import SwiftUI

struct RoutineAgentPicker: View {
    let store: ConversationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.conversations) { agent in
                NavigationLink {
                    RoutineManagementScreen(connection: store.connection, model: store.routines, agentID: agent.id, agentName: agent.name)
                } label: {
                    Label(agent.name, systemImage: "person.crop.circle")
                }
            }
            .navigationTitle("native.routine.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("native.action.done") { dismiss() } } }
        }
    }
}

struct LiveAgentDetails: View {
    let store: ConversationStore
    let conversation: Conversation
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var showsActionError = false
    @State private var showsAgent = false
    @State private var showsRoutines = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.connection.features.agents {
                Button("native.management.agentSettings", systemImage: "slider.horizontal.3") { showsAgent = true }
            }
            if store.connection.features.routines {
                Button("native.routine.title", systemImage: "clock") { showsRoutines = true }
            }
            if store.connection.features.notificationPreferences {
                Toggle("native.action.hideAlerts", isOn: Binding(
                    get: { store.conversation(conversation.id)?.isMuted ?? false },
                    set: { _ in store.toggleMute(conversation.id) }
                ))
                .disabled(!store.connection.canSend || store.chatControls.changingNotifications.contains(conversation.id))
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; showsActionError = false }
        .alert("native.error.generic", isPresented: $showsActionError) {
            Button("native.action.done", role: .cancel) { }
        }
        .onChange(of: store.chatControls.problemRevision) { _, _ in
            if store.chatControls.problem != nil, store.chatControls.problemAgentID == conversation.id, isVisible, scenePhase == .active {
                showsActionError = true
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { showsActionError = false } }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(MessagesStyle.card, in: .rect(cornerRadius: 28))
        .sheet(isPresented: $showsAgent) {
            AgentManagementScreen(model: store.agentManagement, connection: store.connection, initialAgentID: conversation.id,
                onChanged: { }, onOpen: { id in showsAgent = false; store.requestOpen(id) })
        }
        .sheet(isPresented: $showsRoutines) {
            NavigationStack {
                RoutineManagementScreen(connection: store.connection, model: store.routines, agentID: conversation.id, agentName: conversation.name)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("native.action.done") { showsRoutines = false } } }
            }
        }
    }
}
