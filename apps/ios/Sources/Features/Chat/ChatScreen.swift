import SwiftUI
import UIKit

struct ChatScreen: View {
    let store: ConversationStore
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppHaptics.self) private var haptics
    @State private var isVisible = false
    @State private var showsActionError = false
    @State private var showsContact = false
    @State private var showsAttachments = false
    @State private var attachment: AttachmentPreview?
    @State private var selectedMessageID: String?
    @State private var messageFrames: [String: CGRect] = [:]
    @State private var pendingRemovalID: String?
    @State private var cameraContext: CaptureContext?
    @State private var dictationContext: CaptureContext?
    @State private var showsBrowser = false
    @State private var selectedText: SelectedMessageText?
    @State private var focusedReplyTargetID: String?
    @State private var isNearBottom = true
    @State private var viewportSize = CGSize(width: 402, height: 660)
    private var files: NativeAttachments { store.attachments }
    @FocusState private var isComposerFocused: Bool

    private var conversation: Conversation? { store.conversation(conversationID) }
    private var draft: String { store.draftText(conversationID) }
    private var draftBinding: Binding<String> {
        Binding(get: { store.draftText(conversationID) }, set: { text in
            if let focusedReplyTargetID { store.setReplyTarget(focusedReplyTargetID, in: conversationID) }
            store.setDraftText(text, for: conversationID)
        })
    }
    private var focusedReplyRootID: String? {
        focusedReplyTargetID.map { store.replyRoots(conversationID)[$0] ?? $0 }
    }
    private var missingReplyTarget: Bool {
        focusedReplyTargetID.map { !store.canReply($0, in: conversationID) } ?? false
    }
    private var captureID: String { (store.connection.workspaceID ?? "sample") + ":" + conversationID }

    var body: some View {
        if let conversation {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    conversation.background.color.ignoresSafeArea()
                    messageHistory(conversation, width: geometry.size.width)
                        .blur(radius: focusedReplyRootID == nil ? 0 : 20)
                        .opacity(focusedReplyRootID == nil ? 1 : 0.24)
                        .allowsHitTesting(focusedReplyRootID == nil)
                        .accessibilityHidden(focusedReplyRootID != nil)
                    if let rootID = focusedReplyRootID {
                        focusedReply(conversation, rootID: rootID, width: geometry.size.width)
                    }
                    if let selectedMessageID {
                        reactionOverlay(messageID: selectedMessageID, width: geometry.size.width)
                    }
                }
                .coordinateSpace(name: "chat-content")
                .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
                .onPreferenceChange(MessageFramesKey.self) { messageFrames = $0 }
            }
            .background { ConversationBackGesture().frame(width: 0, height: 0) }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if focusedReplyRootID == nil { chatHeader(conversation) }
                else { replyHeader(conversation) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(isBlocked: conversation.isBlocked) }
            .navigationDestination(isPresented: $showsContact) {
                ContactDetailScreen(store: store, conversationID: conversationID)
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .task(id: conversationID) {
                if let target = store.draftReplyTarget(conversationID), store.canReply(target, in: conversationID) {
                    focusedReplyTargetID = target
                }
                await store.openConversation(conversationID)
            }
            .task(id: store.connection.workspaceID) { files.bind(store.connection) }
            .alert("native.error.generic", isPresented: $showsActionError) {
                Button("native.action.done", role: .cancel) { }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { showsActionError = false } }
            .onChange(of: files.problemRevision) { _, _ in
                if files.problem != nil { showActionFailure(context: captureID) }
            }
            .onChange(of: store.chatControls.problemRevision) { _, _ in
                if store.chatControls.problem != nil, store.chatControls.problemAgentID == conversationID { showActionFailure(context: captureID) }
            }
            .onChange(of: captureID) { _, _ in
                cameraContext = nil; dictationContext = nil
                showsActionError = false
                selectedText = nil; selectedMessageID = nil
                focusedReplyTargetID = nil
            }
            .fullScreenCover(item: $cameraContext) { context in
                CameraCaptureSheet(contextID: captureID, onCapture: { input in
                    cameraContext = nil
                    guard context.id == captureID, store.conversation(conversationID) != nil else { return }
                    importAttachment { await files.importPhoto(input, connection: store.connection) }
                }, onCancel: { cameraContext = nil })
            }
            .sheet(item: $dictationContext) { context in
                DictationSheet(contextID: captureID, onInsert: { text in
                    dictationContext = nil
                    guard context.id == captureID, store.conversation(conversationID) != nil else { return }
                    if let focusedReplyTargetID { store.setReplyTarget(focusedReplyTargetID, in: conversationID) }
                    let current = store.draftText(conversationID)
                    let separator = current.isEmpty || current.last?.isWhitespace == true ? "" : " "
                    store.setDraftText(current + separator + text, for: conversationID)
                    if store.draftText(conversationID) == current + separator + text { haptics.play(.selection) }
                }, onCancel: { dictationContext = nil })
            }
            .sheet(isPresented: $showsBrowser) {
                BrowserSessionScreen(session: store.browser, connection: store.connection)
            }
            .sheet(item: $selectedText) { selection in
                NavigationStack {
                    ScrollView {
                        Text(selection.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("native.action.selectText")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("native.action.copy", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = selection.text
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("native.action.done") { selectedText = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { files.previewURL != nil }, set: { if !$0 { files.closePreview() } })) {
                NavigationStack {
                    Group {
                        if let url = files.previewURL { AttachmentQuickLook(url: url).ignoresSafeArea(edges: .bottom) }
                    }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            if let url = files.previewURL {
                                ShareLink(item: url) { Label("native.files.share", systemImage: "square.and.arrow.up") }
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) { Button("native.action.done") { files.closePreview() } }
                    }
                }
            }
            .confirmationDialog("native.attachment.add", isPresented: $showsAttachments, titleVisibility: .hidden) {
                Button("native.attachment.photos", systemImage: "photo") { showActionFailure(context: captureID) }
                Button("native.attachment.camera", systemImage: "camera") { showActionFailure(context: captureID) }
                Button("native.attachment.files", systemImage: "folder") { showActionFailure(context: captureID) }
            }
            .sheet(item: $attachment) { attachment in AttachmentDetailSheet(attachment: attachment) }
            .confirmationDialog("native.connection.removePendingWarning", isPresented: Binding(get: { pendingRemovalID != nil }, set: { if !$0 { pendingRemovalID = nil } }), titleVisibility: .visible) {
                Button("native.connection.removePending", role: .destructive) {
                    if let id = pendingRemovalID { store.discardUnconfirmed(id) }
                    pendingRemovalID = nil
                }
            }
        }
    }

    private func messageHistory(_ conversation: Conversation, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Keep transient forms and the final scroll anchor eagerly sized.
                // Removing a tall lazy form can retain an obsolete content offset.
                VStack(spacing: 6) {
                    Text("OpenBot").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .frame(height: 26)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    if store.hasOlder(conversationID) {
                        Button("native.history.older") {
                            let anchor = conversation.messages.first?.id
                            let context = captureID
                            Task {
                                await store.loadOlder(conversationID)
                                if store.historyProblems[conversationID] != nil { showActionFailure(context: context) }
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        }
                        .font(.caption)
                        .disabled(store.loadingOlder.contains(conversationID) || !store.connection.canSend)
                    }
                    if store.loadingOlder.contains(conversationID) { ProgressView() }

                    LazyVStack(spacing: 6) {
                        ForEach(store.replyTimeline(conversationID)) { item in
                            if let rootID = item.rootID {
                                let parent = store.replyMessage(rootID, in: conversationID)
                                ReplyThreadGroup(quoteText: replyText(parent), quoteOutgoing: parent?.isOutgoing ?? false,
                                                 replyCount: item.messages.count, maximumWidth: width * 0.70,
                                                 openThread: { openReplyThread(rootID) }) {
                                    ForEach(item.messages) { message in messageRow(message, width: width) }
                                }
                            } else {
                                ForEach(item.messages) { message in messageRow(message, width: width) }
                            }
                        }
                    }
                    ForEach(store.approvals.pending.filter { $0.agentID == conversationID }) { approval in
                        ApprovalCard(approval: approval, available: store.connection.canSend,
                                     responding: !store.approvals.responding.isEmpty) { allow in
                            let context = captureID
                            Task {
                                let confirmed = await store.approvals.respond(approval, allow: allow, connection: store.connection)
                                guard isVisible, captureID == context else { return }
                                guard !store.approvals.pending.contains(where: { $0.id == approval.id && $0 != approval }) else { return }
                                if confirmed { haptics.play(.action) }
                                else if store.approvals.pending.contains(approval), store.approvals.problem != nil {
                                    haptics.play(.warning); showActionFailure(context: context)
                                }
                            }
                        }
                    }
                    ForEach(store.questions.pending.filter { $0.agentID == conversationID }) { prompt in
                        QuestionCard(prompt: prompt, available: store.connection.canSend, responding: store.questions.responding) { answers in
                            let context = captureID
                            let confirmed = await store.questions.respond(prompt, answers: answers, connection: store.connection)
                            if isVisible, captureID == context,
                               !store.questions.pending.contains(where: { $0.id == prompt.id && $0 != prompt }) {
                                if confirmed { haptics.play(.action) }
                                else if store.questions.pending.contains(prompt), store.questions.problem != nil {
                                    haptics.play(.warning); showActionFailure(context: context)
                                }
                            }
                            return confirmed
                        }
                        .id(prompt.id)
                    }
                    ForEach(store.browserHandoffs(conversationID)) { handoff in
                        BrowserHandoffCard(handoff: handoff, available: store.connection.canSend,
                            responding: !store.tasks.cancelling.isEmpty,
                            problem: store.tasks.cancellationProblems[handoff.id],
                            cancel: { Task { await store.tasks.cancel(handoff, connection: store.connection) } },
                            open: store.connection.features.browserView || store.connection.features.browserSecretHandoff ? {
                                store.browser.prepare(handoff, connection: store.connection)
                                showsBrowser = true
                            } : nil)
                    }
                    if store.hasForegroundTaskFailure(conversationID) {
                        Text("native.error.generic").font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                    if store.questions.unavailableAgents.contains(conversationID) {
                        Text("native.question.openOnMac").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.loading.contains(conversationID) { ProgressView().padding(8) }
                    if store.running.contains(conversationID) && store.browserHandoffs(conversationID).isEmpty {
                        HStack(spacing: 12) {
                            Text("native.connection.working").foregroundStyle(.secondary)
                            Button("native.chat.stop", systemImage: "stop.circle") {
                                let context = captureID
                                Task { if !(await store.stop(conversationID)) { showActionFailure(context: context) } }
                            }
                                .disabled(!store.canStop(conversationID))
                        }
                        .font(.caption).padding(8)
                    }
                    Color.clear.frame(height: 4).id("latest-message")
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            } action: { _, value in isNearBottom = value }
            .defaultScrollAnchor(store.isLive ? .bottom : .top)
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: store.approvals.pending.map(\.id)) { _, _ in
                proxy.scrollTo("latest-message", anchor: .bottom)
            }
            .onChange(of: store.questions.pending.map(\.id)) { _, _ in
                // Question fields own their focus. Do not retain composer focus across
                // a form that can disappear when another device or the host resolves it.
                isComposerFocused = false
                proxy.scrollTo("latest-message", anchor: .bottom)
            }
            .onChange(of: conversation.messages.last?.id) { old, new in
                if new != old && isNearBottom {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("latest-message", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, width: CGFloat) -> some View {
        MessageHistoryRow(
            message: message,
            maximumWidth: width * 0.70,
            viewportWidth: width,
            allowsReply: store.canReply(message.id, in: conversationID),
            downloadingID: files.downloadingID,
            openFile: { file in Task { await files.open(file, connection: store.connection) } },
            openAttachment: { name, detail in attachment = AttachmentPreview(name: name, detail: detail) },
            reply: { openReply(message.id) }
        )
        .id(message.id)
        .contextMenu {
            if store.canReply(message.id, in: conversationID) {
                Button("native.reply.action", systemImage: "arrowshape.turn.up.left") { openReply(message.id) }
                    .tint(.primary)
            }
            if store.canReact(message.id, in: conversationID) {
                Button("native.reaction.add", systemImage: "face.smiling") { selectedMessageID = message.id }
                    .tint(.primary)
            }
            if case .text(let text) = message.content, !text.isEmpty {
                Button("native.action.copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
                    .tint(.primary)
                Button("native.action.selectText", systemImage: "character.cursor.ibeam") {
                    selectedText = SelectedMessageText(text: text)
                }
                .tint(.primary)
            }
            if store.canCancel(message.id) {
                Button("native.connection.cancelSend", role: .destructive) { store.cancelMessage(message.id) }
                    .tint(.red)
            }
            if store.canDiscard(message.id) {
                Button("native.connection.removePending", role: .destructive) { pendingRemovalID = message.id }
                    .tint(.red)
            }
        } preview: {
            MessageContextPreview(message: message, viewportSize: viewportSize)
        }
        if store.canRetry(message.id) {
            Button("native.connection.retryMessage") { store.retryMessage(message.id) }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func openReply(_ messageID: String) {
        guard store.canReply(messageID, in: conversationID) else { return }
        selectedMessageID = nil
        store.setReplyTarget(messageID, in: conversationID)
        focusedReplyTargetID = messageID
        isComposerFocused = true
        haptics.play(.selection)
    }

    private func closeReply() {
        focusedReplyTargetID = nil
        store.setReplyTarget(nil, in: conversationID)
        isComposerFocused = false
    }

    private func openReplyThread(_ rootID: String) {
        selectedMessageID = nil
        focusedReplyTargetID = rootID
        let available = store.canReply(rootID, in: conversationID)
        store.setReplyTarget(available ? rootID : nil, in: conversationID)
        isComposerFocused = available
    }

    private func replyText(_ message: ChatMessage?) -> String? {
        guard let message else { return nil }
        switch message.content {
        case .text(let text): return text.isEmpty ? message.attachments?.map(\.name).joined(separator: ", ") : text
        case .emoji(let emoji): return emoji
        case .link(let title, _): return title
        case .attachment(let name, _): return name
        }
    }

    private func focusedReply(_ conversation: Conversation, rootID: String, width: CGFloat) -> some View {
        FocusedReplyThread(close: closeReply, showsHeader: false) {
            Color.clear
        } header: { EmptyView() } thread: {
            VStack(spacing: 8) {
                if store.hasOlder(conversationID) {
                    Button("native.history.older") {
                        let context = captureID
                        Task {
                            await store.loadOlder(conversationID)
                            if store.historyProblems[conversationID] != nil { showActionFailure(context: context) }
                        }
                    }
                        .font(.caption)
                        .disabled(store.loadingOlder.contains(conversationID) || !store.connection.canSend)
                }
                if let parent = store.replyMessage(rootID, in: conversationID) {
                    messageRow(parent, width: width)
                } else { Text("native.reply.unavailable").font(.callout).foregroundStyle(.secondary) }
                ForEach(store.replies(to: rootID, in: conversationID)) { message in
                    messageRow(message, width: width)
                }
                if store.running.contains(conversationID) {
                    Text("native.connection.working").font(.caption).foregroundStyle(.secondary)
                    Button("native.reply.returnToChat") { closeReply() }
                        .font(.caption)
                }
            }
        } composer: { EmptyView() }
    }

    private func replyHeader(_ conversation: Conversation) -> some View {
        VStack(spacing: -4) {
            AvatarView(asset: conversation.avatar, size: 60)
            Text(conversation.name)
                .font(.headline).lineLimit(1)
                .padding(.horizontal, 13).frame(minHeight: 33)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            GlassIconButton(symbol: "xmark", label: "native.reply.close", action: closeReply)
                .padding(.trailing, 16)
        }
        .padding(.bottom, 8)
    }

    private func chatHeader(_ conversation: Conversation) -> some View {
        ZStack(alignment: .top) {
            HStack {
                GlassIconButton(symbol: "chevron.backward", label: "native.action.back") { dismiss() }
                Spacer()
                if !store.isLive { GlassIconButton(symbol: "video", label: "native.contact.video") { showActionFailure(context: captureID) } }
            }
            .padding(.horizontal, 16)
            VStack(spacing: -4) {
                AvatarView(asset: conversation.avatar, size: 60)
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 4)
                Button { isComposerFocused = false; showsContact = true } label: {
                    HStack(spacing: 5) {
                        Text(conversation.name).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 33)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityHint("native.contact.openHint")
            }
            .padding(.horizontal, 64)
        }
        .padding(.top, 0)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [conversation.background.color, conversation.background.color.opacity(0.98), conversation.background.color.opacity(0)], startPoint: .top, endPoint: .bottom)
                .padding(.bottom, -10)
                .ignoresSafeArea(edges: .top)
        }
    }

    private func composer(isBlocked: Bool) -> some View {
        VStack(spacing: 0) {
        if store.isLive {
            AttachmentDrafts(attachments: files.drafts, busy: files.isBusy) { file in Task { await files.remove(file, connection: store.connection) } }
        }
        GlassEffectContainer(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                if store.isLive && store.connection.supportsAttachments {
                    AttachmentPickerButton(disabled: !store.connection.canSend || files.isBusy,
                        importFile: { url in importAttachment { await files.importFile(url, connection: store.connection) } },
                        importPhoto: { input in importAttachment { await files.importPhoto(input, connection: store.connection) } },
                        failed: files.selectionFailed,
                        capturePhoto: { cameraContext = CaptureContext(id: captureID) })
                } else if !store.isLive { GlassIconButton(symbol: "plus", label: "native.attachment.add", size: 42) { showsAttachments = true } }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(isBlocked ? "native.composer.blocked" : focusedReplyRootID != nil ? "native.reply.placeholder" : "native.composer.placeholder", text: draftBinding, axis: .vertical)
                        .accessibilityLabel("native.composer.placeholder")
                        .accessibilityIdentifier("message-composer")
                        .font(.body)
                        .lineLimit(1...6)
                        .focused($isComposerFocused)
                        .padding(.vertical, 9)
                        .disabled(isBlocked || missingReplyTarget)
                    if !isBlocked {
                        Button { isComposerFocused = false; dictationContext = CaptureContext(id: captureID) } label: {
                            Image(systemName: "mic").font(.body).frame(width: 26, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("native.dictation.title")
                        .disabled(!store.canCompose || missingReplyTarget)
                        .padding(.bottom, 5)
                    }
                    if (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.drafts.isEmpty) && !isBlocked {
                        Button {
                            if store.send(draft, to: conversationID, attachments: files.drafts, replyToMessageID: focusedReplyTargetID) {
                                files.consume()
                                haptics.play(.action)
                            } else {
                                haptics.play(.error); showActionFailure(context: captureID)
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 30)
                                .background(MessagesStyle.accent, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canCompose || files.isBusy || missingReplyTarget)
                        .padding(.bottom, 6)
                        .accessibilityLabel("native.composer.send")
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 7)
                .frame(minHeight: 42)
                .glassEffect(.regular, in: .capsule)
            }
        }
        }
        .padding(.horizontal, isComposerFocused ? 16 : 27)
        .padding(.top, 8)
        .padding(.bottom, isComposerFocused ? 8 : -7)
    }

    private func reactionOverlay(messageID: String, width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Color.primary.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture { selectedMessageID = nil }
            ReactionPicker { reaction in
                guard store.canReact(messageID, in: conversationID) else { selectedMessageID = nil; return }
                store.react(reaction, to: messageID, in: conversationID)
                selectedMessageID = nil
                haptics.play(.selection)
            }
            .frame(width: width - 20)
            .position(x: width / 2, y: max(42, (messageFrames[messageID]?.minY ?? 180) - 40))
        }
    }

    private func showActionFailure(context: String) {
        guard isVisible, scenePhase == .active, captureID == context else { return }
        showsActionError = true
    }

    private func importAttachment(_ operation: @escaping () async -> Void) {
        let context = captureID
        let previousIDs = Set(files.drafts.map(\.id))
        Task {
            await operation()
            guard isVisible, captureID == context else { return }
            if files.drafts.contains(where: { !previousIDs.contains($0.id) }) { haptics.play(.selection) }
        }
    }
}

private struct CaptureContext: Identifiable { let id: String }
private struct SelectedMessageText: Identifiable { let id = UUID(); let text: String }

private struct MessageHistoryRow: View {
    let message: ChatMessage
    let maximumWidth: CGFloat
    let viewportWidth: CGFloat
    let allowsReply: Bool
    let downloadingID: String?
    let openFile: (HostAttachment) -> Void
    let openAttachment: (String, String) -> Void
    let reply: () -> Void
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.2))) private var replyOffset: CGFloat = 0
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        VStack(spacing: 8) {
            if let timestamp = message.timestamp {
                Text(timestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            payload

        }
    }

    private var payload: some View {
        VStack(spacing: 6) {
            if hasBody {
                MessageBubble(message: message, maximumWidth: maximumWidth, openAttachment: openAttachment, selectableText: false)
            }
            ForEach(message.attachments ?? []) { file in
                LiveAttachmentButton(attachment: file, downloading: downloadingID == file.id) { openFile(file) }
                    .frame(maxWidth: maximumWidth)
                    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: MessageFramesKey.self, value: [message.id: geometry.frame(in: .named("chat-content"))])
            }
        }
        .offset(x: layoutDirection == .leftToRight ? replyOffset : -replyOffset)
        .overlay(alignment: .leading) { ReplySwipeIndicator(progress: replyOffset / 58).offset(x: -4) }
        .simultaneousGesture(DragGesture(minimumDistance: 18, coordinateSpace: .named("chat-content"))
            .updating($replyOffset) { value, offset, _ in
                offset = replyDistance(value)
            }
            .onEnded { value in
                if replyDistance(value) >= 42 { reply() }
            })

    }

    private func replyDistance(_ value: DragGesture.Value) -> CGFloat {
        let distanceFromEdge = layoutDirection == .leftToRight ? value.startLocation.x : viewportWidth - value.startLocation.x
        let translation = layoutDirection == .leftToRight ? value.translation.width : -value.translation.width
        guard allowsReply, distanceFromEdge > 24, translation > 0,
              translation > abs(value.translation.height) * 1.4 else { return 0 }
        return min(translation * 0.65, 78)
    }

    private var hasBody: Bool {
        if case .text(let text) = message.content { return !text.isEmpty }
        return true
    }
}

private struct MessageFramesKey: PreferenceKey {
    nonisolated static var defaultValue: [String: CGRect] { [:] }
    nonisolated static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ReactionPicker: View {
    let select: (Reaction) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Reaction.allCases) { reaction in
                    Button { select(reaction) } label: {
                        Group {
                            if let asset = reaction.pickerAsset {
                                Image(asset).resizable().scaledToFit().frame(width: 29, height: 29)
                            } else {
                                Text(reaction.emoji).font(.system(size: 27))
                            }
                        }
                        .frame(width: 49, height: 64)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("native.reaction.label \(reaction.emoji)"))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 64)
        .padding(.horizontal, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct AttachmentPreview: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
}

private struct AttachmentDetailSheet: View {
    let attachment: AttachmentPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(attachment.name, systemImage: "doc")
            } description: {
                Text(attachment.detail)
                Text("native.attachment.previewMessage")
            }
            .navigationTitle("native.attachment.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("native.action.done") { dismiss() } } }
        }
    }
}

enum UnavailableFeature: String, Identifiable {
    case calls, attachments
    var id: Self { self }
    var message: LocalizedStringResource {
        switch self {
        case .calls: "native.contact.callsUnavailable"
        case .attachments: "native.attachment.unavailable"
        }
    }
}
