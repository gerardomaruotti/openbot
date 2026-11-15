import XCTest

/// The generic messaging journey closes RTC and relaunches after a lost receipt.
/// This journey loses only one real response while the established path stays up.
@MainActor
final class NativeReceiptRecoveryJourney: NativeFixtureCase {
    func testHealthyConnectionRecoversOneLostSendReceipt() async throws {
        continueAfterFailure = false
        signInAndOpenChat()
        let first = "SIM-RECEIPT-1"
        let second = "SIM-RECEIPT-2"
        let before = try await status()

        _ = try await control("offline", post: true)
        let offline = try await status()
        XCTAssertFalse(offline.online, "The host did not enter the offline preparation state.")
        // Queue both before a connected drain starts. Sending a new message during
        // an in-flight send is a different recovery trigger and masks this defect.
        send(first)
        send(second)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Waiting to send")).count, 2)
        let queued = try await status()
        XCTAssertFalse(queued.messages.contains { $0.text == first || $0.text == second })
        XCTAssertEqual(queued.providerTurns, before.providerTurns)

        _ = try await control("drop-receipt-only", post: true)
        _ = try await control("online", post: true)
        let dropDeadline = ProcessInfo.processInfo.systemUptime + 45
        var latest = queued
        repeat {
            latest = try await status()
            if !latest.receiptOnlyFault.drops.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < dropDeadline
        let drop = try XCTUnwrap(latest.receiptOnlyFault.drops.first,
                                 "The fixture did not lose a real accepted message receipt.")
        XCTAssertEqual(latest.receiptOnlyFault.drops.count, 1)
        XCTAssertFalse(latest.receiptOnlyFault.armed)

        // Observe host rows and actual completed provider turns. After the real
        // receipt loss there is no app lifecycle, Send, Retry or Reconnect action.
        let observationStarted = ProcessInfo.processInfo.systemUptime
        let recoveryDeadline = observationStarted + 75
        var recoveryObserved: TimeInterval?
        repeat {
            latest = try await status()
            if completed(first, in: latest) && completed(second, in: latest) {
                recoveryObserved = ProcessInfo.processInfo.systemUptime
                break
            }
            if latest.messages.filter({ $0.text == first }).count > 1 ||
                latest.messages.filter({ $0.text == second }).count > 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < recoveryDeadline

        let firstInputs = latest.messages.filter { $0.text == first }
        let secondInputs = latest.messages.filter { $0.text == second }
        let evidence = RecoveryReport(
            firstHostRows: firstInputs.count, secondHostRows: secondInputs.count,
            firstCompletedAnswer: completed(first, in: latest),
            secondCompletedAnswer: completed(second, in: latest),
            providerTurnDelta: latest.providerTurns - before.providerTurns,
            oneRealReceiptDropped: latest.receiptOnlyFault.drops.count == 1,
            connectionLifecycleAtDrop: drop.lifecycle,
            connectionLifecycleAtObservation: latest.receiptOnlyFault.lifecycle,
            recoveryObservationMS: recoveryObserved.map { ($0 - observationStarted) * 1_000 },
            observationWindowMS: (ProcessInfo.processInfo.systemUptime - observationStarted) * 1_000,
            unconfirmedVisibleAtEnd: app.staticTexts["Pending"].firstMatch.exists,
            firstNativeRows: messageCount(first), secondNativeRows: messageCount(second),
            droppedAt: drop.droppedAt,
            limits: "One real host response lost; actual RTC/provider/SQLite. Timing includes host observation/poll overhead. No lifecycle or retry action after loss; no live model or physical phone."
        )
        try attach(evidence)

        XCTAssertTrue(latest.online, "The host went offline instead of losing only a response.")
        XCTAssertEqual(drop.lifecycle, latest.receiptOnlyFault.lifecycle,
                       "RTC or Signal recovered by reconnecting; this did not exercise a healthy retained connection.")
        XCTAssertEqual(firstInputs.count, 1, "Receipt recovery duplicated the first host message.")
        XCTAssertEqual(secondInputs.count, 1,
                       "The lost receipt stranded the next durable message on a healthy connection.")
        XCTAssertTrue(evidence.firstCompletedAnswer)
        XCTAssertTrue(evidence.secondCompletedAnswer,
                      "The second queued message did not complete without a manual retry or reconnect.")
        XCTAssertEqual(latest.providerTurns - before.providerTurns, 2,
                       "Receipt recovery started a duplicate provider turn.")
        XCTAssertNotNil(recoveryObserved)
        XCTAssertTrue(textElements(first + " received").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(textElements(second + " received").firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(messageCount(first), 1, "The native chat retained a duplicate first-send placeholder.")
        XCTAssertEqual(messageCount(second), 1)
        XCTAssertFalse(app.staticTexts["Pending"].firstMatch.exists)
    }

    private func completed(_ request: String, in state: HostStatus) -> Bool {
        let inputs = state.messages.filter { $0.text == request }
        guard inputs.count == 1, let turn = inputs.first?.turnId else { return false }
        return state.chatMessages.contains {
            $0.author == "assistant" && $0.text == request + " received" &&
            $0.turnId == turn && $0.status == "completed"
        }
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
        attachment.name = "Healthy RTC receipt recovery and same-chat delivery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct HostStatus: Decodable {
        struct Message: Decodable { let id: String; let text: String; let turnId: String? }
        struct ChatMessage: Decodable { let text: String; let author: String; let turnId: String?; let status: String }
        struct ReceiptFault: Decodable {
            struct Drop: Decodable { let droppedAt: String; let lifecycle: Lifecycle }
            let armed: Bool
            let drops: [Drop]
            let lifecycle: Lifecycle
        }
        let messages: [Message]
        let chatMessages: [ChatMessage]
        let providerTurns: Int
        let receiptOnlyFault: ReceiptFault
        let online: Bool
    }

    private struct Lifecycle: Codable, Equatable {
        let connections: Int
        let disconnections: Int
        let pathLosses: Int
        let signalOpens: Int
        let signalCloses: Int
    }

    private struct RecoveryReport: Encodable {
        let firstHostRows: Int
        let secondHostRows: Int
        let firstCompletedAnswer: Bool
        let secondCompletedAnswer: Bool
        let providerTurnDelta: Int
        let oneRealReceiptDropped: Bool
        let connectionLifecycleAtDrop: Lifecycle
        let connectionLifecycleAtObservation: Lifecycle
        let recoveryObservationMS: Double?
        let observationWindowMS: Double
        let unconfirmedVisibleAtEnd: Bool
        let firstNativeRows: Int
        let secondNativeRows: Int
        let droppedAt: String
        let limits: String
    }
}
