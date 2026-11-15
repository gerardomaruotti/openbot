import XCTest

/// A real host refusal must become a definite local failure while another agent's
/// durable send and cache survive. Actual membership loss must still remove the cache.
@MainActor
final class NativePermissionRecoveryJourney: NativeFixtureCase {
    func testAgentRefusalKeepsQueueAndMembershipRevocationPurgesCache() async throws {
        continueAfterFailure = false
        let setup = try JSONDecoder().decode(Setup.self, from: await control("permissions/setup", post: true))
        let deniedPath = "/v1/agents/\(setup.deniedAgentID)/messages"
        let allowedPath = "/v1/agents/\(setup.allowedAgentID)/messages"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openConnection()
        let email = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Email")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 15)); email.tap(); email.typeText(setup.email)
        app.buttons["Continue"].tap()
        let connect = app.buttons["Connect to Mac"]
        XCTAssertTrue(connect.wait(for: \.isHittable, toEqual: true, timeout: 15)); connect.tap()
        openChat("Simulator Agent")
        send("SIM-ACCESS-1")
        XCTAssertTrue(textElements("SIM-ACCESS-1 received").firstMatch.waitForExistence(timeout: 30))

        _ = try await control("offline", post: true)
        send("SIM-ACCESS-2")
        XCTAssertTrue(app.staticTexts["Waiting to send"].firstMatch.waitForExistence(timeout: 15))
        backToList(); openChat("Permission Queue Agent"); send("SIM-ACCESS-3")
        XCTAssertTrue(app.staticTexts["Waiting to send"].firstMatch.waitForExistence(timeout: 15))
        let before = try await status()
        XCTAssertGreaterThan(before.sealedFileCount, 0, "The queued state was not written before the refusal.")
        let restriction = try JSONDecoder().decode(Restriction.self, from: await control("permissions/restrict", post: true))
        XCTAssertEqual(restriction.deniedStatus, 403, "The real host did not establish a per-agent denial.")
        backToList(); openChat("Simulator Agent")
        _ = try await control("online", post: true)

        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var after = try await status()
        while ProcessInfo.processInfo.systemUptime < deadline &&
                (!after.allowedMessages.contains(where: { $0.author == "assistant" && $0.text == "SIM-ACCESS-3 received" && $0.status == "completed" }) ||
                 !hasHealthyRoundTrip(after, deniedPath: deniedPath, allowedPath: allowedPath)) {
            try await Task.sleep(for: .milliseconds(150))
            after = try await status()
        }
        let refusalIndex = try XCTUnwrap(after.rpc.firstIndex { frame in
            frame.kind == "error" && frame.method == "POST" && frame.path == deniedPath && frame.status == 403
        }, "The phone did not receive a real host403 for its denied message request.")
        let refusal = after.rpc[refusalIndex]
        XCTAssertTrue(hasHealthyRoundTrip(after, deniedPath: deniedPath, allowedPath: allowedPath),
                      "The denial was not followed by successful requests on the same RTC peer.")
        XCTAssertEqual(after.bridgeLifecycle, try XCTUnwrap(refusal.lifecycle),
                       "RTC or Signal reconnected after the denial; this did not retain a healthy peer.")
        try attach(after, name: "State after phone403 with healthy RTC")
        XCTAssertGreaterThan(after.sealedFileCount, 0, "A per-agent403 purged the encrypted native workspace.")
        XCTAssertEqual(after.memberRole, "member")
        XCTAssertTrue(after.memberActive)
        XCTAssertEqual(after.deniedMessages.filter { $0.text == "SIM-ACCESS-2" }.count, 0,
                       "A view-only request reached the agent.")
        let accepted = after.allowedMessages.filter { $0.author == "user" && $0.text == "SIM-ACCESS-3" }
        XCTAssertEqual(accepted.count, 1, "A per-agent denial lost or duplicated the unrelated queued input.")
        let turn = try XCTUnwrap(accepted.first?.turnId)
        XCTAssertEqual(after.allowedMessages.filter { $0.author == "assistant" && $0.text == "SIM-ACCESS-3 received" && $0.turnId == turn && $0.status == "completed" }.count, 1)

        XCTAssertTrue(app.staticTexts["Not Sent"].firstMatch.waitForExistence(timeout: 10),
                      "A confirmed host403 stayed uncertain instead of becoming a definite failed send.")
        XCTAssertFalse(app.staticTexts["Pending"].firstMatch.exists,
                       "The phone still presents the refused message as an uncertain delivery.")

        app.terminate(); app.launch()
        if app.textFields["message-composer"].waitForExistence(timeout: 5) { backToList() }
        openChat("Permission Queue Agent")
        XCTAssertTrue(textElements("SIM-ACCESS-3 received").firstMatch.waitForExistence(timeout: 30),
                      "The refusal ended the phone account or removed the permitted conversation.")
        let reopened = try await status()
        let requestCount: (Status) -> Int = { state in
            state.rpc.filter { $0.kind == "request" && $0.method == "POST" && $0.path == deniedPath }.count
        }
        XCTAssertEqual(requestCount(reopened), requestCount(before) + 1,
                       "A definite permission refusal was retried automatically, including after restart.")
        try attach(reopened, name: "Definite refusal preserved across restart")
        _ = try await control("permissions/revoke", post: true)
        let revokedDeadline = ProcessInfo.processInfo.systemUptime + 45
        var revoked = try await status()
        while ProcessInfo.processInfo.systemUptime < revokedDeadline && revoked.sealedFileCount > 0 {
            try await Task.sleep(for: .milliseconds(150)); revoked = try await status()
        }
        try attach(revoked, name: "State after actual membership revocation")
        XCTAssertFalse(revoked.memberActive)
        XCTAssertEqual(revoked.availableHosts, 0)
        XCTAssertEqual(revoked.sealedFileCount, 0, "Actual revoked host access retained its encrypted workspace.")
        app.terminate(); app.launch()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Permission Queue Agent")).firstMatch.waitForExistence(timeout: 5))
        let afterRestart = try await status()
        XCTAssertEqual(afterRestart.sealedFileCount, 0)
    }

