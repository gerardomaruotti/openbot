import Foundation
import Observation

@Observable
@MainActor
final class AgentConnection {
    let transport = HostTransport()
    private(set) var phase: ConnectionPhase = .preview
    private(set) var hosts: [ConnectedHost] = []
    private(set) var hostName = ""
    private(set) var isBusy = false
    private(set) var deduplicatesMessages = false
    private(set) var supportsPush = false
    private(set) var supportsAttachments = false
    private(set) var features = NativeHostFeatures()
    private(set) var capabilities: Set<String> = []
    private(set) var role = "member"
    private(set) var signOutNotice: LocalizedStringResource?
    var problem: ConnectionProblem?
    var agentsChanged: (([HostAgent]) -> Void)?
    var teamEvent: ((WireValue) -> Void)?
    var cleared: (() -> Void)?
    var workspaceChanged: (() -> Void)?
    var hostRemoved: (() -> Void)?
    var workspacesRetained: ((Set<String>) -> Void)?
    var ready: ((Bool) -> Void)?

    private var credential: HostCredential?
    private var restored = false
    private var installed = false
    private var active = true
    private var generation = 0
    private var retry: Task<Void, Never>?

    var isAuthenticated: Bool { credential != nil }
    var canSend: Bool { phase == .online && active && !isBusy }
    var email: String { credential?.email ?? "" }
    var hostID: String? { credential?.selectedHostID }
    var workspaceID: String? { credential?.workspaceID }

