import Foundation
import Observation

struct AgentTaskTurn: Equatable {
    let agentID: String
    let threadID: String
    let turnID: String

    init?(_ value: WireValue) {
        guard let agent = value["agentId"]?.string, let thread = value["threadId"]?.string,
              let turn = value["turnId"]?.string else { return nil }
        agentID = agent; threadID = thread; turnID = turn
    }
}

/// A notice contains no provider error text, prompt, credential, or page address.
struct AgentTaskFailure: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case failed, problem, warning, providerSignIn, memory, unconfirmedStart
    }

    let agentID: String?
    let turnID: String?
    let kind: Kind
    let terminal: Bool
    var id: String { [agentID ?? "host", turnID ?? "", kind.rawValue].joined(separator: ":") }

    var title: LocalizedStringResource {
        switch kind {
        case .failed: "native.task.failedTitle"
        case .warning: "native.task.warningTitle"
        case .providerSignIn: "native.task.providerSignInTitle"
        case .memory: "native.task.memoryTitle"
        case .unconfirmedStart: "native.task.unconfirmedTitle"
        case .problem: "native.task.problemTitle"
        }
    }

    var message: LocalizedStringResource {
        switch kind {
        case .failed: "native.task.failedBody"
        case .warning: "native.task.warningBody"
        case .providerSignIn: "native.task.providerSignInBody"
        case .memory: "native.task.memoryBody"
        case .unconfirmedStart: "native.task.unconfirmedBody"
        case .problem: "native.task.problemBody"
        }
    }
}

struct HostProviderIssue: Identifiable, Equatable {
    enum Kind: Equatable { case signIn, unavailable }
    let id: String
    let name: String?
    let kind: Kind

    var message: LocalizedStringResource {
        switch kind {
        case .signIn: "native.task.providerSignInBody"
        case .unavailable: "native.task.providerUnavailableBody"
        }
    }
}

/// Host queue counts are distinct from the phone's durable send outbox.
struct AgentTaskQueue: Equatable {
    let queuedCount: Int
    let startingCount: Int
    var waitingCount: Int { queuedCount + startingCount }
    var message: LocalizedStringResource {
        queuedCount == 0 ? "native.task.startingBody" : "native.task.queueBody"
    }

    init?(_ value: WireValue) {
        guard case .array(let deliveries) = value["deliveries"] else { return nil }
        queuedCount = deliveries.filter { $0["status"]?.string == "queued" }.count
        startingCount = deliveries.filter { $0["status"]?.string == "starting" }.count
    }
}

struct AgentBrowserHandoff: Identifiable, Equatable {
    let wire: WireValue
    let agentID: String
    let threadID: String
    let turnID: String
    let requestID: WireValue
    let tabID: String
    let site: String?
    let method: String?
    let signInBlocked: Bool
    let id: String

    init?(_ value: WireValue) {
        guard let agent = value["agentId"]?.string, let thread = value["threadId"]?.string,
              let turn = value["turnId"]?.string, let request = value["requestId"],
              let tab = value["tabId"]?.string,
              let identifier = try? JSONEncoder().encode(request) else { return nil }
        wire = value
        agentID = agent; threadID = thread; turnID = turn; requestID = request; tabID = tab
        // The released secret metadata contains a public origin and a method, never an answer.
        // Show only the host name; do not turn the Mac's page into a phone navigation action.
        if let origin = value["secret"]?["origin"]?.string, let url = URL(string: origin), url.scheme == "https" {
            site = url.host
        } else { site = nil }
        method = value["secret"]?["method"]?.string
        signInBlocked = value["reason"]?.string == "sign-in-blocked"
        id = [agent, thread, turn, identifier.base64EncodedString()].joined(separator: ":")
    }

    var instruction: LocalizedStringResource {
        if signInBlocked { return "native.handoff.signInBlocked" }
        switch method {
        case "password": return "native.handoff.password"
        case "otp": return "native.handoff.code"
        case "authenticator": return "native.handoff.authenticator"
        default: return "native.handoff.browserStep"
        }
    }
}

