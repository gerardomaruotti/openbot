import SwiftUI

struct ConversationListScreen: View {
    let store: ConversationStore
    @Environment(AppHaptics.self) private var haptics
    @State private var path: [String] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsActionError = false
    @State private var search = ""
    @State private var unreadOnly = false
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var isComposing = false
    @State private var isEditingPins = false
    @State private var pendingDeletion: String?
    @State private var showsSearchHelp = false
    @State private var showsConnection = false
    @State private var incomingConnectionLink: String?
    @State private var showsAgents = false
    @State private var showsRoutines = false
    @State private var listSize = CGSize(width: 402, height: 680)
    @FocusState private var isSearchFocused: Bool

    init(store: ConversationStore) {
        self.store = store
        _path = State(initialValue: store.lastOpenedID.map { [$0] } ?? [])
    }

    private var visible: [Conversation] {
        store.conversations.filter { conversation in
            conversation.isVisible && (!unreadOnly || conversation.isUnread) &&
            (search.isEmpty || conversation.name.localizedStandardContains(search) ||
             conversation.preview.localizedStandardContains(search))
        }
    }

    private var pins: [Conversation] { visible.filter(\.isPinned) }
    private var rows: [Conversation] { search.isEmpty && !isSelecting ? visible.filter { !$0.isPinned } : visible }

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                if !pins.isEmpty && search.isEmpty && !isSelecting {
                    PinnedConversations(
                        conversations: pins,
                        open: { path.append($0) },
                        unpin: togglePin
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 16, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                ForEach(rows) { conversation in
                    Button {
                        if isSelecting {
                            if selection.contains(conversation.id) { selection.remove(conversation.id) }
                            else { selection.insert(conversation.id) }
                        } else {
                            path.append(conversation.id)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            ConversationRow(conversation: conversation, notice: store.attentionTitle(conversation.id))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 4)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .tag(conversation.id)
                    .listRowInsets(EdgeInsets(top: 12, leading: 26, bottom: 12, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 57 }
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .leading) {
                        Button {
                            store.toggleUnread(conversation.id)
                        } label: {
                            Label(conversation.isUnread ? "native.action.read" : "native.action.unread", systemImage: conversation.isUnread ? "bubble.left" : "bubble.left.fill")
                        }
                        .tint(MessagesStyle.accent)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !store.isLive {
                        Button(role: .destructive) { pendingDeletion = conversation.id } label: {
                            Label("native.action.delete", systemImage: "trash")
                        }
                        Button {
                            store.update(conversation.id) { $0.isMuted.toggle() }
                        } label: {
                            Label(conversation.isMuted ? "native.action.showAlerts" : "native.action.hideAlerts", systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
                        }
                        .tint(MessagesStyle.mute)
                        } else if store.connection.features.notificationPreferences {
                            Button { store.toggleMute(conversation.id) } label: {
                                Label(conversation.isMuted ? "native.action.showAlerts" : "native.action.hideAlerts", systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
                            }
                            .tint(MessagesStyle.mute)
                            .disabled(!store.connection.canSend || store.chatControls.changingNotifications.contains(conversation.id))
                        }
                    }
                    .contextMenu {
                        if store.isLive {
                            Button(conversation.isPinned ? "native.action.unpin" : "native.action.pin", systemImage: "pin") { togglePin(conversation.id) }
                                .tint(.primary)
                            Button(conversation.isUnread ? "native.action.read" : "native.action.unread", systemImage: "bubble.left") { store.toggleUnread(conversation.id) }
                                .tint(.primary)
                            if store.connection.features.notificationPreferences {
                                Button(conversation.isMuted ? "native.action.showAlerts" : "native.action.hideAlerts", systemImage: "bell.slash") { store.toggleMute(conversation.id) }
                                    .tint(.primary)
                                    .disabled(!store.connection.canSend || store.chatControls.changingNotifications.contains(conversation.id))
                            }
                        } else { conversationActions(conversation).tint(.primary) }
                    } preview: {
                        ConversationPreview(messages: conversation.messages, viewportSize: listSize)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(MessagesStyle.surface)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { listSize = $0 }
            .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
            .overlay {
                if visible.isEmpty {
                    if store.connection.problem == .storage {
                        ContentUnavailableView {
                            Label("native.error.generic", systemImage: "bubble.left.and.bubble.right")
                        } actions: {
                            Button("native.connection.reconnect") { Task { await store.connection.reconnect() } }
                        }
                    } else if store.connection.isBusy {
                        ProgressView()
                    } else if store.isLive && store.connection.phase == .online && store.conversations.isEmpty {
                        ContentUnavailableView {
                            Label("native.connection.noAgents", systemImage: "bubble.left.and.bubble.right")
                        } description: {
                            Text("native.connection.noAgentsHelp")
                        } actions: {
                            Button("native.connection.reconnect") { Task { await store.connection.reconnect() } }
                        }
                    } else if unreadOnly && search.isEmpty {
                        ContentUnavailableView("native.filter.noneUnread", systemImage: "checkmark.bubble")
                    } else if search.isEmpty {
                        ContentUnavailableView {
                            Label("native.connection.empty", systemImage: "desktopcomputer")
                        } actions: {
                            Button("native.connection.getStarted") { showsConnection = true }
                        }
                    } else { ContentUnavailableView.search(text: search) }
                }
            }
            .alert("native.error.generic", isPresented: $showsActionError) {
                Button("native.action.done", role: .cancel) { store.notifications.routeFailed = false }
            }
            .onChange(of: store.notifications.routeFailed) { _, failed in
                if failed, scenePhase == .active { showsActionError = true }
            }
            .onChange(of: store.chatControls.problemRevision) { _, _ in
                if store.chatControls.problem != nil, path.isEmpty, scenePhase == .active { showsActionError = true }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { showsActionError = false } }
            .navigationTitle("native.messages.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSelecting {
                        Button("native.action.done") { isSelecting = false; selection.removeAll() }
                            .foregroundStyle(.primary)
                    } else {
                        Menu {
                            Button("native.connection.title", systemImage: "desktopcomputer") { showsConnection = true }
                            if store.isLive && store.connection.features.agents {
                                Button("native.agents.title", systemImage: "person.2") { showsAgents = true }
                            }
                            if store.isLive && store.connection.features.routines {
                                Button("native.routine.title", systemImage: "clock") { showsRoutines = true }
                            }
                            Button("native.action.editPins", systemImage: "pin") { isEditingPins = true }
                            if !store.isLive {
                            Button("native.action.selectMessages", systemImage: "checkmark.circle") { isSelecting = true }
                            Button("native.action.restoreSamples", systemImage: "arrow.counterclockwise") { store.restoreSamples() }
                            }
                        } label: {
                            Text("native.action.edit").foregroundStyle(.primary)
                        }
                        .tint(.primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            unreadOnly = false
                        } label: {
                            Label("native.filter.all", systemImage: unreadOnly ? "bubble.left.and.bubble.right" : "checkmark")
                        }
                        Button {
                            unreadOnly = true
                        } label: {
                            Label("native.filter.unread", systemImage: unreadOnly ? "checkmark" : "bubble.left.fill")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.title3)
                            .foregroundStyle(.primary)
                    }
                    .tint(.primary)
                    .accessibilityLabel("native.filter.title")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    HStack {
                        Button("native.action.unread") {
                            for id in selection { store.update(id) { $0.isUnread = true } }
                            isSelecting = false; selection.removeAll()
                        }
                        Spacer()
                        Button("native.action.delete", role: .destructive) {
                            for id in selection { store.delete(id) }
                            isSelecting = false; selection.removeAll()
                        }
                    }
                    .disabled(selection.isEmpty)
                    .padding(24)
                    .background(.bar)
                } else {
                    searchDock
                }
            }
            .navigationDestination(for: String.self) { id in
                ChatScreen(store: store, conversationID: id)
            }
            .sheet(isPresented: $isComposing) {
                if store.isLive {
                    AgentManagementScreen(model: store.agentManagement, connection: store.connection, onChanged: { }, onOpen: { id in
                        isComposing = false
                        store.requestOpen(id)
                    })
                } else {
                NewConversationSheet(conversations: store.conversations) { id in
                    isComposing = false
                    store.update(id) { $0.isVisible = true }
                    path.append(id)
                }
                }
            }
            .sheet(isPresented: $showsAgents) {
                AgentManagementScreen(model: store.agentManagement, connection: store.connection, onChanged: { }, onOpen: { id in
                    showsAgents = false
                    store.requestOpen(id)
                })
            }
            .sheet(isPresented: $showsRoutines) { RoutineAgentPicker(store: store) }
            .sheet(isPresented: $showsConnection, onDismiss: { incomingConnectionLink = nil }) {
                ConnectionScreen(connection: store.connection, notifications: store.notifications, queuedCount: store.queuedCount,
                                 incomingLink: incomingConnectionLink)
            }
            .task(id: store.notifications.pendingOpen?.id) {
                guard let destination = store.notifications.pendingOpen else { return }
                let id = await store.resolveNotification(destination)
                guard store.notifications.pendingOpen?.id == destination.id else { return }
                if let id { showsConnection = false; isComposing = false; path = [id] }
                store.notifications.finishOpening(destination.id, success: id != nil)
            }
            .onOpenURL { url in
                incomingConnectionLink = url.absoluteString
                showsConnection = true
            }
            .onChange(of: store.isLive) { _, _ in
                path = []; showsAgents = false; showsRoutines = false; isComposing = false; isEditingPins = false
            }
            .onChange(of: store.requestedConversationID) { _, id in
                guard let id else { return }
                showsAgents = false; isComposing = false; path = [id]
                store.requestedConversationID = nil
            }
            .onChange(of: store.connection.hostID) { _, _ in
                path = []; showsAgents = false; showsRoutines = false; isComposing = false; isEditingPins = false
            }
            .onChange(of: store.conversations.map(\.id)) { _, ids in path.removeAll { !ids.contains($0) } }
            .onChange(of: path) { old, new in
                if new.isEmpty, let id = old.last { store.closeConversation(id) }
            }
            .sheet(isPresented: $isEditingPins) {
                NavigationStack {
                    List(store.conversations.filter(\.isVisible)) { conversation in
                        Button {
                            togglePin(conversation.id)
                        } label: {
                            HStack(spacing: 14) {
                                AvatarView(asset: conversation.avatar, size: 42)
                                Text(conversation.name).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: conversation.isPinned ? "pin.fill" : "pin")
                            }
                        }
                    }
                    .navigationTitle("native.action.editPins")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("native.action.done") { isEditingPins = false } } }
                }
            }
            .confirmationDialog("native.delete.title", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("native.action.delete", role: .destructive) {
                    if let id = pendingDeletion { store.delete(id) }
                    pendingDeletion = nil
                }
            }
            .alert("native.search.voiceTitle", isPresented: $showsSearchHelp) {
                Button("native.action.done", role: .cancel) { }
            } message: {
                Text("native.search.voiceMessage")
            }
        }
    }