    private func hasHealthyRoundTrip(_ state: Status, deniedPath: String, allowedPath: String) -> Bool {
        guard let index = state.rpc.firstIndex(where: {
            $0.kind == "error" && $0.method == "POST" && $0.path == deniedPath && $0.status == 403
        }) else { return false }
        let peer = state.rpc[index].peerId
        let later = state.rpc.dropFirst(index + 1)
        return later.contains { $0.peerId == peer && $0.kind == "response" && $0.method == "POST" && $0.path == allowedPath && $0.status == 202 } &&
            later.contains { $0.peerId == peer && $0.kind == "response" && $0.method == "GET" && $0.status == 200 }
    }

    private func backToList() { app.buttons["Back"].firstMatch.tap() }

    private func openChat(_ name: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 45)); row.tap()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 15))
    }

    private func status() async throws -> Status {
        try JSONDecoder().decode(Status.self, from: await control("permissions/status"))
    }

    private func attach(_ status: Status, name: String) throws {
        let attachment = XCTAttachment(data: try JSONEncoder().encode(status), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private struct Setup: Decodable { let email: String; let deniedAgentID: String; let allowedAgentID: String }
    private struct Restriction: Decodable { let deniedStatus: Int }
    private struct BridgeLifecycle: Codable, Equatable {
        let connections: Int
        let disconnections: Int
        let pathLosses: Int
        let signalOpens: Int
        let signalCloses: Int
    }
    private struct RpcFrame: Codable {
        let kind: String
        let peerId: String
        let requestId: String
        let method: String?
        let path: String?
        let status: Int?
        let code: String?
        let lifecycle: BridgeLifecycle?
    }
    private struct Status: Codable {
        struct Message: Codable { let id: String; let author: String; let text: String; let status: String; let turnId: String? }
        let email: String
        let memberRole: String?
        let memberActive: Bool
        let availableHosts: Int
        let sealedFileCount: Int
        let deniedMessages: [Message]
        let allowedMessages: [Message]
        let rpc: [RpcFrame]
        let bridgeLifecycle: BridgeLifecycle
    }
}
