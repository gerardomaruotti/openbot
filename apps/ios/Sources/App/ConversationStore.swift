import Foundation
import Observation

@Observable
@MainActor
final class ConversationStore {
    let connection = AgentConnection()
    let approvals = AgentApprovals()
    let questions = AgentQuestions()
    let tasks = AgentTasks()
    let notifications = NativeNotifications()
    let attachments = NativeAttachments()
    let chatControls = NativeChatControls()
    let agentManagement = NativeAgents()
    let routines = NativeRoutines()
    let browser = NativeBrowserSession()
    var requestedConversationID: String?
    private(set) var conversations: [Conversation] = []
    private(set) var loading: Set<String> = []
    private(set) var running: Set<String> = []
    private(set) var loadingOlder: Set<String> = []
    private(set) var historyProblems: [String: LocalizedStringResource] = [:]
    private(set) var stopping: Set<String> = []
    private(set) var lastOpenedID: String?
    private let defaults: UserDefaults
    private let storageKey = "native-messages-preview.v1"
    private var workspace: LiveWorkspaceState?
    private var disk: LiveWorkspaceDisk?
    private var remoteHostID: String?
    private var fresh: Set<String> = []
    private var loadingIDs: Set<String> = []
    private var needsReload: Set<String> = []
    private var unknownDeltas: [String: [WireValue]] = [:]
    private var reloadTasks: [String: Task<Void, Never>] = [:]
    private var persistence: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var drainRequested = false
    private var receiptRecovery: Task<Void, Never>?
    private var receiptRecoveryAttempts: [String: Int] = [:]
    private var persistenceBlocked = false
    private var activeID: String?
    private var generation = 0
    private var isActive = true
    private var foregroundFailedTurns: Set<String> = []
    private var sampleDrafts: [String: String] = [:]
    private var sampleReplyTargets: [String: String] = [:]
    private var replyProjections: [String: ConversationReplyProjection] = [:]

    var isLive: Bool { connection.isAuthenticated }
    var canCompose: Bool { !isLive || (workspace != nil && disk != nil && connection.problem != .hostMissing) }
    var queuedCount: Int { workspace?.outbox.filter { $0.state != .sent }.count ?? 0 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notifications.bind(connection)
        connection.agentsChanged = { [weak self] agents in self?.applyAgents(agents) }
        connection.teamEvent = { [weak self] event in self?.receive(event) }
        connection.cleared = { [weak self] in self?.clearSession() }
        connection.workspaceChanged = { [weak self] in self?.selectWorkspace() }
        connection.hostRemoved = { [weak self] in self?.removeWorkspace() }
        connection.workspacesRetained = { [weak self] scopes in self?.retainWorkspaces(scopes); self?.notifications.retain(scopes) }
        connection.ready = { [weak self] kept in self?.connected(kept: kept); self?.notifications.connected() }
        if isLive { selectWorkspace() }
        else if let data = defaults.data(forKey: storageKey), let saved = try? JSONDecoder().decode([Conversation].self, from: data) { conversations = saved }
        else { conversations = [] }
        if !isLive { rebuildReplyProjections() }
    }

    func conversation(_ id: String) -> Conversation? { conversations.first { $0.id == id } }

    func requestOpen(_ id: String) {
        guard conversation(id) != nil else { return }
        requestedConversationID = id
    }

    func browserHandoffs(_ id: String) -> [AgentBrowserHandoff] {
        guard let page = workspace?.pages[id] else { return [] }
        return tasks.browserHandoffs.filter {
            $0.agentID == id && $0.threadID == page.threadId &&
            (page.activeTurnId == nil || page.activeTurnId == $0.turnID)
        }
    }

    func attentionTitle(_ id: String) -> LocalizedStringResource? {
        if tasks.browserHandoffs.contains(where: { $0.agentID == id }) {
            return connection.features.browserView || connection.features.browserSecretHandoff ? "native.browser.handoffTitle" : "native.handoff.title"
        }
        return nil
    }

    /// Only a failure observed in the visible main conversation can interrupt the user.
    /// Routine inputs share the host's user role, so their provenance must also be checked.
    func hasForegroundTaskFailure(_ id: String) -> Bool {
        guard let failure = tasks.failures[id], failure.terminal,
              let turn = failure.turnID, foregroundFailedTurns.contains(turn),
              let page = workspace?.pages[id] else { return false }
        return page.messages.contains {
            $0.author == "user" && $0.turnId == turn && $0.itemType != "routine" && $0.source != "routine"
        }
    }