    private var searchDock: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title3.weight(.medium))
                    TextField("native.search.placeholder", text: $search, prompt: Text("native.search.placeholder").foregroundStyle(MessagesStyle.secondary))
                        .font(.body)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("native.search.clear")
                    } else if !store.isLive {
                        Button { showsSearchHelp = true } label: { Image(systemName: "mic").font(.title3) }
                            .accessibilityLabel("native.search.voiceTitle")
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)

                GlassIconButton(symbol: "square.and.pencil", label: "native.compose.title", size: 48) { isComposing = true }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 10)
        .padding(.bottom, isSearchFocused ? 8 : -6)
    }

    @ViewBuilder
    private func conversationActions(_ conversation: Conversation) -> some View {
        Button(conversation.isPinned ? "native.action.unpin" : "native.action.pin", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
            togglePin(conversation.id)
        }
        Button(conversation.isUnread ? "native.action.read" : "native.action.unread", systemImage: "bubble.left") {
            store.update(conversation.id) { $0.isUnread.toggle() }
        }
        Button(conversation.isMuted ? "native.action.showAlerts" : "native.action.hideAlerts", systemImage: "bell.slash") {
            store.update(conversation.id) { $0.isMuted.toggle() }
        }
        Button("native.action.delete", systemImage: "trash", role: .destructive) { pendingDeletion = conversation.id }
            .tint(.red)
    }

    private func togglePin(_ id: String) {
        guard let before = store.conversation(id)?.isPinned else { return }
        store.togglePin(id)
        if let after = store.conversation(id)?.isPinned, before != after { haptics.play(.selection) }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    var notice: LocalizedStringResource? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(asset: conversation.avatar, size: 45)
                .overlay(alignment: .leading) {
                    if conversation.isUnread {
                        Circle().fill(MessagesStyle.accent).frame(width: 8, height: 8).offset(x: -17)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(conversation.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if conversation.isVerified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.primary) }
                    Spacer(minLength: 2)
                    Text(conversation.dateLabel).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(conversation.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(minHeight: 62, alignment: .top)
            if conversation.isMuted {
                Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PinnedConversations: View {
    let conversations: [Conversation]
    let open: (String) -> Void
    let unpin: (String) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(conversations) { conversation in
                Button { open(conversation.id) } label: {
                    VStack(spacing: 6) {
                        AvatarView(asset: conversation.avatar, size: 95)
                        Text(conversation.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("native.action.unpin", systemImage: "pin.slash") { unpin(conversation.id) }
                        .tint(.primary)
                }
                .accessibilityAction(named: Text("native.action.unpin")) { unpin(conversation.id) }
            }
        }
    }
}

private struct NewConversationSheet: View {
    let conversations: [Conversation]
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var matches: [Conversation] {
        conversations.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(matches) { conversation in
                Button { open(conversation.id) } label: {
                    HStack(spacing: 14) {
                        AvatarView(asset: conversation.avatar, size: 44)
                        Text(conversation.name).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "native.compose.to")
            .navigationTitle("native.compose.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("native.action.cancel") { dismiss() } } }
        }
    }
}