/// Current host state only. Nothing here is persisted or automatically retried.
@Observable
@MainActor
final class AgentTasks {
    private(set) var activeTurns: [String: AgentTaskTurn] = [:]
    private(set) var failures: [String: AgentTaskFailure] = [:]
    private(set) var hostProblem: AgentTaskFailure?
    private(set) var providerIssues: [HostProviderIssue] = []
    private(set) var queues: [String: AgentTaskQueue] = [:]
    private(set) var browserHandoffs: [AgentBrowserHandoff] = []
    private(set) var cancelling: Set<String> = []
    private(set) var cancellationProblems: [String: LocalizedStringResource] = [:]
    private var hostID: String?
    private var generation = 0
    private var hostProblemRevision = 0

    func clear() {
        generation += 1
        hostProblemRevision = 0
        activeTurns = [:]; failures = [:]; hostProblem = nil; providerIssues = []
        queues = [:]; browserHandoffs = []; cancelling = []; cancellationProblems = [:]; hostID = nil
    }

    func retainAgents(_ ids: Set<String>) {
        activeTurns = activeTurns.filter { ids.contains($0.key) }
        failures = failures.filter { ids.contains($0.key) }
        queues = queues.filter { ids.contains($0.key) }
        browserHandoffs.removeAll { !ids.contains($0.agentID) }
        pruneCancellationProblems()
    }

    func refresh(connection: AgentConnection) async {
        guard let currentHost = connection.hostID, currentHost == hostID else { return }
        let epoch = generation
        let problemRevision = hostProblemRevision
        await connection.reconnect()
        guard epoch == generation, connection.hostID == currentHost, connection.phase == .online else { return }
        // The new runtime/provider snapshots keep any current, actionable failure.
        // A host-wide transient event has no released acknowledgement route.
        if problemRevision == hostProblemRevision { hostProblem = nil }
    }

    func receive(_ event: WireValue, hostID: String?) {
        guard let hostID else { clear(); return }
        if self.hostID != hostID { clear(); self.hostID = hostID }
        switch event["type"]?.string {
        case "runtime-snapshot":
            if let snapshot = event["snapshot"] { receiveSnapshot(snapshot) }
        case "turn-started":
            guard let turn = AgentTaskTurn(event) else { return }
            activeTurns[turn.agentID] = turn
            failures[turn.agentID] = nil
        case "turn-completed":
            guard let turn = AgentTaskTurn(event) else { return }
            if activeTurns[turn.agentID]?.turnID == turn.turnID { activeTurns[turn.agentID] = nil }
            if event["status"]?.string == "failed" {
                failures[turn.agentID] = AgentTaskFailure(agentID: turn.agentID, turnID: turn.turnID, kind: .failed, terminal: true)
            } else if failures[turn.agentID]?.turnID == turn.turnID { failures[turn.agentID] = nil }
            browserHandoffs.removeAll { $0.agentID == turn.agentID && $0.threadID == turn.threadID && $0.turnID == turn.turnID }
            pruneCancellationProblems()
        case "error":
            receiveError(event)
        case "status":
            if let status = event["status"] { receiveStatus(status) }
        case "queue-changed":
            guard let snapshot = event["snapshot"], let agent = snapshot["agentId"]?.string,
                  let queue = AgentTaskQueue(snapshot) else { return }
            queues[agent] = queue
        case "browser-takeover-requested":
            guard let value = event["request"], let handoff = AgentBrowserHandoff(value) else { return }
            browserHandoffs.removeAll { $0.agentID == handoff.agentID && $0.requestID == handoff.requestID }
            browserHandoffs.append(handoff)
            cancellationProblems[handoff.id] = nil
        case "browser-takeover-resolved":
            browserHandoffs.removeAll { $0.agentID == event["agentId"]?.string && $0.requestID == event["requestId"] }
            pruneCancellationProblems()
        default: break
        }
    }

    func cancel(_ handoff: AgentBrowserHandoff, connection: AgentConnection) async {
        guard let currentHost = connection.hostID, currentHost == hostID, connection.canSend,
              browserHandoffs.contains(handoff), cancelling.isEmpty else { return }
        let epoch = generation
        cancelling.insert(handoff.id)
        cancellationProblems[handoff.id] = nil
        defer { if epoch == generation { cancelling.remove(handoff.id) } }
        do {
            // The bridge reads a new host snapshot, compares the entire exact request,
            // and only then sends the released cancel response. It never sends complete.
            _ = try await connection.transport.execute([
                "type": .string("cancelBrowserTakeover"), "hostId": .string(currentHost),
                "browserTakeover": handoff.wire
            ])
            guard epoch == generation, connection.hostID == currentHost else { return }
            browserHandoffs.removeAll { $0 == handoff }
            pruneCancellationProblems()
        } catch {
            guard epoch == generation, connection.hostID == currentHost,
                  browserHandoffs.contains(handoff) else { return }
            cancellationProblems[handoff.id] = "native.handoff.cancelNotConfirmed"
        }
    }

