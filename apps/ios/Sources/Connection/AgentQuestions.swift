import Foundation
import CryptoKit
import Observation
import OSLog

struct AgentQuestionPrompt: Identifiable, Equatable {
    struct Question: Decodable, Identifiable, Equatable {
        struct Option: Decodable, Equatable { let label: String; let description: String }
        let id: String
        let header: String
        let question: String
        let isSecret: Bool
        let options: [Option]?
        let multiSelect: Bool?
    }

    let wire: WireValue
    let agentID: String
    let threadID: String
    let turnID: String
    let requestID: WireValue
    let questions: [Question]
    let confirmation: AgentConfirmation?
    let contextID: String
    let id: String

    init?(_ value: WireValue) {
        guard value["contextVerified"]?.bool == true,
              let agent = value["agentId"]?.string, let thread = value["threadId"]?.string,
              let turn = value["turnId"]?.string, let request = value["requestId"],
              let questions = try? value["questions"]?.decode([Question].self), !questions.isEmpty,
              let identifier = try? JSONEncoder().encode(request) else { return nil }
        wire = value; agentID = agent; threadID = thread; turnID = turn; requestID = request
        self.questions = questions
        if let block = value["uiBlock"] {
            guard block["spec"]?["type"]?.string == "confirm",
                  let confirmation = AgentConfirmation(block) else { return nil }
            self.confirmation = confirmation
        } else { confirmation = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let context = try? encoder.encode(WireValue.array([value["questions"] ?? .null, value["uiBlock"] ?? .null])) else { return nil }
        contextID = SHA256.hash(data: context).map { String(format: "%02x", $0) }.joined()
        id = [agent, thread, turn, identifier.base64EncodedString()].joined(separator: ":")
    }
}

struct AgentConfirmation: Equatable {
    struct Action: Decodable, Identifiable, Equatable {
        let id: String
        let label: String
        let style: String?
        let confirm: Bool?
    }

    struct Field: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String?
        let select: String?
        let options: [String]
    }

    private struct Spec: Decodable {
        struct Field: Decodable {
            let label: String
            let value: String?
            let select: String?
            let options: [String]?
        }
        let type: String
        let title: String
        let danger: Bool?
        let confirmHold: Int?
        let fields: [Field]?
        let preview: String?
        let actions: [Action]
    }

    let title: String
    let danger: Bool
    let holdSeconds: Double
    let holdsPrimary: Bool
    let fields: [Field]
    let preview: String?
    let actions: [Action]
    let continuesAutomatically: Bool

    init?(_ value: WireValue) {
        guard value["version"]?.integer == 1, value["state"]?["status"]?.string == "pending",
              let spec = try? value["spec"]?.decode(Spec.self), spec.type == "confirm",
              !spec.actions.isEmpty else { return nil }
        title = spec.title; danger = spec.danger == true
        holdSeconds = Double(spec.confirmHold ?? 800) / 1_000
        holdsPrimary = danger || spec.confirmHold != nil
        preview = spec.preview; actions = spec.actions
        continuesAutomatically = value["state"]?["autoAnswer"] != nil
        // Value fields have no host IDs. Their positions belong to this immutable card context;
        // QuestionCard changes its identity if any field or action changes.
        fields = (spec.fields ?? []).enumerated().map { index, field in
            Field(id: field.select ?? "value-\(index)", label: field.label, value: field.value,
                  select: field.select, options: field.options ?? [])
        }
    }

    func requiresHold(_ action: Action) -> Bool {
        action.confirm == true || action.style == "danger" || (holdsPrimary && action.style == "primary")
    }
}

/// Pending input is recovered from the host. Answers and secrets are never cached or retried.
@Observable
@MainActor
final class AgentQuestions {
    private(set) var pending: [AgentQuestionPrompt] = []
    private(set) var responding = false
    private(set) var problem: LocalizedStringResource?
    private(set) var unavailableAgents: Set<String> = []
    private var hostID: String?
    private var generation = 0

    func clear() {
        generation += 1
        pending = []; responding = false; problem = nil; hostID = nil; unavailableAgents = []
    }

    func receive(_ event: WireValue, hostID: String?) {
        if self.hostID != hostID { clear(); self.hostID = hostID }
        switch event["type"]?.string {
        case "prompt-context-pending":
            pending.removeAll { $0.agentID == event["agentId"]?.string && $0.threadID == event["threadId"]?.string && $0.turnID == event["turnId"]?.string && $0.requestID == event["requestId"] }
            if let agent = event["agentId"]?.string { unavailableAgents.insert(agent) }
        case "runtime-snapshot":
            guard case .array(let values) = event["snapshot"]?["pendingPrompts"] else { return }
            // Runtime summaries shorten question text without a truncation flag. Only
            // full prompts hydrated by the transport may be answered on this device.
            if event["snapshot"]?["attentionComplete"]?.bool == true {
                pending = pending.filter { prompt in
                    values.contains { $0["agentId"]?.string == prompt.agentID && $0["threadId"]?.string == prompt.threadID && $0["turnId"]?.string == prompt.turnID && $0["requestId"] == prompt.requestID }
                }
                unavailableAgents = Set(values.compactMap { $0["agentId"]?.string })
            } else {
                unavailableAgents.formUnion(values.compactMap { $0["agentId"]?.string })
            }
            unavailableAgents.subtract(pending.map(\.agentID))
        case "prompt":
            guard let prompt = AgentQuestionPrompt(event) else { return }
            pending.removeAll { $0.id == prompt.id }
            pending.append(prompt)
            unavailableAgents.remove(prompt.agentID)
        case "agent-input-resolved":
            if event["kind"]?.string == "prompt" {
                pending.removeAll { $0.agentID == event["agentId"]?.string && $0.requestID == event["requestId"] }
                if let agent = event["agentId"]?.string { unavailableAgents.remove(agent) }
            }
        case "turn-completed":
            pending.removeAll { $0.agentID == event["agentId"]?.string && $0.turnID == event["turnId"]?.string }
            if let agent = event["agentId"]?.string { unavailableAgents.remove(agent) }
        default: break
        }
    }

    func respond(_ prompt: AgentQuestionPrompt, answers: [String: [String]], connection: AgentConnection) async -> Bool {
        guard !responding else { return false }
        let current = pending.contains(prompt)
        guard let hostID = connection.hostID, connection.canSend, current else {
            problem = "native.question.notConfirmed"
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenBot", category: "NativeQuestions")
                .error("Question response could not start; connected \(connection.canSend, privacy: .public), current \(current, privacy: .public)")
            return false
        }
        let epoch = generation
        responding = true; problem = nil
        defer { if epoch == generation { responding = false } }
        do {
            _ = try await connection.transport.execute([
                "type": .string("respondPrompt"), "hostId": .string(hostID), "prompt": prompt.wire,
                "answers": .object(answers.mapValues { .array($0.map(WireValue.string)) })
            ])
            return true
        } catch {
            let code = (error as? ConnectionProblem)?.rawValue ?? "bridge-\((error as NSError).code)"
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "OpenBot", category: "NativeQuestions")
                .error("Question response failed: \(code, privacy: .public)")
            if epoch == generation { problem = "native.question.notConfirmed" }
            return false
        }
    }
}
