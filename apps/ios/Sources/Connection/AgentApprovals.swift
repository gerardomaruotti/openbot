import Foundation
import Observation
import OSLog

struct AgentApproval: Identifiable, Equatable {
    struct Permissions: Decodable, Equatable {
        struct FileSystem: Decodable, Equatable { let read: [String]; let write: [String] }
        let fileSystem: FileSystem
        let network: Bool
    }

    let wire: WireValue
    let agentID: String
    let threadID: String
    let turnID: String
    let requestID: WireValue
    let kind: String
    let command: String?
    let cwd: String?
    let reason: String?
    let grantRoot: String?
    let permissions: Permissions?
    let truncated: Bool
    let id: String

    init?(_ value: WireValue) {
        guard let agent = value["agentId"]?.string, let thread = value["threadId"]?.string,
              let turn = value["turnId"]?.string, let request = value["requestId"],
              let kind = value["kind"]?.string, ["command", "file-change", "permissions"].contains(kind),
              let identifier = try? JSONEncoder().encode(request) else { return nil }
        wire = value
        agentID = agent; threadID = thread; turnID = turn; requestID = request
        self.kind = kind
        command = value["command"]?.string; cwd = value["cwd"]?.string
        reason = value["reason"]?.string; grantRoot = value["grantRoot"]?.string
        permissions = try? value["permissions"]?.decode(Permissions.self)
        truncated = value["truncated"]?.bool ?? false
        id = [agent, thread, turn, identifier.base64EncodedString()].joined(separator: ":")
    }
}

@Observable
@MainActor
final class AgentApprovals {
    private(set) var pending: [AgentApproval] = []
    private(set) var responding: Set<String> = []
    private(set) var problem: LocalizedStringResource?
    private var hostID: String?
    private var generation = 0

    func clear() {
        generation += 1
        pending = []; responding = []; problem = nil; hostID = nil
    }

    func receive(_ event: WireValue, hostID: String?) {
        if self.hostID != hostID { clear(); self.hostID = hostID }
        switch event["type"]?.string {
        case "runtime-snapshot":
            guard case .array(let values) = event["snapshot"]?["pendingApprovals"] else { return }
            let incoming = values.compactMap(AgentApproval.init)
            if event["snapshot"]?["attentionComplete"]?.bool == true { pending = incoming }
            else {
                let identities = Set(incoming.map(\.id))
                pending = pending.filter { !identities.contains($0.id) } + incoming
            }
        case "approval":
            guard let value = event["approval"], let approval = AgentApproval(value) else { return }
            pending.removeAll { $0.requestID == approval.requestID }
            pending.append(approval)
        case "agent-input-resolved":
            if event["kind"]?.string == "approval" { pending.removeAll { $0.requestID == event["requestId"] } }
        case "turn-completed":
            pending.removeAll { $0.agentID == event["agentId"]?.string && $0.turnID == event["turnId"]?.string }
        default: break
        }
    }

    @discardableResult
    func respond(_ approval: AgentApproval, allow: Bool, connection: AgentConnection) async -> Bool {
        guard let currentHost = connection.hostID, connection.canSend, pending.contains(approval), responding.isEmpty,
              !(allow && approval.truncated) else { return false }
        let epoch = generation
        responding.insert(approval.id)
        problem = nil
        defer { if epoch == generation { responding.remove(approval.id) } }
        do {
            _ = try await connection.transport.execute([
                "type": .string("respondApproval"), "approval": approval.wire, "hostId": .string(currentHost),
                "decision": .string(allow ? "accept" : "decline")
            ])
            return epoch == generation
        } catch {
            let code = (error as? ConnectionProblem)?.rawValue ?? "bridge-\((error as NSError).code)"
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenBot", category: "NativeApprovals")
                .error("Approval response failed: \(code, privacy: .public)")
            if epoch == generation { problem = "native.approval.notConfirmed" }
            return false
        }
    }
}