    private func receiveSnapshot(_ snapshot: WireValue) {
        if case .array(let values) = snapshot["activeTurns"] {
            activeTurns = Dictionary(values.compactMap(AgentTaskTurn.init).map { ($0.agentID, $0) }, uniquingKeysWith: { _, latest in latest })
        }
        if case .array(let values) = snapshot["failedTurns"] {
            // Failed-turn markers are complete, independently of the bounded attention list.
            var next = failures.filter { entry in
                !entry.value.terminal && entry.value.turnID != nil && activeTurns[entry.key]?.turnID == entry.value.turnID
            }
            for value in values {
                guard let agent = value["agentId"]?.string, let turn = value["turnId"]?.string else { continue }
                next[agent] = AgentTaskFailure(agentID: agent, turnID: turn, kind: .failed, terminal: true)
            }
            failures = next
        }
        if case .array(let values) = snapshot["work"] {
            for value in values where value["status"]?.string == "failed" || value["error"]?.string?.isEmpty == false {
                guard let agent = value["agentId"]?.string else { continue }
                let terminal = value["status"]?.string == "failed"
                failures[agent] = AgentTaskFailure(agentID: agent, turnID: value["turnId"]?.string ?? failures[agent]?.turnID,
                                                  kind: terminal ? .failed : .problem, terminal: terminal)
            }
        }
        if case .array(let values) = snapshot["pendingBrowserTakeovers"] {
            let incoming = values.compactMap(AgentBrowserHandoff.init)
            if snapshot["attentionComplete"]?.bool == true { browserHandoffs = incoming }
            else {
                let identities = Set(incoming.map(\.id))
                browserHandoffs = browserHandoffs.filter { !identities.contains($0.id) } + incoming
            }
            pruneCancellationProblems()
        }
    }

    private func receiveError(_ event: WireValue) {
        guard let code = event["code"]?.string else { return }
        let kind: AgentTaskFailure.Kind
        switch code {
        case "agent_warning": kind = .warning
        case "host_memory_low": kind = .memory
        case "delivery_start_unconfirmed", "delivery_reconciliation_pending": kind = .unconfirmedStart
        default: kind = code.hasSuffix("_account_sign_in_failed") ? .providerSignIn : .problem
        }
        // The error message and link may contain a provider's quoted request. Do not
        // retain, render, export, or log either value on this surface.
        if let agent = event["agentId"]?.string {
            failures[agent] = AgentTaskFailure(agentID: agent, turnID: activeTurns[agent]?.turnID, kind: kind, terminal: false)
        } else {
            hostProblemRevision += 1
            hostProblem = AgentTaskFailure(agentID: nil, turnID: nil, kind: kind, terminal: false)
        }
    }

    private func receiveStatus(_ status: WireValue) {
        if case .array(let providers) = status["providers"] {
            providerIssues = providers.compactMap { value in
                guard value["state"]?.string == "sign-in-required", let id = value["id"]?.string else { return nil }
                return HostProviderIssue(id: id, name: value["displayName"]?.string ?? id, kind: .signIn)
            }
        } else { providerIssues = [] }
        if providerIssues.isEmpty && status["capabilities"]?["chat"]?.string != "ready" {
            if status["auth"]?["kind"]?.string == "signed-out" {
                providerIssues = [HostProviderIssue(id: "host-chat", name: nil, kind: .signIn)]
            } else if ["blocked", "stopped"].contains(status["phase"]?.string ?? "") ||
                        (status["phase"]?.string == "ready" && status["capabilities"]?["chat"]?.string == "setup-required") {
                providerIssues = [HostProviderIssue(id: "host-chat", name: nil, kind: .unavailable)]
            }
        }
    }

    private func pruneCancellationProblems() {
        let ids = Set(browserHandoffs.map(\.id))
        cancellationProblems = cancellationProblems.filter { ids.contains($0.key) }
    }
}
