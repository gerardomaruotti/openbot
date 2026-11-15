import SwiftUI

struct AgentManagementScreen: View {
    let model: NativeAgents
    let connection: AgentConnection
    var initialAgentID: String? = nil
    let onChanged: () async -> Void
    var onOpen: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editor: AgentEditorTarget?
    @State private var openedInitialAgent = false
    @State private var initialLoadFailed = false
    @State private var isVisible = false
    private var loadKey: AgentManagementLoadKey {
        AgentManagementLoadKey(workspaceID: connection.workspaceID, online: connection.phase == .online)
    }

    var body: some View {
        NavigationStack {
            List {
                if initialLoadFailed && !model.hasLoaded {
                    Section {
                        Text("native.error.generic").foregroundStyle(.secondary)
                        Button("native.agents.refresh", systemImage: "arrow.clockwise") {
                            Task {
                                let loaded = await model.load(connection: connection)
                                guard isVisible, !Task.isCancelled else { return }
                                initialLoadFailed = !loaded && !model.hasLoaded
                            }
                        }
                        .disabled(model.isBusy || !connection.canSend)
                    }
                }
                ForEach(model.agents) { agent in
                    Button {
                        editor = AgentEditorTarget(agent: agent, context: model.currentContext)
                    } label: {
                        AgentManagementRow(agent: agent)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                }
            }
            .overlay {
                if model.isBusy && !model.hasLoaded { ProgressView() }
                else if model.hasLoaded && model.agents.isEmpty {
                    ContentUnavailableView("native.agents.empty", systemImage: "person.2",
                        description: Text("native.agents.emptyHelp"))
                }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .navigationTitle("native.agents.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("native.action.done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.canCreate && connection.features.agentCreate {
                        Button("native.agents.new", systemImage: "person.badge.plus") {
                            editor = AgentEditorTarget(agent: nil, context: model.currentContext)
                        }
                        .disabled(!model.canChange(model.currentContext, connection: connection))
                    }
                }
            }
            .refreshable { _ = await model.load(connection: connection) }
            .task(id: loadKey) {
                let loaded = await model.load(connection: connection)
                guard isVisible, !Task.isCancelled else { return }
                initialLoadFailed = !loaded && !model.hasLoaded
                if !openedInitialAgent, let initialAgentID,
                   let agent = model.agents.first(where: { $0.id == initialAgentID }) {
                    openedInitialAgent = true
                    editor = AgentEditorTarget(agent: agent, context: model.currentContext)
                }
            }
            .sheet(item: $editor) { target in
                AgentEditorScreen(model: model, connection: connection, target: target,
                    onChanged: onChanged, onOpen: onOpen, finished: { editor = nil })
            }
        }
    }
}

private struct AgentManagementLoadKey: Equatable {
    let workspaceID: String?
    let online: Bool
}

private struct AgentManagementRow: View {
    let agent: NativeManagedAgent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(MessagesStyle.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                if !agent.title.isEmpty {
                    Text(agent.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentEditorTarget: Identifiable {
    let id = UUID()
    let agent: NativeManagedAgent?
    let context: NativeAgentContext?
}

private struct AgentEditorScreen: View {
    @Environment(AppHaptics.self) private var haptics
    @State private var isVisible = false
    let model: NativeAgents
    let connection: AgentConnection
    let target: AgentEditorTarget
    let onChanged: () async -> Void
    let onOpen: ((String) -> Void)?
    let finished: () -> Void
    @State private var draft: NativeAgentDraft
    @State private var showsDelete = false
    @State private var showsDiscard = false
    @State private var submitting = false
    @State private var showsActionError = false

    init(model: NativeAgents, connection: AgentConnection, target: AgentEditorTarget,
         onChanged: @escaping () async -> Void, onOpen: ((String) -> Void)?, finished: @escaping () -> Void) {
        self.model = model; self.connection = connection; self.target = target
        self.onChanged = onChanged; self.onOpen = onOpen; self.finished = finished
        _draft = State(initialValue: NativeAgentDraft(agent: target.agent))
    }

    private var creating: Bool { target.agent == nil }
    private var currentAgent: NativeManagedAgent? { target.agent.flatMap { model.agent($0.id) } }
    private var isCurrent: Bool {
        model.isCurrent(target.context, connection: connection) && (creating || currentAgent != nil)
    }
    private var canEdit: Bool {
        model.canChange(target.context, connection: connection) && !submitting &&
        (creating ? model.canCreate && connection.features.agentCreate : currentAgent?.canManage == true)
    }
    private var changed: Bool {
        if let agent = target.agent { return draft != NativeAgentDraft(agent: agent) }
        return !draft.name.isEmpty || !draft.instructions.isEmpty || !draft.firstMessage.isEmpty
    }
    private var unconfirmedCreate: Bool { creating && model.unconfirmedCreateSeeds.contains(draft.avatarSeed) }

    var body: some View {
        NavigationStack {
            Form {
                AgentIdentityFields(name: $draft.name, title: $draft.title, instructions: $draft.instructions,
                    showRole: !creating).disabled(!canEdit)
                if creating {
                    Section {
                        TextField("native.agents.firstMessage", text: $draft.firstMessage, axis: .vertical)
                            .accessibilityIdentifier("agent-first-message")
                            .lineLimit(3...8)
                        if draft.firstMessage.utf16.count > 100_000 {
                            Text("native.agents.messageLimit").font(.caption).foregroundStyle(.red)
                        }
                    }
                    .disabled(!canEdit || unconfirmedCreate)
                }
                if currentAgent?.canManage == false {
                    Text("native.agents.readOnly").foregroundStyle(.secondary)
                }
                if showsActionError { Text("native.error.generic").foregroundStyle(.secondary) }
                if unconfirmedCreate {
                    Button("native.agents.checkList") {
                        Task {
                            let loaded = await model.load(connection: connection)
                            guard isVisible, model.isCurrent(target.context, connection: connection), !Task.isCancelled else { return }
                            if loaded { finished() }
                        }
                    }
                    .disabled(model.isBusy || !connection.canSend)
                }
                if submitting || model.isBusy { ProgressView().frame(maxWidth: .infinity) }
                if let agent = target.agent, let onOpen {
                    Section {
                        Button("native.agents.openChat") { finished(); onOpen(agent.id) }
                            .disabled(!isCurrent || submitting)
                    }
                }
                if currentAgent?.canDelete == true && connection.features.agentDelete {
                    Section {
                        Button("native.agents.delete", role: .destructive) { showsDelete = true }
                            .disabled(!canEdit)
                    }
                }
            }
            .navigationTitle(creating ? Text("native.agents.new") : Text(target.agent?.name ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("native.action.cancel") {
                        if changed && !unconfirmedCreate { showsDiscard = true } else { finished() }
                    }
                    .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if creating || currentAgent?.canManage == true {
                        Button(creating ? "native.agents.create" : "native.agents.save") { Task { await save() } }
                            .accessibilityIdentifier("agent-save")
                            .disabled(!canEdit || !draft.isValid(creating: creating) || !changed || unconfirmedCreate)
                    }
                }
            }
            .interactiveDismissDisabled(submitting || (changed && !unconfirmedCreate))
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: isCurrent) { _, current in if !current { finished() } }
            .confirmationDialog("native.agents.discardConfirm", isPresented: $showsDiscard, titleVisibility: .visible) {
                Button("native.agents.discard", role: .destructive, action: finished)
                Button("native.agents.keepEditing", role: .cancel) { }
            }
            .confirmationDialog("native.agents.deleteConfirm", isPresented: $showsDelete, titleVisibility: .visible) {
                Button("native.agents.delete", role: .destructive) { Task { await remove() } }
            } message: {
                if let agent = target.agent { Text("native.agents.deleteWarning \(agent.name)") }
            }
        }
    }

    private func save() async {
        guard canEdit else { return }
        submitting = true; showsActionError = false
        let saved: NativeManagedAgent?
        if let agent = target.agent {
            saved = await model.update(agent, draft: draft, context: target.context, connection: connection)
        } else {
            saved = await model.create(draft, context: target.context, connection: connection)
        }
        if let saved {
            if isVisible, model.isCurrent(target.context, connection: connection) { haptics.play(.success) }
            await onChanged()
            let mayOpen = model.isCurrent(target.context, connection: connection)
            finished()
            if creating && mayOpen { onOpen?(saved.id) }
        } else if isVisible, model.isCurrent(target.context, connection: connection) {
            showsActionError = true; haptics.play(.warning)
        }
        submitting = false
    }

    private func remove() async {
        guard let agent = target.agent, canEdit else { return }
        submitting = true; showsActionError = false
        if await model.remove(agent, context: target.context, connection: connection) {
            if isVisible, model.isCurrent(target.context, connection: connection) { haptics.play(.success) }
            await onChanged()
            finished()
        } else if isVisible, model.isCurrent(target.context, connection: connection) {
            showsActionError = true; haptics.play(.warning)
        }
        submitting = false
    }
}

private struct AgentIdentityFields: View {
    @Binding var name: String
    @Binding var title: String
    @Binding var instructions: String
    let showRole: Bool

    var body: some View {
        Section {
            TextField("native.agents.name", text: $name).textContentType(.name)
                .accessibilityIdentifier("agent-name")
            if name.utf16.count > 80 { Text("native.agents.nameLimit").font(.caption).foregroundStyle(.red) }
            if showRole {
                TextField("native.agents.role", text: $title, axis: .vertical).lineLimit(1...3)
                    .accessibilityIdentifier("agent-title")
                if title.utf16.count > 120 { Text("native.agents.roleLimit").font(.caption).foregroundStyle(.red) }
            }
        }
        Section("native.agents.instructions") {
            TextEditor(text: $instructions).frame(minHeight: 110)
                .accessibilityIdentifier("agent-instructions")
                .accessibilityLabel("native.agents.instructions")
            if instructions.utf16.count > 2_000 {
                Text("native.agents.instructionsLimit").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
