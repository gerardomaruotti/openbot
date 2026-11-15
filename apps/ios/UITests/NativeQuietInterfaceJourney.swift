import XCTest

/// The host owns actual routine failure, history and filesystem faults. The native
/// boundary owns quiet passive failures, generic action errors and intact drafts.
@MainActor
final class NativeQuietInterfaceJourney: NativeFixtureCase {
    private let genericError = "Something went wrong."

    func testPassiveFailureIsQuietAndExplicitSendFailureKeepsDraft() async throws {
        continueAfterFailure = false
        let setup = try JSONDecoder().decode(Setup.self, from: await control("quiet/setup", post: true))
        signInAndOpenChat()
        XCTAssertTrue(textElements(setup.content).firstMatch.waitForExistence(timeout: 30),
                      "Ordinary assistant content with technical words was removed.")

        _ = try await control("quiet/run-background", post: true)
        let failed = try await waitForQuietStatus {
            $0.routineRuns.count == 1 && $0.routineRuns.first?.status == "failed" && $0.activeTurnId == nil
        }
        XCTAssertEqual(failed.routineRuns.first?.kind, "manual")
        XCTAssertFalse(failed.failedTurns.isEmpty, "No actual failed host turn reached the runtime snapshot.")
        try attach(failed, name: "Actual routine failure before native snapshot reload")

        // A fresh restore reads the completed failed-turn snapshot. Waiting for
        // its saved conversation gives a positive hydration barrier before the
        // absence checks, without starting a new turn that clears host failures.
        app.terminate(); app.launch()
        openChatIfNeeded()
        XCTAssertTrue(textElements(setup.content).firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(textElements("Request failed").firstMatch.exists,
                       "A passive routine failure exposed a technical failure card.")
        XCTAssertFalse(textElements("Open OpenBot on your Mac to review the error. Check the result before you send this request again.").firstMatch.exists)
        XCTAssertFalse(textElements("Synthetic request failed. No external action was performed.").firstMatch.exists)
        XCTAssertFalse(textElements(genericError).firstMatch.exists,
                       "A passive routine failure raised a foreground action error.")

        app.buttons["Simulator Agent"].firstMatch.tap()
        let routines = app.buttons["Routines"].firstMatch
        XCTAssertTrue(routines.wait(for: \.isHittable, toEqual: true, timeout: 10)); routines.tap()
        let savedRoutine = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", setup.routineName)).firstMatch
        XCTAssertTrue(savedRoutine.wait(for: \.isHittable, toEqual: true, timeout: 15)); savedRoutine.tap()
        XCTAssertTrue(app.staticTexts["Recent Runs"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Failed"].firstMatch.exists,
                       "The routine history exposed a passive failure status.")
        XCTAssertFalse(app.staticTexts["Synthetic request failed. No external action was performed."].firstMatch.exists)
        for _ in 0..<4 where !app.textFields["message-composer"].isHittable {
            let done = app.buttons["Done"].firstMatch
            let back = app.buttons["Back"].firstMatch
            let nativeBack = app.navigationBars.buttons.element(boundBy: 0)
            if done.exists && done.isHittable { done.tap() }
            else if back.exists && back.isHittable { back.tap() }
            else {
                XCTAssertTrue(nativeBack.wait(for: \.isHittable, toEqual: true, timeout: 10)); nativeBack.tap()
            }
        }
        XCTAssertTrue(app.textFields["message-composer"].wait(for: \.isHittable, toEqual: true, timeout: 10))

        let request = "SIM-QUIET-1"
        let composer = app.textFields["message-composer"].firstMatch
        XCTAssertTrue(composer.wait(for: \.isHittable, toEqual: true, timeout: 10))
        composer.tap(); composer.typeText(request)
        // Fault after the draft is saved; the Send action must fail its actual
        // durable write, retain the draft and avoid a host mutation.
        _ = try await control("storage/fail-writes", post: true)
        let send = app.buttons["Send Message"].firstMatch
        XCTAssertTrue(send.wait(for: \.isHittable, toEqual: true, timeout: 10)); send.tap()
        XCTAssertTrue(textElements(genericError).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(textElements("Your chats could not be opened or saved securely on this iPhone. Please try again.").firstMatch.exists,
                       "The explicit action exposed storage details.")
        XCTAssertEqual(composer.value as? String, request, "An unsuccessful send cleared the unsent draft.")
        let blocked = try await quietStatus()
        XCTAssertFalse(blocked.messages.contains { $0.author == "user" && $0.text == request },
                       "The message reached the host without its required durable save.")
        try attach(blocked, name: "Explicit Send failed without a host mutation")

        _ = try await control("storage/restore-writes", post: true)
        // Generic feedback may be an alert or inline message. Dismiss only an
        // actual alert; the next Send remains the explicit retry decision.
        if app.alerts.firstMatch.exists {
            let done = app.alerts.firstMatch.buttons.firstMatch
            XCTAssertTrue(done.isHittable); done.tap()
        }
        XCTAssertTrue(send.wait(for: \.isHittable, toEqual: true, timeout: 10)); send.tap()
        reply(request + " received")
        let recovered = try await waitForQuietStatus {
            $0.messages.contains { $0.author == "assistant" && $0.text == request + " received" && $0.status == "completed" }
        }
        let inputs = recovered.messages.filter { $0.author == "user" && $0.text == request }
        XCTAssertEqual(inputs.count, 1, "The explicit retry duplicated or lost the message.")
        let turn = try XCTUnwrap(inputs.first?.turnId)
        XCTAssertEqual(recovered.messages.filter {
            $0.author == "assistant" && $0.text == request + " received" && $0.turnId == turn && $0.status == "completed"
        }.count, 1)
        XCTAssertEqual(recovered.routineRuns.count, 1, "The native screen replayed the failed routine.")
        XCTAssertEqual(recovered.messages.filter { $0.text == setup.content && $0.author == "assistant" }.count, 1)
        try attach(recovered, name: "Explicit retry completed exactly one host turn")
    }

    private func signInAndOpenChat() {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openConnection()
        let email = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Email")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 15)); email.tap(); email.typeText("native-simulator@example.invalid")
        app.buttons["Continue"].tap()
        let connect = app.buttons["Connect to Mac"].firstMatch
        XCTAssertTrue(connect.wait(for: \.isHittable, toEqual: true, timeout: 15)); connect.tap()
        openChatIfNeeded()
    }

    private func openChatIfNeeded() {
        if app.textFields["message-composer"].waitForExistence(timeout: 3) { return }
        let chat = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch
        XCTAssertTrue(chat.wait(for: \.isHittable, toEqual: true, timeout: 45)); chat.tap()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 15))
    }

    private func quietStatus() async throws -> Status {
        try JSONDecoder().decode(Status.self, from: await control("quiet/status"))
    }

    private func waitForQuietStatus(_ satisfied: (Status) -> Bool) async throws -> Status {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var value = try await quietStatus()
        while !satisfied(value), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100)); value = try await quietStatus()
        }
        XCTAssertTrue(satisfied(value), "The actual quiet fixture did not reach its expected host state.")
        return value
    }

    private func attach(_ value: Status, name: String) throws {
        let attachment = XCTAttachment(data: try JSONEncoder().encode(value), uniformTypeIdentifier: "public.json")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private struct Setup: Decodable { let content: String; let routineName: String; let routineId: String }
    private struct Status: Codable {
        struct Run: Codable { let id: String; let status: String; let kind: String; let deliveryId: String? }
        struct Turn: Codable { let agentId: String; let turnId: String }
        struct Message: Codable { let id: String; let author: String; let text: String; let status: String; let turnId: String? }
        let activeTurnId: String?
        let routineRuns: [Run]
        let failedTurns: [Turn]
        let messages: [Message]
    }
}