    var accountURL: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenBotAccountURL") as? String ?? "https://api.openbot.run"
    }

    init() {
        transport.receive = { [weak self] event in self?.receive(event) }
        transport.pin = { [weak self] id, key in
            guard let self, var value = self.credential else { throw ConnectionProblem.auth }
            value.hostKeys[id] = key
            try HostSessionStore.save(value)
            self.credential = value
        }
        _ = restoreCredential()
    }

    func restore() async {
        guard restoreCredential(), credential != nil, !installed else { return }
        await reconnect()
    }

    private func restoreCredential() -> Bool {
        if restored { return true }
        do {
            credential = try HostSessionStore.load()
            restored = true
            return true
        } catch { problem = .keychain; return false }
    }

    func startEmail(_ email: String) async -> (String, String?)? {
        guard restoreCredential(), !isBusy, credential == nil else { return nil }
        isBusy = true
        problem = nil
        signOutNotice = nil
        phase = .signingIn
        defer { isBusy = false; if credential == nil { phase = .preview } }
        do {
            try transport.useAccount(accountURL)
            let reply = try await transport.execute(["type": .string("emailStart"), "apiUrl": .string(accountURL), "email": .string(email), "requestId": .string(UUID().uuidString)])
            guard let challenge = reply["challengeId"]?.string else { throw ConnectionProblem.protocolError }
            #if DEBUG
            let code = URL(string: accountURL)?.scheme == "http" ? reply["developmentCode"]?.string : nil
            #else
            let code: String? = nil
            #endif
            return (challenge, code)
        } catch { problem = issue(error); return nil }
    }

    func verifyEmail(challenge: String, code: String) async {
        guard restoreCredential(), !isBusy, credential == nil else { return }
        isBusy = true
        problem = nil
        phase = .signingIn
        defer { isBusy = false; notifyReady() }
        do {
            let reply = try await transport.execute(["type": .string("emailVerify"), "apiUrl": .string(accountURL), "challengeId": .string(challenge), "code": .string(code), "deviceId": .string(deviceID)])
            try await accept(reply)
        } catch {
            if credential == nil { problem = issue(error); phase = .preview }
            else { connectionFailed(error) }
        }
    }

    func pair(_ link: String) async {
        guard restoreCredential(), !isBusy else { return }
        signOutNotice = nil
        guard credential == nil else { await reconnect(); return }
        isBusy = true
        problem = nil
        phase = .signingIn
        defer { isBusy = false; notifyReady() }
        do {
            guard var parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["openbot", Bundle.main.object(forInfoDictionaryKey: "OpenBotURLScheme") as? String ?? "openbot-native"].contains(parts.scheme), parts.host == "mobile-connect",
                  let api = parts.queryItems?.first(where: { $0.name == "api" })?.value else { throw ConnectionProblem.invalidLink }
            parts.scheme = "openbot"
            guard let normalized = parts.url?.absoluteString else { throw ConnectionProblem.invalidLink }
            try transport.useAccount(api)
            let reply = try await transport.execute(["type": .string("pair"), "link": .string(normalized), "deviceId": .string(deviceID)])
            try await accept(reply)
        } catch {
            if credential == nil { problem = issue(error); phase = .preview }
            else { connectionFailed(error) }
        }
    }

    private func accept(_ reply: WireValue) async throws {
        let value = try reply.decode(HostCredential.self)
        try HostSessionStore.save(value)
        generation += 1
        credential = value
        installed = true
        cleared?()
        try await discoverAndConnect()
    }

    func reconnect(hostID: String? = nil) async {
        guard !isBusy, active, credential != nil else { return }
        retry?.cancel()
        retry = nil
        isBusy = true
        phase = .connecting
        problem = nil
        let currentGeneration = generation
        defer { isBusy = false; notifyReady() }
        do {
            if !installed, let credential {
                try transport.useAccount(credential.apiUrl)
                let value = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(credential))
                _ = try await transport.execute(["type": .string("restore"), "session": value])
                installed = true
            }
            guard generation == currentGeneration else { return }
            try await discoverAndConnect(preferredHostID: hostID)
        } catch {
            guard generation == currentGeneration else { return }
            connectionFailed(error)
        }
    }

    /// A tapped alert must wait for an existing restore or foreground transition.
    func reconnectForNotification(hostID: String) async {
        let availability = Observations { (self.isBusy, self.active, self.isAuthenticated) }
        for await (busy, active, authenticated) in availability {
            guard !Task.isCancelled, authenticated else { return }
            if !busy && active { break }
        }
        guard !Task.isCancelled else { return }
        await reconnect(hostID: hostID)
    }

    private func connectionFailed(_ error: Error) {
        if issue(error) == .auth { report(error); return }
        phase = .offline
        if problem != .protocolError { problem = issue(error) }
        scheduleRetry()
    }

    private func discoverAndConnect(preferredHostID: String? = nil) async throws {
        guard let credential else { throw ConnectionProblem.auth }
        let epoch = generation
        let result = try await transport.execute(["type": .string("hosts")])
        guard epoch == generation else { throw CancellationError() }
        hosts = try result.decode([ConnectedHost].self)
        workspacesRetained?(Set(hosts.map { credential.workspaceID(hostID: $0.hostId, membershipID: $0.membershipId) }))
        let preferred = preferredHostID ?? credential.selectedHostID ?? credential.host?.hostId
        let host = preferred.flatMap { id in hosts.first { $0.hostId == id } } ?? (preferred == nil && hosts.count == 1 ? hosts.first : nil)
        guard let host else {
            phase = .offline
            if hosts.isEmpty || preferred != nil {
                problem = .hostMissing
                if preferred == credential.selectedHostID { hostRemoved?() }
            }
            return
        }
        var selected = self.credential ?? credential
        selected.selectedHostID = host.hostId
        selected.membershipId = host.membershipId
        try HostSessionStore.save(selected)
        self.credential = selected
        workspaceChanged?()
        phase = .connecting
        let connected = try await transport.execute(["type": .string("connect"), "hostId": .string(host.hostId)])
        guard epoch == generation else { throw CancellationError() }
        guard let agents = connected["agents"] else { throw ConnectionProblem.protocolError }
        let decoded = try agents.decode([HostAgent].self)
        var saved = self.credential ?? credential
        saved.selectedHostID = host.hostId
        try HostSessionStore.save(saved)
        self.credential = saved
        hostName = host.name
        deduplicatesMessages = connected["deduplicatesMessages"]?.bool ?? false
        supportsPush = connected["supportsPush"]?.bool ?? false
        supportsAttachments = connected["supportsAttachments"]?.bool ?? false
        features = NativeHostFeatures(connected["features"])
        capabilities = Set((try? connected["capabilities"]?.decode([String].self)) ?? [])
        role = connected["role"]?.string ?? "member"
        keptConnection = connected["kept"]?.bool ?? false
        agentsChanged?(decoded)
        phase = .online
        if problem != .storage { problem = nil }
    }

    private var keptConnection = false
    private func notifyReady() {
        if phase == .online && active { ready?(keptConnection) }
    }

    func history(_ agentID: String, before: String? = nil) async throws -> HostPage {
        var command: [String: WireValue] = ["type": .string("history"), "agentId": .string(agentID)]
        if let before { command["before"] = .string(before) }
        let result = try await transport.execute(command)
        return try result.decode(HostPage.self)
    }

    func report(_ error: Error) {
        let value = issue(error)
        if value == .auth {
            try? HostSessionStore.clear()
            clear()
        }
        problem = value
    }

    func send(_ text: String, to agentID: String, clientID: String, attachmentIDs: [String] = [], replyToMessageID: String? = nil) async throws -> String {
        guard canSend else { throw ConnectionProblem.network }
        let reply: WireValue
        do {
            reply = try await transport.execute(["type": .string("send"), "agentId": .string(agentID), "text": .string(text), "clientMessageId": .string(clientID), "timezone": .string(TimeZone.current.identifier), "attachmentDraftIds": .array(attachmentIDs.map(WireValue.string)), "replyToMessageId": replyToMessageID.map(WireValue.string) ?? .null])
        } catch ConnectionProblem.auth {
            throw ConnectionProblem.auth
        } catch ConnectionProblem.sendFailed {
            throw ConnectionProblem.sendFailed
        } catch {
            // A lost bridge reply cannot tell us whether the host accepted the message.
            throw ConnectionProblem.unconfirmed
        }
        guard let id = reply["conversationMessageId"]?.string else { throw ConnectionProblem.unconfirmed }
        return id
    }

    func notificationScope(for hostID: String) -> String? {
        guard let credential, let host = hosts.first(where: { $0.hostId == hostID }) else { return nil }
        return credential.workspaceID(hostID: hostID, membershipID: host.membershipId)
    }

    func registerPush(scope: String, token: String, secret: String, environment: String, away: Bool) async throws {
        guard let hostID, canSend else { throw ConnectionProblem.network }
        _ = try await transport.execute(["type": .string("pushRegister"), "hostId": .string(hostID), "registration": .object([
            "serverId": .string(scope), "token": .string(token), "secret": .string(secret),
            "environment": .string(environment), "locale": .string(Locale.current.language.languageCode?.identifier ?? "en"),
            "away": .bool(away), "level": .string("all"), "mutedUntil": .null,
            "preview": .bool(true), "sound": .string("default"), "liveActivityStartedAt": .null
        ])])
    }

    func removePushRegistration() async throws {
        guard let hostID, canSend else { throw ConnectionProblem.network }
        _ = try await transport.execute(["type": .string("pushRemove"), "hostId": .string(hostID)])
    }

    func setActive(_ value: Bool) async {
        guard active != value else { return }
        active = value
        // Cached chats remain usable, but sends wait for fresh membership verification.
        if value, credential != nil { phase = .connecting }
        retry?.cancel()
        retry = nil
        if installed { _ = try? await transport.execute(["type": .string("active"), "value": .bool(value)]) }
        if value, credential != nil { await reconnect() }
    }

    func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        problem = nil
        signOutNotice = nil
        let signedIn = credential
        do {
            try HostSessionStore.clear()
        } catch {
            problem = .keychain
            return
        }
        // Local access and saved data end even when the account service is offline.
        // The old credential is kept only in this bounded request, never saved for retry.
        clear()
        if let signedIn, !(await revokeSession(signedIn)) {
            signOutNotice = "native.connection.signedOutLocally"
        }
    }

    private func revokeSession(_ credential: HostCredential) async -> Bool {
        guard let base = URL(string: credential.apiUrl),
              let endpoint = URL(string: "/v1/mobile-auth/session", relativeTo: base)?.absoluteURL,
              let client = try? AccountHTTPClient(apiURL: base) else { return false }
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            client.close()
        }
        defer { deadline.cancel(); client.close() }
        do {
            let (_, response) = try await client.perform(
                url: endpoint, method: "DELETE",
                headers: ["Authorization": "Bearer \(credential.sessionToken)"], body: nil)
            return (200..<300).contains(response.statusCode) || response.statusCode == 401
        } catch { return false }
    }

    private func clear() {
        generation += 1
        retry?.cancel()
        retry = nil
        transport.reset()
        credential = nil
        installed = false
        hosts = []
        deduplicatesMessages = false
        supportsPush = false
        supportsAttachments = false
        features = NativeHostFeatures()
        capabilities = []
        role = "member"
        hostName = ""
        phase = .preview
        cleared?()
    }

    private func receive(_ value: WireValue) {
        switch value["type"]?.string {
        case "expired":
            try? HostSessionStore.clear()
            clear()
            problem = .auth
        case "reset":
            installed = false
            if credential != nil { phase = .offline; scheduleRetry() }
        case "team":
            if value["hostId"]?.string == hostID, let event = value["event"] { teamEvent?(event) }
        case "connection":
            guard value["hostId"]?.string == hostID else { return }
            if value["code"]?.string == "protocol_error" {
                retry?.cancel()
                retry = nil
                phase = .offline
                problem = .protocolError
            } else if value["code"]?.string == "session_revoked" {
                installed = false
                phase = .offline
                scheduleRetry()
            } else if value["state"]?.string == "offline", credential != nil {
                phase = .offline
                scheduleRetry()
            } else if value["state"]?.string == "connecting" {
                phase = .connecting
            } else if value["resync"]?.bool == true, active {
                phase = .connecting
                Task { [weak self] in await self?.reconnect() }
            } else if value["state"]?.string == "online", phase != .online, !isBusy, active {
                Task { [weak self] in await self?.reconnect() }
            }
        default: break
        }
    }

    private func scheduleRetry() {
        guard retry == nil, active, credential != nil, problem != .protocolError else { return }
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.retry = nil
            await self?.reconnect()
        }
    }

    private func issue(_ error: Error) -> ConnectionProblem { error as? ConnectionProblem ?? .network }

    private var deviceID: String {
        let key = "native.connection.device-id"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