    func draftText(_ id: String) -> String {
        isLive ? workspace?.drafts?[id] ?? "" : sampleDrafts[id] ?? ""
    }

    func setDraftText(_ text: String, for id: String) {
        guard conversation(id) != nil, draftText(id) != text else { return }
        if isLive {
            guard canCompose, var next = workspace else { return }
            var drafts = next.drafts ?? [:]
            if text.isEmpty { drafts.removeValue(forKey: id) } else { drafts[id] = text }
            next.drafts = drafts.isEmpty ? nil : drafts
            workspace = next
            // A process can end before the batched history write. Keep each accepted
            // user edit durable, together with its current reply target.
            saveNow()
        } else {
            if text.isEmpty { sampleDrafts.removeValue(forKey: id) } else { sampleDrafts[id] = text }
        }
    }

    func draftReplyTarget(_ id: String) -> String? {
        isLive ? workspace?.draftReplyTargets?[id] : sampleReplyTargets[id]
    }

    func canReply(_ messageID: String, in id: String) -> Bool {
        guard let message = replyMessage(messageID, in: id) else { return false }
        return !isLive || message.deliveryState == nil || message.deliveryState == .sent
    }

    func setReplyTarget(_ messageID: String?, in id: String) {
        guard conversation(id) != nil, draftReplyTarget(id) != messageID,
              messageID.map({ canReply($0, in: id) }) ?? true else { return }
        if isLive {
            guard var next = workspace else { return }
            var targets = next.draftReplyTargets ?? [:]
            targets[id] = messageID
            next.draftReplyTargets = targets.isEmpty ? nil : targets
            if let messageID, let original = next.pages[id]?.messages.first(where: { $0.id == messageID }) {
                var references = next.pages[id]?.references ?? [:]
                references[messageID] = original
                next.pages[id]?.references = references
            }
            workspace = next
            saveNow()
        } else { sampleReplyTargets[id] = messageID }
    }

    func replyMessage(_ messageID: String, in id: String) -> ChatMessage? {
        replyProjections[id]?.messagesByID[messageID]
    }

    /// Explicit references own the thread. A turn answer joins it only when the loaded host
    /// history proves a complete turn boundary and every user input has the same reply root.
    func replyRoots(_ id: String) -> [String: String] {
        replyProjections[id]?.rootsByID ?? [:]
    }

    func replyTimeline(_ id: String) -> [ReplyTimelineItem] {
        replyProjections[id]?.timeline ?? []
    }

    func replies(to rootID: String, in id: String) -> [ChatMessage] {
        replyProjections[id]?.repliesByRootID[rootID] ?? []
    }

    private func rebuildReplyProjection(_ id: String) {
        guard let conversation = conversation(id) else { replyProjections[id] = nil; return }
        replyProjections[id] = ConversationReplyProjection.make(messages: conversation.messages, page: workspace?.pages[id])
    }

    private func rebuildReplyProjections() {
        let ids = Set(conversations.map(\.id))
        replyProjections = replyProjections.filter { ids.contains($0.key) }
        for id in ids { rebuildReplyProjection(id) }
    }

    func update(_ id: String, _ change: (inout Conversation) -> Void) {
        guard !isLive, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        change(&conversations[index])
        rebuildReplyProjection(id)
        saveSamples()
    }

