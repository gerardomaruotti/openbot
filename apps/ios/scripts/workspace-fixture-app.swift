import CryptoKit
import SwiftUI

/// Simulator-only installer fixture. Never linked into the native product target.
@main
struct WorkspaceFixtureApp: App {
    let result: String
    @State private var cleanupResult: String?
    init() {
        #if targetEnvironment(simulator)
        do {
            let fixtureEmail = "native-recovery@example.invalid"
            if CommandLine.arguments.contains("--clear-fixture") {
                guard let saved = try HostSessionStore.load(), saved.email == fixtureEmail,
                      saved.apiUrl == "http://127.0.0.1:9", let scope = saved.workspaceID else {
                    result = "No fixture account to clear. Existing data preserved."
                    return
                }
                let disk = try LiveWorkspaceDisk(directory: LiveWorkspaceDisk.applicationDirectory, key: HostSessionStore.workspaceKey())
                try disk.remove(scope: scope)
                try HostSessionStore.clear()
                result = "Fixture cleared."
                return
            }
            guard try HostSessionStore.load() == nil else {
                result = "Existing account preserved. Fixture not installed."
                return
            }
            let directory = LiveWorkspaceDisk.applicationDirectory
            if FileManager.default.fileExists(atPath: directory.path),
               !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty {
                result = "Existing workspace preserved. Fixture not installed."
                return
            }
            let credential = HostCredential(apiUrl: "http://127.0.0.1:9", sessionToken: "synthetic-local-fixture-token-not-valid-remotely", userName: "Synthetic", email: fixtureEmail, host: nil, hostKeys: [:], selectedHostID: "fixture-host", membershipId: "fixture-member")
            guard let scope = credential.workspaceID else { throw ConnectionProblem.protocolError }
            var state = LiveWorkspaceState(scope: scope)
            let agentID = "fixture-agent"
            state.agents = [HostAgent(id: agentID, name: "Recovery Test", title: nil)]
            state.pages[agentID] = HostPage(agentId: agentID, threadId: "fixture-thread", activeTurnId: nil, revision: 8, messages: [
                HostMessage(id: "fixture-user", author: "user", text: "SYNTHETIC: Reply once.", createdAt: "2026-11-13T10:00:00Z", status: "completed", itemType: nil),
                HostMessage(id: "fixture-commentary", author: "assistant", text: "Following exact format", createdAt: "2026-11-13T10:00:01Z", status: "completed", itemType: "commentary"),
                HostMessage(id: "fixture-empty", author: "assistant", text: "", createdAt: "2026-11-13T10:00:01Z", status: "streaming", itemType: "agentMessage"),
                HostMessage(id: "fixture-answer", author: "assistant", text: "SYNTHETIC received.", createdAt: "2026-11-13T10:00:02Z", status: "completed", itemType: "final_answer")
            ])
            state.outbox = [OutboxMessage(clientID: "fixture-queued-one", agentID: agentID, text: "SYNTHETIC: queued before restart.", createdAt: .now)]
            state.lastOpenedID = agentID
            let disk = try LiveWorkspaceDisk(directory: directory, key: HostSessionStore.workspaceKey())
            try disk.save(state)
            try HostSessionStore.save(credential)
            // Drive the same production callback as a successful host connection. This must not
            // overlap a read and modification of the @Observable workspace storage.
            let model = ConversationStore()
            model.connection.agentsChanged?(state.agents)
            model.connection.agentsChanged?(state.agents)
            guard model.queuedCount == 1, model.conversation(agentID)?.messages.count == 3 else { throw ConnectionProblem.protocolError }
            result = "Fixture ready; agent refresh passed."
        } catch { result = "Fixture failed. Existing data preserved." }
        #else
        result = "This fixture cannot run on a physical device."
        #endif
    }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text(cleanupResult ?? result)
                Button("Clear Fixture") {
                    do {
                        guard let saved = try HostSessionStore.load(), saved.email == "native-recovery@example.invalid",
                              saved.apiUrl == "http://127.0.0.1:9", let scope = saved.workspaceID else { cleanupResult = "Existing data preserved."; return }
                        let disk = try LiveWorkspaceDisk(directory: LiveWorkspaceDisk.applicationDirectory, key: HostSessionStore.workspaceKey())
                        try disk.remove(scope: scope)
                        try HostSessionStore.clear()
                        cleanupResult = "Fixture cleared."
                    } catch { cleanupResult = "Fixture cleanup failed." }
                }
            }.padding()
        }
    }
}
