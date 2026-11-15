import Foundation
import Observation

struct NativeNotificationPreferences: Decodable, Sendable {
    struct AgentLevel: Decodable, Sendable { let agentId: String; let level: String }
    let server: String?
    let agents: [AgentLevel]
    var levels: [String: String] { Dictionary(agents.map { ($0.agentId, $0.level) }, uniquingKeysWith: { _, new in new }) }
}

@Observable
@MainActor
final class NativeChatControls {
    private(set) var changingReactions: Set<String> = []
    private(set) var changingNotifications: Set<String> = []
    private(set) var problemRevision = 0
    private(set) var problem: LocalizedStringResource? {
        didSet { if problem != nil { problemRevision += 1 } }
    }
    private(set) var problemAgentID: String?
    private var generation = 0

    func clear() {
        generation += 1
        changingReactions = []; changingNotifications = []; problem = nil; problemAgentID = nil
    }

    func preferences(connection: AgentConnection) async -> NativeNotificationPreferences? {
        guard connection.canSend, connection.features.notificationPreferences, let host = connection.hostID else { return nil }
        let scope = connection.workspaceID
        let epoch = generation
        do {
            let value = try await connection.transport.execute(["type": .string("notificationPreferences"), "hostId": .string(host)])
            guard epoch == generation, scope == connection.workspaceID else { return nil }
            return try value.decode(NativeNotificationPreferences.self)
        } catch { return nil }
    }

    func setLevel(_ level: String?, agentID: String, connection: AgentConnection) async -> NativeNotificationPreferences? {
        guard connection.canSend, connection.features.notificationPreferences,
              !changingNotifications.contains(agentID), let host = connection.hostID else { return nil }
        let scope = connection.workspaceID
        let epoch = generation
        changingNotifications.insert(agentID); problem = nil; problemAgentID = nil
        defer { if epoch == generation, scope == connection.workspaceID { changingNotifications.remove(agentID) } }
        do {
            let value = try await connection.transport.execute(["type": .string("setAgentNotificationLevel"), "hostId": .string(host), "agentId": .string(agentID), "level": level.map(WireValue.string) ?? .null])
            guard epoch == generation, scope == connection.workspaceID else { return nil }
            return try value.decode(NativeNotificationPreferences.self)
        } catch {
            if epoch == generation, scope == connection.workspaceID { problem = "native.error.generic"; problemAgentID = agentID }
            return nil
        }
    }

    func react(_ emoji: String?, agentID: String, messageID: String, connection: AgentConnection) async -> Bool {
        guard connection.canSend, connection.features.reactions, !changingReactions.contains(messageID), let host = connection.hostID else { return false }
        let scope = connection.workspaceID
        let epoch = generation
        changingReactions.insert(messageID); problem = nil; problemAgentID = nil
        defer { if epoch == generation, scope == connection.workspaceID { changingReactions.remove(messageID) } }
        do {
            _ = try await connection.transport.execute(["type": .string("setReaction"), "hostId": .string(host), "agentId": .string(agentID), "messageId": .string(messageID), "emoji": emoji.map(WireValue.string) ?? .null])
            return epoch == generation && scope == connection.workspaceID
        } catch {
            if epoch == generation, scope == connection.workspaceID { problem = "native.error.generic"; problemAgentID = agentID }
            return false
        }
    }
}
