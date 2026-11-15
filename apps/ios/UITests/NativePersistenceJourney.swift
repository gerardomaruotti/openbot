import XCTest

/// The generic queue journey owns network recovery. This journey checks that a
/// real local write failure does not leave a durable message stranded online.
@MainActor
final class NativePersistenceJourney: NativeFixtureCase {
    func testQueuedSendResumesAfterStorageRecovery() async throws {
        continueAfterFailure = false
        signInAndOpenChat()
        let request = "SIM-STORAGE-1"
        let answer = request + " received"
        let draft = "D"
        let initial = try await status()
        XCTAssertFalse(initial.messages.contains { $0.text == request })

        _ = try await control("offline", post: true)
        send(request)
        XCTAssertTrue(app.staticTexts["Waiting to send"].waitForExistence(timeout: 15),
                      "The offline request was not saved in the native queue.")
        let queued = try await status()
        XCTAssertFalse(queued.messages.contains { $0.text == request },
                       "The request reached the host before the storage fault.")

        let composer = app.textFields.matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("A")
        // A real filesystem fault blocks the existing queue. An explicit Send
        // proves the write failed using generic feedback, not a background banner.
        _ = try await control("storage/fail-writes", post: true)
        _ = try await control("online", post: true)
        app.buttons["Send Message"].tap()
        XCTAssertTrue(textElements("Something went wrong.").firstMatch.waitForExistence(timeout: 30),
                      "The explicit failed Send did not receive generic feedback.")
        XCTAssertFalse(app.staticTexts["Your chats could not be opened or saved securely on this iPhone. Please try again."].exists)
        XCTAssertEqual(composer.value as? String, "A", "Failed Send cleared its unsaved input.")
        let blocked = try await status()
        XCTAssertFalse(blocked.messages.contains { $0.text == request || $0.text == "A" },
                       "The app sent a message while its required local write failed.")
        XCTAssertEqual(blocked.providerTurns, initial.providerTurns)

        let restoreStarted = ProcessInfo.processInfo.systemUptime
        _ = try await control("storage/restore-writes", post: true)
        if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.tap() }
        let editStarted = ProcessInfo.processInfo.systemUptime
        composer.tap()
        composer.typeText(XCUIKeyboardKey.delete.rawValue + draft)
        let editCompleted = ProcessInfo.processInfo.systemUptime

        // Observe the actual host transcript, not the local optimistic bubble.
        // No Send, Retry, Reconnect, or app lifecycle action follows the edit.
        let deadline = editCompleted + 10
        var latest = blocked
        var receiptObserved: TimeInterval?
        var completedAnswer = false
        var answerObserved: TimeInterval?
        repeat {
            latest = try await status()
            let inputs = latest.messages.filter { $0.text == request }
            if !inputs.isEmpty, receiptObserved == nil {
                receiptObserved = ProcessInfo.processInfo.systemUptime
            }
            if inputs.count == 1, let turn = inputs[0].turnId {
                completedAnswer = latest.chatMessages.contains {
                    $0.author == "assistant" && $0.text == answer &&
                    $0.turnId == turn && $0.status == "completed"
                }
                if completedAnswer { answerObserved = ProcessInfo.processInfo.systemUptime }
            }
            if completedAnswer || inputs.count > 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline

        let inputs = latest.messages.filter { $0.text == request }
        let report = RecoveryReport(
            request: request,
            hostInputCount: inputs.count,
            hostMessageID: inputs.first?.id,
            hostTurnID: inputs.first?.turnId,
            completedSameTurnAnswer: completedAnswer,
            hostReceiptWithin10Seconds: receiptObserved.map { $0 <= deadline } ?? false,
            completedAnswerWithin10Seconds: answerObserved.map { $0 <= deadline } ?? false,
            providerTurnDelta: latest.providerTurns - initial.providerTurns,
            restoreToFirstHostReceiptObservedMS: receiptObserved.map { ($0 - restoreStarted) * 1_000 },
            editStartToFirstHostReceiptObservedMS: receiptObserved.map { ($0 - editStarted) * 1_000 },
            editCompletionToObservationMS: receiptObserved.map { ($0 - editCompleted) * 1_000 },
            observationWindowMS: (ProcessInfo.processInfo.systemUptime - editCompleted) * 1_000,
            draftValue: composer.value as? String,
            draftReachedHost: latest.messages.contains { $0.text == draft }
        )
        try attach(report)

        XCTAssertNotNil(receiptObserved,
                        "A successful draft write did not resume the queued request within 10 seconds.")
        XCTAssertTrue(report.hostReceiptWithin10Seconds, "The queued request reached the host after the 10-second limit.")
        XCTAssertEqual(inputs.count, 1, "Storage recovery submitted the queued request more than once.")
        XCTAssertTrue(completedAnswer, "Storage recovery did not complete the same host turn within 10 seconds.")
        XCTAssertTrue(report.completedAnswerWithin10Seconds, "The host answer completed after the 10-second limit.")
        XCTAssertEqual(latest.providerTurns - initial.providerTurns, 1,
                       "Storage recovery started another provider turn.")
        XCTAssertFalse(report.draftReachedHost, "Editing the draft submitted it without Send.")
        XCTAssertEqual(composer.value as? String, draft, "Queue recovery changed the unsent draft.")
        XCTAssertTrue(textElements(answer).firstMatch.waitForExistence(timeout: 10),
                      "The actual host answer did not reach the native chat.")
        XCTAssertEqual(messageCount(request), 1, "The native chat duplicated the queued message.")
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(app.buttons["Send Message"].isEnabled)
    }

    private func signInAndOpenChat() {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openConnection()
        let email = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Email")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        email.typeText("native-simulator@example.invalid")
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.wait(for: \.isHittable, toEqual: true, timeout: 10))
        next.tap()
        let connect = app.buttons["Connect to Mac"]
        XCTAssertTrue(connect.wait(for: \.isHittable, toEqual: true, timeout: 15))
        connect.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 45))
        row.tap()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 15))
    }

    private func status() async throws -> HostStatus {
        try JSONDecoder().decode(HostStatus.self, from: await control("status"))
    }

    private func attach(_ report: RecoveryReport) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(data: try encoder.encode(report), uniformTypeIdentifier: "public.json")
        attachment.name = "Native storage recovery and first host receipt timing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct HostStatus: Decodable {
        struct Message: Decodable { let id: String; let text: String; let turnId: String? }
        struct ChatMessage: Decodable {
            let text: String; let author: String; let turnId: String?; let status: String
        }
        let messages: [Message]
        let chatMessages: [ChatMessage]
        let providerTurns: Int
    }

    private struct RecoveryReport: Encodable {
        let request: String
        let hostInputCount: Int
        let hostMessageID: String?
        let hostTurnID: String?
        let completedSameTurnAnswer: Bool
        let hostReceiptWithin10Seconds: Bool
        let completedAnswerWithin10Seconds: Bool
        let providerTurnDelta: Int
        let restoreToFirstHostReceiptObservedMS: Double?
        let editStartToFirstHostReceiptObservedMS: Double?
        let editCompletionToObservationMS: Double?
        let observationWindowMS: Double
        let draftValue: String?
        let draftReachedHost: Bool
    }
}
