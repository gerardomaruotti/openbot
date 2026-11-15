import Foundation

struct LiveWorkspaceState: Codable {
    let scope: String
    var agents: [HostAgent] = []
    var pages: [String: HostPage] = [:]
    var outbox: [OutboxMessage] = []
    var lastOpenedID: String?
    var readAt: [String: String]? = nil
    var pinnedAgents: [String]? = nil
    var drafts: [String: String]? = nil
    var draftReplyTargets: [String: String]? = nil
    var agentNotificationLevels: [String: String]? = nil
    var serverNotificationLevel: String? = nil

    mutating func recoverInterruptedSends() {
        for index in outbox.indices where outbox[index].state == .sending {
            outbox[index].state = .unconfirmed
        }
    }

    mutating func beginAttempt(_ id: String, deduplicates: Bool, now: Date = .now) {
        guard let index = outbox.firstIndex(where: { $0.clientID == id }) else { return }
        outbox[index].state = .sending
        if outbox[index].firstAttemptAt == nil {
            outbox[index].firstAttemptAt = now
            outbox[index].repeatSafe = deduplicates
        }
    }

    mutating func acceptReceipt(_ id: String, messageID: String) {
        guard let index = outbox.firstIndex(where: { $0.clientID == id }) else { return }
        outbox[index].state = .sent
        outbox[index].messageID = messageID
        outbox[index].usesConversationID = true
    }

    mutating func settleDeliveredMessages(in page: HostPage) {
        let ids = Set(page.messages.map(\.id))
        outbox.removeAll { $0.agentID == page.agentId && $0.state == .sent && ($0.usesConversationID != true || $0.messageID.map(ids.contains) == true) }
    }

    /// The first unsettled send in a chat owns its order until it is resolved or cancelled.
    func nextSend(deduplicates: Bool, excluding attempted: Set<String>, now: Date = .now) -> OutboxMessage? {
        var blockedAgents: Set<String> = []
        for message in outbox {
            if message.state == .sent { continue }
            guard blockedAgents.insert(message.agentID).inserted else { continue }
            if !attempted.contains(message.clientID), message.canAttempt(deduplicates: deduplicates, now: now) { return message }
        }
        return nil
    }
}

struct OutboxMessage: Codable, Identifiable {
    let clientID: String
    let agentID: String
    let text: String
    let createdAt: Date
    var state: MessageDeliveryState = .queued
    var firstAttemptAt: Date?
    var repeatSafe = false
    var messageID: String?
    // Older native builds saved the mailbox ID. Retire those acknowledged placeholders on a fresh host page.
    var usesConversationID: Bool?
    var attachments: [HostAttachment]? = nil
    // Keep the target immutable with this client ID on every retry.
    var replyToMessageId: String? = nil
    var id: String { clientID }
    var rowID: String { messageID ?? "pending-\(clientID)" }

    func canAttempt(deduplicates: Bool, now: Date = .now) -> Bool {
        if state == .queued && firstAttemptAt == nil { return true }
        guard state == .unconfirmed, repeatSafe, deduplicates, let firstAttemptAt else { return false }
        // Match the existing phone client's conservative half of the host's 24-hour window.
        return (0..<(12 * 60 * 60)).contains(now.timeIntervalSince(firstAttemptAt))
    }
}
