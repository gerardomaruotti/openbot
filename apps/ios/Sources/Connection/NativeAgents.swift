import Foundation
import Observation

struct NativeManagedAgent: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let title: String
    let description: String
    let provider: WireValue
    let model: String
    let reasoningEffort: String
    let updatedAt: String?
    let avatarSeed: String
    let canManage: Bool
    let canDelete: Bool

    var providerID: String { provider.string ?? provider["id"]?.string ?? "" }
    var modelKey: String { providerID + "\n" + model }
}

struct NativeAgentContext: Equatable {
    let hostID: String
    let workspaceID: String
    let identity: UUID
}

struct NativeAgentDraft: Equatable {
    var name: String
    var title: String
    var instructions: String
    var firstMessage: String
    let avatarSeed: String

    init(agent: NativeManagedAgent? = nil) {
        name = agent?.name ?? ""
        title = agent?.title ?? ""
        instructions = agent?.description ?? ""
        firstMessage = ""
        avatarSeed = agent?.avatarSeed ?? "native:" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    func isValid(creating: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 80 &&
        title.utf16.count <= 120 && instructions.utf16.count <= 2_000 &&
        (!creating || (!firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && firstMessage.utf16.count <= 100_000))
    }
}

/// Management reads and writes stay on the currently authenticated host. Mutations are never queued.
@Observable
@MainActor
final class NativeAgents {
    func retainVisibleAgents(_ ids: Set<String>) {
        rosterRevision += 1
        agents.removeAll { !ids.contains($0.id) }
    }
    private struct Catalogue: Decodable {
        let agents: [NativeManagedAgent]
        let canCreate: Bool
        let canChooseModel: Bool
    }

    private(set) var agents: [NativeManagedAgent] = []
    private(set) var canCreate = false
    private(set) var isBusy = false
    private(set) var hasLoaded = false
    private(set) var unconfirmedCreateSeeds: Set<String> = []
    private(set) var problem: LocalizedStringResource?
    private(set) var modelProblem: LocalizedStringResource?
    private var context: NativeAgentContext?
    private var rosterRevision = 0

    var currentContext: NativeAgentContext? { context }
    func agent(_ id: String) -> NativeManagedAgent? { agents.first { $0.id == id } }

    func clear() {
        context = nil
        agents = []
        canCreate = false; isBusy = false; hasLoaded = false
        unconfirmedCreateSeeds = []; problem = nil; modelProblem = nil
    }

    func isCurrent(_ expected: NativeAgentContext?, connection: AgentConnection) -> Bool {
        guard let expected, context == expected, connection.isAuthenticated else { return false }
        return connection.hostID == expected.hostID && connection.workspaceID == expected.workspaceID
    }

    func canChange(_ expected: NativeAgentContext?, connection: AgentConnection) -> Bool {
        isCurrent(expected, connection: connection) && connection.canSend && connection.features.agents && !isBusy
    }

    @discardableResult
    func load(connection: AgentConnection) async -> Bool {
        guard let host = connection.hostID, let workspace = connection.workspaceID else { clear(); return false }
        if context?.hostID != host || context?.workspaceID != workspace {
            clear()
            context = NativeAgentContext(hostID: host, workspaceID: workspace, identity: UUID())
        }
        guard !isBusy, connection.canSend, connection.features.agents, let expected = context else {
            return false
        }
        isBusy = true; problem = nil; modelProblem = nil
        let revision = rosterRevision
        defer {
            if context == expected {
                isBusy = false
                if revision != rosterRevision, connection.canSend {
                    Task { _ = await load(connection: connection) }
                }
            }
        }
        do {
            let value = try await connection.transport.execute(["type": .string("agents"), "hostId": .string(host)])
            let catalogue = try value.decode(Catalogue.self)
            guard isCurrent(expected, connection: connection), revision == rosterRevision else { return false }
            agents = catalogue.agents
            canCreate = catalogue.canCreate && connection.features.agentCreate
            hasLoaded = true
            return true
        } catch {
            return false
        }
    }

    func create(_ draft: NativeAgentDraft, context expected: NativeAgentContext?, connection: AgentConnection) async -> NativeManagedAgent? {
        guard canChange(expected, connection: connection), canCreate, connection.features.agentCreate,
              !unconfirmedCreateSeeds.contains(draft.avatarSeed),
              draft.isValid(creating: true), let expected else { return nil }
        let input: [String: WireValue] = [
            "name": .string(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "description": .string(draft.instructions), "avatarSeed": .string(draft.avatarSeed),
            "avatarHue": .null, "initialMessage": .string(draft.firstMessage),
        ]
        isBusy = true; problem = nil
        defer { if context == expected { isBusy = false } }
        do {
            let value = try await connection.transport.execute([
                "type": .string("createAgent"), "hostId": .string(expected.hostID), "input": .object(input),
            ])
            let saved = try value.decode(NativeManagedAgent.self)
            guard isCurrent(expected, connection: connection) else { return nil }
            upsert(saved)
            return saved
        } catch {
            if isCurrent(expected, connection: connection) {
                // The released create route has no idempotency key. Never repeat an
                // unconfirmed create from this form, even after a list refresh.
                unconfirmedCreateSeeds.insert(draft.avatarSeed)
                problem = "native.error.generic"
            }
            return nil
        }
    }

    func update(_ agent: NativeManagedAgent, draft: NativeAgentDraft, context expected: NativeAgentContext?, connection: AgentConnection) async -> NativeManagedAgent? {
        guard canChange(expected, connection: connection), self.agent(agent.id)?.canManage == true,
              draft.isValid(creating: false), let expected else { return nil }
        var patch: [String: WireValue] = [:]
        if draft.name != agent.name { patch["name"] = .string(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if draft.title != agent.title { patch["title"] = .string(draft.title) }
        if draft.instructions != agent.description { patch["description"] = .string(draft.instructions) }
        guard !patch.isEmpty else { return agent }
        isBusy = true; problem = nil
        defer { if context == expected { isBusy = false } }
        do {
            let value = try await connection.transport.execute([
                "type": .string("updateAgent"), "hostId": .string(expected.hostID),
                "agentId": .string(agent.id), "patch": .object(patch),
                "expectedUpdatedAt": agent.updatedAt.map(WireValue.string) ?? .null,
            ])
            let saved = try value.decode(NativeManagedAgent.self)
            guard isCurrent(expected, connection: connection) else { return nil }
            upsert(saved)
            return saved
        } catch {
            if isCurrent(expected, connection: connection) { problem = "native.error.generic" }
            return nil
        }
    }

    func remove(_ agent: NativeManagedAgent, context expected: NativeAgentContext?, connection: AgentConnection) async -> Bool {
        guard canChange(expected, connection: connection), self.agent(agent.id)?.canDelete == true, connection.features.agentDelete,
              let expected else { return false }
        isBusy = true; problem = nil
        defer { if context == expected { isBusy = false } }
        do {
            _ = try await connection.transport.execute([
                "type": .string("deleteAgent"), "hostId": .string(expected.hostID),
                "agentId": .string(agent.id), "expectedUpdatedAt": agent.updatedAt.map(WireValue.string) ?? .null,
            ])
            guard isCurrent(expected, connection: connection) else { return false }
            agents.removeAll { $0.id == agent.id }
            return true
        } catch {
            if isCurrent(expected, connection: connection) { problem = "native.error.generic" }
            return false
        }
    }

    private func upsert(_ agent: NativeManagedAgent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent }
        else { agents.append(agent) }
    }
}