    @discardableResult
    func send(_ text: String, to id: String, attachments: [HostAttachment] = [], replyToMessageID: String? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), attachments.count <= 10, conversation(id)?.isBlocked == false else { return false }
        guard replyToMessageID.map({ canReply($0, in: id) }) ?? true else { return false }
        if isLive {
            guard canCompose, var next = workspace else { return false }
            next.outbox.append(OutboxMessage(clientID: UUID().uuidString, agentID: id, text: trimmed, createdAt: .now, attachments: attachments.isEmpty ? nil : attachments, replyToMessageId: replyToMessageID))
            next.drafts?.removeValue(forKey: id)
            next.draftReplyTargets?.removeValue(forKey: id)
            // Acceptance means the encrypted outbox is durable, even when the Mac is offline.
            guard commit(next) else { return false }
            project(id)
            drainOutbox()
            return true
        }
        update(id) { conversation in
            conversation.messages.append(ChatMessage(id: UUID().uuidString, content: .text(trimmed), isOutgoing: true, replyToMessageId: replyToMessageID))
            conversation.preview = trimmed
            conversation.dateLabel = Date.now.formatted(date: .omitted, time: .shortened)
            conversation.isVisible = true
            conversation.isUnread = false
        }
        sampleDrafts.removeValue(forKey: id)
        sampleReplyTargets.removeValue(forKey: id)
        return true
    }

    func react(_ reaction: Reaction, to messageID: String, in conversationID: String) {
        if isLive {
            guard canReact(messageID, in: conversationID), let message = conversation(conversationID)?.messages.first(where: { $0.id == messageID }) else { return }
            let emoji = message.userReaction == reaction.emoji ? nil : reaction.emoji
            Task {
                if await chatControls.react(emoji, agentID: conversationID, messageID: messageID, connection: connection) { await reload(conversationID) }
            }
            return
        }
        update(conversationID) { conversation in
            guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conversation.messages[index].reaction = conversation.messages[index].reaction == reaction ? nil : reaction
        }
    }

    func canReact(_ messageID: String, in id: String) -> Bool {
        !isLive || (connection.canSend && connection.features.reactions && !chatControls.changingReactions.contains(messageID) && workspace?.pages[id]?.messages.contains(where: { $0.id == messageID && $0.isVisible }) == true)
    }

    func toggleMute(_ id: String) {
        guard let value = conversation(id) else { return }
        if !isLive { update(id) { $0.isMuted.toggle() }; return }
        let level: String? = value.isMuted ? (workspace?.serverNotificationLevel == "nothing" ? "all" : nil) : "nothing"
        Task {
            if let preferences = await chatControls.setLevel(level, agentID: id, connection: connection) { applyPreferences(preferences) }
        }
    }

    func toggleUnread(_ id: String) {
        guard let value = conversation(id) else { return }
        if !isLive { update(id) { $0.isUnread.toggle() }; return }
        guard var next = workspace else { return }
        var read = next.readAt ?? [:]
        read[id] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(value.isUnread ? .now : .distantPast)
        next.readAt = read
        workspace = next
        project(id); saveSoon()
    }

    private func applyPreferences(_ preferences: NativeNotificationPreferences) {
        guard var next = workspace else { return }
        next.agentNotificationLevels = preferences.levels
        next.serverNotificationLevel = preferences.server
        workspace = next
        projectAgents(); saveSoon()
    }

    func delete(_ id: String) { update(id) { $0.isVisible = false; $0.isPinned = false } }
    func restoreSamples() { guard !isLive else { return }; conversations = SampleConversations.all; rebuildReplyProjections(); saveSamples() }
    private func saveSamples() {
        guard !isLive, let data = try? JSONEncoder().encode(conversations) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func resolveNotification(_ destination: NativeNotifications.Destination) async -> String? {
        let target = destination.push
        await connection.reconnectForNotification(hostID: target.hostID)
        guard connection.canSend, connection.notificationScope(for: target.hostID) == target.scope,
              conversation(target.agentID) != nil, let page = try? await connection.history(target.agentID),
              target.threadID == nil || target.threadID == page.threadId else { return nil }
        return target.agentID
    }

    func openConversation(_ id: String) async {
        if activeID != id { attachments.clear(connection: connection) }
        attachments.bind(connection)
        activeID = id
        notifications.visibleAgentID = id
        lastOpenedID = id
        workspace?.lastOpenedID = id
        markRead(id)
        if isLive { saveSoon(); await reload(id) }
        else { update(id) { $0.isUnread = false } }
    }

    func closeConversation(_ id: String) {
        guard activeID == id else { return }
        attachments.clear(connection: connection)
        activeID = nil
        foregroundFailedTurns = []
        notifications.visibleAgentID = nil
        lastOpenedID = nil
        workspace?.lastOpenedID = nil
        saveNow()
    }

    func setActive(_ value: Bool) async {
        isActive = value
        if value, let activeID { markRead(activeID) }
        if !value {
            foregroundFailedTurns = []
            receiptRecovery?.cancel(); receiptRecovery = nil
            saveNow()
        }
        await notifications.setActive(value)
        await connection.setActive(value)
    }

    func canRetry(_ rowID: String) -> Bool {
        guard connection.canSend, let value = workspace?.outbox.first(where: { $0.rowID == rowID }) else { return false }
        return value.state == .failed || value.canAttempt(deduplicates: connection.deduplicatesMessages) && value.state == .unconfirmed
    }

    func retryMessage(_ rowID: String) {
        guard canRetry(rowID), var next = workspace, let index = next.outbox.firstIndex(where: { $0.rowID == rowID }) else { return }
        if next.outbox[index].state == .failed {
            next.outbox[index].state = .queued
            next.outbox[index].firstAttemptAt = nil
        }
        if commit(next) { project(next.outbox[index].agentID); drainOutbox() }
    }

    func canCancel(_ rowID: String) -> Bool {
        workspace?.outbox.contains { $0.rowID == rowID && ($0.state == .queued || $0.state == .failed) } == true
    }

    func canDiscard(_ rowID: String) -> Bool {
        workspace?.outbox.contains { $0.rowID == rowID && $0.state == .unconfirmed } == true
    }

    func discardUnconfirmed(_ rowID: String) {
        guard canDiscard(rowID), var next = workspace, let message = next.outbox.first(where: { $0.rowID == rowID }) else { return }
        next.outbox.removeAll { $0.rowID == rowID }
        if commit(next) { project(message.agentID); drainOutbox() }
    }

    func cancelMessage(_ rowID: String) {
        guard canCancel(rowID), var next = workspace, let message = next.outbox.first(where: { $0.rowID == rowID }) else { return }
        next.outbox.removeAll { $0.rowID == rowID }
        if commit(next) { project(message.agentID); drainOutbox() }
    }

    private func selectWorkspace() {
        guard let scope = connection.workspaceID else { return }
        guard workspace?.scope != scope else { return }
        saveNow()
        let oldScope = workspace?.scope
        let sameHost = remoteHostID == connection.hostID
        resetProjection()
        do {
            let disk = try LiveWorkspaceDisk(directory: LiveWorkspaceDisk.applicationDirectory, key: HostSessionStore.workspaceKey())
            if sameHost, let oldScope { try disk.remove(scope: oldScope) }
            self.disk = disk
            workspace = try disk.load(scope: scope) ?? LiveWorkspaceState(scope: scope)
            remoteHostID = connection.hostID
            lastOpenedID = workspace?.lastOpenedID
            activeID = lastOpenedID
            projectAgents()
        } catch { connection.problem = .storage }
    }

    private func clearSession() {
        notifications.clear()
        approvals.clear()
        questions.clear()
        resetProjection()
        disk = nil
        do { try LiveWorkspaceDisk.clearApplicationData() } catch { connection.problem = .storage }
    }

    private func retainWorkspaces(_ scopes: Set<String>) {
        // Cancel stale saves before pruning; an old in-memory archive must not recreate a removed file.
        if let workspace, !scopes.contains(workspace.scope) { resetProjection() }
        do {
            if disk == nil { disk = try LiveWorkspaceDisk(directory: LiveWorkspaceDisk.applicationDirectory, key: HostSessionStore.workspaceKey()) }
            try disk?.retain(scopes: scopes)
        } catch { connection.problem = .storage }
    }

    private func removeWorkspace() {
        approvals.clear()
        if let scope = workspace?.scope { do { try disk?.remove(scope: scope) } catch { connection.problem = .storage } }
        resetProjection()
    }

    private func resetProjection() {
        attachments.clear(connection: connection)
        approvals.clear()
        questions.clear()
        tasks.clear()
        chatControls.clear()
        agentManagement.clear()
        routines.clear()
        browser.clear()
        requestedConversationID = nil
        generation += 1
        foregroundFailedTurns = []
        persistence?.cancel(); persistence = nil
        drain?.cancel(); drain = nil
        receiptRecovery?.cancel(); receiptRecovery = nil
        receiptRecoveryAttempts = [:]
        drainRequested = false; persistenceBlocked = false
        for task in reloadTasks.values { task.cancel() }
        reloadTasks = [:]
        workspace = nil
        conversations = []
        replyProjections = [:]
        loading = []; loadingIDs = []; needsReload = []; running = []; fresh = []
        unknownDeltas = [:]
        loadingOlder = []; historyProblems = [:]; stopping = []
        lastOpenedID = nil; activeID = nil; remoteHostID = nil
    }

    private func connected(kept: Bool) {
        if !kept { fresh = [] }
        saveNow()
        drainOutbox()
        if let activeID { scheduleReload(activeID) }
        Task {
            if let preferences = await chatControls.preferences(connection: connection) { applyPreferences(preferences) }
        }
    }

    private func applyAgents(_ agents: [HostAgent]) {
        selectWorkspace()
        guard var next = workspace else { return }
        let ids = Set(agents.map(\.id))
        agentManagement.retainVisibleAgents(ids)
        routines.retainVisibleAgents(ids)
        if let request = browser.request, !ids.contains(request.agentID) { browser.clear() }
        tasks.retainAgents(ids)
        let cachedAgents = next.agents
        next.agents = agents.map { agent in
            var result = agent
            if let cached = cachedAgents.first(where: { $0.id == agent.id }), result.preview == nil {
                result.preview = cached.preview; result.updatedAt = cached.updatedAt
            }
            return result
        }
        next.pages = next.pages.filter { ids.contains($0.key) }
        next.outbox.removeAll { !ids.contains($0.agentID) }
        next.drafts = next.drafts?.filter { ids.contains($0.key) }
        next.draftReplyTargets = next.draftReplyTargets?.filter { ids.contains($0.key) }
        next.agentNotificationLevels = next.agentNotificationLevels?.filter { ids.contains($0.key) }
        if let activeID, !ids.contains(activeID) {
            attachments.clear(connection: connection)
            self.activeID = nil
            notifications.visibleAgentID = nil
        }
        if let lastOpenedID, !ids.contains(lastOpenedID) { self.lastOpenedID = nil; next.lastOpenedID = nil }
        if let requestedConversationID, !ids.contains(requestedConversationID) { self.requestedConversationID = nil }
        workspace = next
        projectAgents()
        saveSoon()
    }

    private func projectAgents() {
        conversations = (workspace?.agents ?? []).map { agent in
            Conversation(id: agent.id, name: agent.name, avatar: "agent", preview: agent.preview ?? agent.title ?? "", dateLabel: "", messages: [], isPinned: workspace?.pinnedAgents?.contains(agent.id) == true, isMuted: (workspace?.agentNotificationLevels?[agent.id] ?? workspace?.serverNotificationLevel) == "nothing")
        }
        let ids = Set(conversations.map(\.id))
        replyProjections = replyProjections.filter { ids.contains($0.key) }
        for id in conversations.map(\.id) { project(id) }
    }

    private func project(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }), let workspace else { return }
        let messages = workspace.pages[id]?.messages.filter(\.isVisible) ?? []
        var previousDate: Date?
        var rows: [ChatMessage] = []
        for message in messages {
            let date = dateFromWire(message.createdAt)
            let timestamp = date.flatMap { date in previousDate.map { date.timeIntervalSince($0) > 300 } ?? true ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) : nil }
            if let date { previousDate = date }
            let reactions = message.reactions ?? message.reaction.map { emoji in
                [HostReaction(emoji: emoji, actor: HostReaction.Actor(kind: "user"))]
            }
            rows.append(ChatMessage(id: message.id, content: .text(message.text), isOutgoing: message.author == "user", timestamp: timestamp, deliveryState: message.author == "user" ? .sent : nil, isStreaming: message.status == "streaming", attachments: message.attachments, liveReactions: reactions, userReaction: message.reaction ?? reactions?.first(where: { $0.actor.kind == "user" })?.emoji, replyToMessageId: message.replyToMessageId, turnId: message.turnId))
        }
        let knownIDs = Set(messages.map(\.id))
        for value in workspace.outbox where value.agentID == id && !knownIDs.contains(value.rowID) {
            rows.append(ChatMessage(id: value.rowID, content: .text(value.text), isOutgoing: true, deliveryState: value.state, attachments: value.attachments, replyToMessageId: value.replyToMessageId))
        }
        conversations[index].messages = rows
        rebuildReplyProjection(id)
        refreshConversationMetadata(id, index: index, latestHostMessage: messages.last)
    }

    private func refreshConversationMetadata(_ id: String, index: Int, latestHostMessage: HostMessage?) {
        guard let workspace else { return }
        let agent = workspace.agents.first { $0.id == id }
        let rosterDate = agent?.updatedAt.flatMap(dateFromWire)
        let historyDate = latestHostMessage.flatMap { dateFromWire($0.createdAt) }
        if rosterDate.map({ (historyDate ?? .distantPast) >= $0 }) ?? true {
            if let last = conversations[index].messages.last, case .text(let text) = last.content { conversations[index].preview = text }
        }
        let updated = max(rosterDate ?? .distantPast, historyDate ?? .distantPast)
        if updated != .distantPast { conversations[index].dateLabel = updated.formatted(date: .omitted, time: .shortened) }
        conversations[index].isUnread = updated > (workspace.readAt?[id].flatMap(dateFromWire) ?? .distantPast) && activeID != id
    }

    func togglePin(_ id: String) {
        if !isLive { update(id) { $0.isPinned.toggle() }; return }
        guard var next = workspace else { return }
        var pins = next.pinnedAgents ?? []
        if pins.contains(id) { pins.removeAll { $0 == id } } else { pins.append(id) }
        next.pinnedAgents = pins
        if commit(next) { projectAgents() }
    }

    private func markRead(_ id: String) {
        guard isActive, var next = workspace else { return }
        var read = next.readAt ?? [:]
        read[id] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(.now)
        next.readAt = read
        workspace = next
        if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index].isUnread = false }
        saveSoon()
    }

    func hasOlder(_ id: String) -> Bool { workspace?.pages[id]?.pageInfo?.hasOlder == true }

    func canStop(_ id: String) -> Bool {
        connection.canSend && running.contains(id) && !stopping.contains(id) && workspace?.pages[id]?.activeTurnId != nil
    }

    @discardableResult
    func stop(_ id: String) async -> Bool {
        guard canStop(id),
              let host = connection.hostID, let turn = workspace?.pages[id]?.activeTurnId else { return false }
        let epoch = generation
        stopping.insert(id)
        defer { if epoch == generation { stopping.remove(id) } }
        do {
            _ = try await connection.transport.execute(["type": .string("interrupt"), "hostId": .string(host), "agentId": .string(id), "turnId": .string(turn)])
            return epoch == generation && connection.hostID == host
        } catch {
            if epoch == generation { connection.report(error) }
            return false
        }
    }

    func loadOlder(_ id: String) async {
        guard connection.canSend, !loadingOlder.contains(id), let current = workspace?.pages[id],
              let cursor = current.pageInfo?.olderCursor, current.pageInfo?.hasOlder == true else { return }
        let epoch = generation
        loadingOlder.insert(id); historyProblems[id] = nil
        defer { if epoch == generation { loadingOlder.remove(id) } }
        do {
            let older = try await connection.history(id, before: cursor)
            guard epoch == generation, var page = workspace?.pages[id], older.threadId == page.threadId,
                  page.pageInfo?.olderCursor == cursor else { return }
            let ids = Set(page.messages.map(\.id))
            page.messages = older.messages.filter { !ids.contains($0.id) } + page.messages
            page.references = (older.references ?? [:]).merging(page.references ?? [:]) { _, new in new }
            page.pageInfo = older.pageInfo
            workspace?.pages[id] = page
            project(id); saveSoon()
        } catch {
            if epoch == generation { historyProblems[id] = "native.history.failed"; connection.report(error) }
        }
    }

    private func scheduleReload(_ id: String) {
        guard reloadTasks[id] == nil else { return }
        reloadTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            self?.reloadTasks[id] = nil
            await self?.reload(id)
        }
    }

    private func reload(_ id: String) async {
        guard isLive, connection.phase == .online, conversation(id) != nil else { return }
        if loadingIDs.contains(id) { needsReload.insert(id); return }
        let epoch = generation
        loadingIDs.insert(id)
        historyProblems[id] = nil
        if conversation(id)?.messages.isEmpty == true { loading.insert(id) }
        defer {
            if epoch == generation {
                loadingIDs.remove(id); loading.remove(id)
                if needsReload.remove(id) != nil { scheduleReload(id) }
            }
        }
        do {
            let page = try await connection.history(id)
            guard epoch == generation, page.agentId == id, isLive else { return }
            applyPage(page)
        } catch { if epoch == generation { historyProblems[id] = "native.history.failed"; connection.report(error) } }
    }

    private func applyPage(_ incoming: HostPage) {
        var page = incoming
        guard conversation(page.agentId) != nil else { return }
        if fresh.contains(page.agentId), let old = workspace?.pages[page.agentId], old.threadId == page.threadId, old.revision > page.revision { return }
        page.recentPageInfo = incoming.pageInfo
        if let old = workspace?.pages[page.agentId], old.threadId == page.threadId {
            page.references = (old.references ?? [:]).merging(page.references ?? [:]) { _, new in new }
        }
        if let old = workspace?.pages[page.agentId], old.threadId == page.threadId,
           old.messages.count > 50, incoming.pageInfo?.hasOlder == true,
           let first = page.messages.first {
            let ids = Set(page.messages.map(\.id))
            let older = old.messages.filter { !ids.contains($0.id) && $0.createdAt < first.createdAt }
            if !older.isEmpty { page.messages = older + page.messages; page.pageInfo = old.pageInfo }
        }
        workspace?.pages[page.agentId] = page
        fresh.insert(page.agentId)
        if page.activeTurnId != nil { running.insert(page.agentId) } else { running.remove(page.agentId) }
        workspace?.settleDeliveredMessages(in: page)
        project(page.agentId)
        if activeID == page.agentId { markRead(page.agentId) }
        saveSoon()
        let buffered = unknownDeltas.removeValue(forKey: page.agentId) ?? []
        for event in buffered where event["threadId"]?.string == page.threadId { applyDelta(event) }
    }

    private func receive(_ event: WireValue) {
        guard isLive else { return }
        approvals.receive(event, hostID: connection.hostID)
        questions.receive(event, hostID: connection.hostID)
        tasks.receive(event, hostID: connection.hostID)
        if isActive, event["type"]?.string == "turn-completed", event["status"]?.string == "failed",
           event["agentId"]?.string == activeID, let turn = event["turnId"]?.string {
            if foregroundFailedTurns.count >= 128 { foregroundFailedTurns.removeAll() }
            foregroundFailedTurns.insert(turn)
        }
        routines.receive(event, connection: connection)
        browser.receive(event, hostID: connection.hostID)
        if event["type"]?.string == "agent-notification-levels-changed" {
            Task { if let preferences = await chatControls.preferences(connection: connection) { applyPreferences(preferences) } }
        }
        let type = event["type"]?.string
        if type == "runtime-snapshot", let value = event["snapshot"]?["agents"], let agents = try? value.decode([HostAgent].self) {
            applyAgents(agents)
            if case .array(let turns) = event["snapshot"]?["activeTurns"] {
                running = Set(turns.compactMap { turn in
                    guard let id = turn["agentId"]?.string,
                          let thread = turn["threadId"]?.string,
                          let current = workspace?.pages[id]?.threadId, thread == current else { return nil }
                    return id
                })
            }
            if let activeID { markRead(activeID) }
        } else if type == "conversation-page", let value = event["page"], let page = try? value.decode(HostPage.self) { applyPage(page) }
        else if type == "conversation", let snapshot = event["snapshot"] {
            if let page = try? snapshot.decode(HostPage.self) { applyPage(page) }
            else if let id = snapshot["agentId"]?.string, id == activeID, (snapshot["revision"]?.integer ?? Int.max) > (workspace?.pages[id]?.revision ?? -1) { scheduleReload(id) }
        } else if type == "conversation-delta" { applyDelta(event) }
        else if type == "agents-changed", let value = event["agents"], let agents = try? value.decode([HostAgent].self) { applyAgents(agents) }
        else if let id = event["agentId"]?.string, id == activeID {
            if type == "turn-completed" { running.remove(id); scheduleReload(id) }
            else if type == "conversation-invalidated", (event["revision"]?.integer ?? Int.max) > (workspace?.pages[id]?.revision ?? -1) { scheduleReload(id) }
        }
    }

    private func applyDelta(_ event: WireValue) {
        guard let id = event["agentId"]?.string, id == activeID,
              let messageID = event["messageId"]?.string, let delta = event["delta"]?.string,
              let revision = event["revision"]?.integer else { return }
        if fresh.contains(id), revision <= (workspace?.pages[id]?.revision ?? -1) { return }
        guard fresh.contains(id), var page = workspace?.pages[id], page.threadId == event["threadId"]?.string,
              revision == page.revision + 1, let index = page.messages.firstIndex(where: { $0.id == messageID }) else {
            if (unknownDeltas[id]?.count ?? 0) < 256 { unknownDeltas[id, default: []].append(event) }
            scheduleReload(id)
            return
        }
        let wasVisible = page.messages[index].isVisible
        page.messages[index].text += delta
        let isVisible = page.messages[index].isVisible
        let text = page.messages[index].text
        page.revision = revision
        workspace?.pages[id] = page
        running.insert(id)
        if wasVisible && isVisible {
            if !updateProjectedText(text, messageID: messageID, in: id) { project(id) }
        } else if wasVisible != isVisible { project(id) }
        saveSoon()
    }

    private func updateProjectedText(_ text: String, messageID: String, in id: String) -> Bool {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == id }),
              let rowIndex = replyProjections[id]?.rowIndices[messageID],
              conversations[conversationIndex].messages.indices.contains(rowIndex),
              conversations[conversationIndex].messages[rowIndex].id == messageID,
              replyProjections[id]?.updateText(text, for: messageID) == true else { return false }
        conversations[conversationIndex].messages[rowIndex].content = .text(text)
        refreshConversationMetadata(id, index: conversationIndex,
                                    latestHostMessage: workspace?.pages[id]?.messages.last(where: \.isVisible))
        return true
    }

    private func drainOutbox(automaticallyRecoveringReceipts: Bool = false) {
        guard connection.canSend, !persistenceBlocked else { return }
        if drain != nil { drainRequested = true; return }
        receiptRecovery?.cancel(); receiptRecovery = nil
        let epoch = generation
        drain = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == self.generation {
                    self.drain = nil
                    if self.drainRequested { self.drainRequested = false; self.drainOutbox() }
                    else { self.scheduleReceiptRecovery() }
                }
            }
            var attempted: Set<String> = automaticallyRecoveringReceipts
                ? Set(self.receiptRecoveryAttempts.compactMap { $0.value >= 3 ? $0.key : nil }) : []
            while !Task.isCancelled, epoch == self.generation, self.connection.canSend,
                  (!automaticallyRecoveringReceipts || self.isActive),
                  var next = self.workspace,
                  let message = next.nextSend(deduplicates: self.connection.deduplicatesMessages, excluding: attempted) {
                attempted.insert(message.clientID)
                if automaticallyRecoveringReceipts, message.state == .unconfirmed {
                    self.receiptRecoveryAttempts[message.clientID, default: 0] += 1
                }
                next.beginAttempt(message.clientID, deduplicates: self.connection.deduplicatesMessages)
                // This write must precede any request that can reach the host.
                guard self.commit(next) else { return }
                self.project(message.agentID)
                do {
                    let receipt = try await self.connection.send(message.text, to: message.agentID, clientID: message.clientID, attachmentIDs: message.attachments?.map(\.id) ?? [], replyToMessageID: message.replyToMessageId)
                    guard epoch == self.generation, var accepted = self.workspace else { return }
                    accepted.acceptReceipt(message.clientID, messageID: receipt)
                    let saved = self.commit(accepted, rememberOnFailure: true)
                    self.project(message.agentID)
                    guard saved else { return }
                    self.scheduleReload(message.agentID)
                } catch {
                    guard epoch == self.generation else { return }
                    if (error as? ConnectionProblem) == .auth { self.connection.report(error); return }
                    guard var failed = self.workspace, let position = failed.outbox.firstIndex(where: { $0.clientID == message.clientID }) else { return }
                    failed.outbox[position].state = (error as? ConnectionProblem) == .sendFailed ? .failed : .unconfirmed
                    let saved = self.commit(failed, rememberOnFailure: true)
                    self.project(message.agentID)
                    guard saved else { return }
                }
            }
        }
    }

    /// A response can be lost while RTC stays online. Recover only requests whose
    /// original client ID is proven repeat-safe by both the original and current
    /// host capability. Limit timer-driven attempts; explicit user/lifecycle
    /// recovery retains its existing behavior and every send still commits first.
    private func scheduleReceiptRecovery() {
        guard receiptRecovery == nil, isActive, connection.canSend, !persistenceBlocked,
              let workspace else { return }
        let unsettled = Set(workspace.outbox.filter { $0.state == .unconfirmed }.map(\.clientID))
        receiptRecoveryAttempts = receiptRecoveryAttempts.filter { unsettled.contains($0.key) }
        let exhausted = Set(receiptRecoveryAttempts.compactMap { $0.value >= 3 ? $0.key : nil })
        guard let message = workspace.nextSend(deduplicates: connection.deduplicatesMessages, excluding: exhausted),
              message.state == .unconfirmed else { return }
        let epoch = generation
        let delay = 2 << receiptRecoveryAttempts[message.clientID, default: 0]
        receiptRecovery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, epoch == self.generation else { return }
            self.receiptRecovery = nil
            guard self.isActive, self.connection.canSend, !self.persistenceBlocked else { return }
            self.drainOutbox(automaticallyRecoveringReceipts: true)
        }
    }

    @discardableResult
    private func commit(_ state: LiveWorkspaceState, rememberOnFailure: Bool = false) -> Bool {
        guard let disk else { connection.problem = .storage; return false }
        let resumesPersistence = persistenceBlocked
        do {
            try disk.save(state)
            workspace = state
            persistenceBlocked = false
            if resumesPersistence {
                if connection.problem == .storage { connection.problem = nil }
                // A failed pre-send write leaves a durable queued message. Any
                // successful later save can resume it with its original ID.
                drainOutbox()
            }
            return true
        }
        catch {
            if rememberOnFailure { workspace = state }
            persistenceBlocked = true
            connection.problem = .storage
            return false
        }
    }

    private func saveSoon() {
        persistence?.cancel()
        persistence = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        persistence?.cancel(); persistence = nil
        if let workspace { _ = commit(workspace) }
    }

    private func dateFromWire(_ value: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

struct ReplyTimelineItem: Identifiable {
    let id: String
    let rootID: String?
    var messages: [ChatMessage]
}
