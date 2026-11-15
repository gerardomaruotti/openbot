import CryptoKit
import Foundation

@main
struct WorkspaceRecoveryE2E {
    enum Failure: Error { case check(String) }
    static func require(_ value: Bool, _ stage: String) throws {
        if !value { throw Failure.check(stage) }
    }

    static func main() {
        do {
            let mode = CommandLine.arguments[1]
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let disk = LiveWorkspaceDisk(directory: root, key: SymmetricKey(data: Data(repeating: 0x53, count: 32)))
            let marker = "SYNTHETIC-OUTBOX-RESTART-PRIVATE-CONTENT"
            let commentary = HostMessage(id: "thinking", author: "assistant", text: "Following exact format", createdAt: "2026-11-13T10:00:00Z", status: "completed", itemType: "commentary")
            let empty = HostMessage(id: "empty", author: "assistant", text: " \n ", createdAt: "2026-11-13T10:00:00Z", status: "streaming", itemType: "agentMessage")
            let answer = HostMessage(id: "answer", author: "assistant", text: "TEST-ONCE received", createdAt: "2026-11-13T10:00:00Z", status: "completed", itemType: nil)
            try require(!commentary.isVisible, "commentary-hidden")
            try require(!empty.isVisible, "empty-hidden")
            try require(answer.isVisible, "legacy-answer-visible")
            if mode == "projection" { print("{\"projection\":true}"); return }

            if mode == "write" {
                var state = LiveWorkspaceState(scope: "account-A-host-A-member-A")
                state.agents = [HostAgent(id: "agent-A", name: "Synthetic", title: nil)]
                state.drafts = ["agent-A": "SYNTHETIC-UNSENT-DRAFT", "agent-B": "SYNTHETIC-OTHER-DRAFT"]
                state.agentNotificationLevels = ["agent-A": "nothing"]
                state.serverNotificationLevel = "needs-me"
                state.draftReplyTargets = ["agent-A": "history-1"]
                state.outbox = [
                    OutboxMessage(clientID: "stable-one", agentID: "agent-A", text: marker, createdAt: .now,
                                  attachments: [HostAttachment(id: "draft-file-one", name: "synthetic.txt", mimeType: "text/plain", size: 4, kind: "file", previewKind: nil)], replyToMessageId: "history-0"),
                    OutboxMessage(clientID: "stable-two", agentID: "agent-A", text: "SYNTHETIC-SECOND", createdAt: .now)
                ]
                state.pages["agent-A"] = HostPage(agentId: "agent-A", threadId: "thread-A", activeTurnId: nil, revision: 75,
                    messages: (0..<75).map { index in
                        HostMessage(id: "history-\(index)", author: "assistant", text: "History \(index)", createdAt: "2026-11-13T10:00:00Z", status: "completed", itemType: nil,
                            reaction: index == 74 ? "👍" : nil,
                            reactions: index == 74 ? [HostReaction(emoji: "👍", actor: .init(kind: "user"))] : nil)
                    }, pageInfo: .init(hasOlder: true, olderCursor: "loaded-oldest-cursor"),
                    recentPageInfo: .init(hasOlder: true, olderCursor: "latest-fifty-cursor"))
                state.beginAttempt("stable-one", deduplicates: true)
                try disk.save(state)
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                try require(files.count == 1, "one-encrypted-file")
                let raw = try Data(contentsOf: files[0])
                try require(raw.range(of: Data(marker.utf8)) == nil, "no-plaintext-message")
                try require(raw.range(of: Data("SYNTHETIC-UNSENT-DRAFT".utf8)) == nil, "no-plaintext-draft")
                print("{\"encryptedWrite\":true}")
                return
            }

            guard var recovered = try disk.load(scope: "account-A-host-A-member-A") else { throw Failure.check("restart-load") }
            try require(recovered.outbox[0].state == .unconfirmed, "interrupted-send-uncertain")
            try require(recovered.outbox[0].text == marker, "content-survives-restart")
            try require(recovered.drafts?["agent-A"] == "SYNTHETIC-UNSENT-DRAFT", "unsent-draft-survives-restart")
            try require(recovered.drafts?["agent-B"] == "SYNTHETIC-OTHER-DRAFT", "drafts-are-per-agent")
            try require(recovered.agentNotificationLevels == ["agent-A": "nothing"] && recovered.serverNotificationLevel == "needs-me", "member-alert-preferences-survive-restart")
            try require(recovered.pages["agent-A"]?.messages.last?.reaction == "👍" && recovered.pages["agent-A"]?.messages.last?.reactions?.first?.emoji == "👍", "host-reactions-survive-restart")
            try require(recovered.outbox[0].replyToMessageId == "history-0", "immutable-outbox-reply-target-survives-restart")
            try require(recovered.draftReplyTargets?["agent-A"] == "history-1", "draft-reply-target-survives-restart")
            try require(recovered.pages["agent-A"]?.references?["history-0"]?.text == "History 0" && recovered.pages["agent-A"]?.references?["history-1"]?.text == "History 1", "trimmed-reply-context-retained-for-outbox-and-draft")
            try require(recovered.outbox[0].attachments?.map(\.id) == ["draft-file-one"], "attachment-id-survives-restart")
            try require(recovered.pages["agent-A"]?.messages.count == 50, "cache-keeps-recent-fifty")
            try require(recovered.pages["agent-A"]?.messages.first?.id == "history-25", "cache-retains-newest-messages")
            try require(recovered.pages["agent-A"]?.pageInfo?.olderCursor == "latest-fifty-cursor", "cache-cursor-can-reload-trimmed-history")
            try require(recovered.nextSend(deduplicates: false, excluding: []) == nil, "no-unsafe-retry-or-reorder")
            try require(recovered.nextSend(deduplicates: true, excluding: [])?.clientID == "stable-one", "retry-stable-id")
            let attempt = recovered.outbox[0].firstAttemptAt!
            try require(recovered.nextSend(deduplicates: true, excluding: [], now: attempt.addingTimeInterval(13 * 3600)) == nil, "expired-retry-blocked")
            try require(recovered.nextSend(deduplicates: true, excluding: [], now: attempt.addingTimeInterval(-1)) == nil, "backward-clock-blocked")
            recovered.beginAttempt("stable-one", deduplicates: true)
            try require(recovered.outbox[0].firstAttemptAt == attempt, "retry-window-never-extended")
            recovered.acceptReceipt("stable-one", messageID: "host-confirmed-one")
            try disk.save(recovered)
            guard var confirmed = try disk.load(scope: recovered.scope) else { throw Failure.check("receipt-restart") }
            try require(confirmed.outbox[0].messageID == "host-confirmed-one", "receipt-durable")
            try require(confirmed.nextSend(deduplicates: true, excluding: [])?.clientID == "stable-two", "chat-order-unblocked")
            let delivered = HostMessage(id: "host-confirmed-one", author: "user", text: marker, createdAt: "2026-11-13T10:00:00Z", status: "completed", itemType: nil)
            confirmed.settleDeliveredMessages(in: HostPage(agentId: "agent-A", threadId: "thread-A", activeTurnId: nil, revision: 1, messages: [delivered]))
            try require(confirmed.outbox.map(\.clientID) == ["stable-two"], "receipt-id-settles-one-copy")

            // Earlier native builds saved the mailbox receipt ID as the bubble ID.
            confirmed.outbox.append(OutboxMessage(clientID: "legacy-sent", agentID: "agent-A", text: "LEGACY-ACKNOWLEDGED", createdAt: .now, state: .sent, messageID: "mailbox-id"))
            try disk.save(confirmed)
            guard var legacy = try disk.load(scope: confirmed.scope) else { throw Failure.check("legacy-cache-read") }
            legacy.settleDeliveredMessages(in: HostPage(agentId: "agent-A", threadId: "thread-A", activeTurnId: nil, revision: 2, messages: [delivered]))
            try require(legacy.outbox.map(\.clientID) == ["stable-two"], "legacy-ack-retired-queue-preserved")

            let before = Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
            try disk.save(LiveWorkspaceState(scope: "account-A-host-A-member-B"))
            let after = Set(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
            let foreign = after.subtracting(before).first!
            let original = before.first!
            try Data(contentsOf: original).write(to: foreign, options: .atomic)
            var rejected = false
            do { _ = try disk.load(scope: "account-A-host-A-member-B") } catch { rejected = true }
            try require(rejected, "membership-ciphertext-swap-rejected")
            var corrupted = try Data(contentsOf: original)
            corrupted[corrupted.count - 1] ^= 1
            try corrupted.write(to: original, options: .atomic)
            rejected = false
            do { _ = try disk.load(scope: recovered.scope) } catch { rejected = true }
            try require(rejected, "tamper-rejected")
            try disk.save(LiveWorkspaceState(scope: recovered.scope))
            try disk.retain(scopes: [recovered.scope])
            try require(try disk.load(scope: "account-A-host-A-member-B") == nil, "removed-membership-pruned")
            try require(try disk.load(scope: recovered.scope) != nil, "current-workspace-retained")
            print("{\"processRestartRecovery\":true,\"encryptedDraftRecovery\":true,\"memberAlertsAndReactionsRecovery\":true,\"boundedRetry\":true,\"chatOrder\":true,\"receiptSettlement\":true,\"scopeBinding\":true,\"tamperRejected\":true,\"removedHostPruned\":true,\"projection\":true}")
        } catch {
            print("Workspace recovery E2E failed: \(error)")
            exit(1)
        }
    }
}
