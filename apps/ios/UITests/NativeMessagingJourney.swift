import XCTest

@MainActor
final class NativeMessagingJourney: NativeFixtureCase {
    private func hostStatus() async throws -> Status {
        try JSONDecoder().decode(Status.self, from: await control("status"))
    }

    private func choice(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    private func questionField(_ placeholder: String) -> XCUIElement {
        let predicate = NSPredicate(format: "placeholderValue == %@ OR label == %@", placeholder, placeholder)
        let field = app.textFields.matching(predicate).firstMatch
        return field.exists ? field : app.textViews.matching(predicate).firstMatch
    }

    private func dismissOptionalPasswordOffer() {
        // A generic note plus a private answer can trigger iOS credential heuristics.
        // Respect the system choice and decline saving this synthetic one-use input.
        let service = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let title = service.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save Password?")).firstMatch
        if title.waitForExistence(timeout: 3) {
            let notNow = service.buttons["Not Now"]
            XCTAssertTrue(notNow.wait(for: \.isHittable, toEqual: true, timeout: 5))
            notNow.tap()
            XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        }
    }

    private func answerQuestionsAfterRelaunch() async throws {
        send("SIM-QUESTION")
        XCTAssertTrue(app.buttons["Send answers"].waitForExistence(timeout: 20))
        app.terminate()
        app.launch()
        // Runtime summaries cut this prompt at 240 characters. The real conversation
        // must hydrate its full text before the recovered request can be answered.
        let fullQuestion = "Choose a color. " + String(repeating: "The complete question must be shown before you answer. ", count: 6)
        XCTAssertGreaterThan(fullQuestion.count, 240)
        let recoveredQuestion = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Choose a color.")).firstMatch
        XCTAssertTrue(recoveredQuestion.waitForExistence(timeout: 30), "The recovered request did not restore the question.")
        XCTAssertEqual(recoveredQuestion.label.trimmingCharacters(in: .whitespacesAndNewlines), fullQuestion.trimmingCharacters(in: .whitespacesAndNewlines), "The recovered question was shortened.")
        let blue = choice("Blue")
        reveal(blue, swipingUp: false)
        blue.tap()
        XCTAssertTrue(blue.isSelected)
        let small = choice("Small")
        reveal(small, swipingUp: true)
        small.tap()
        let large = choice("Large")
        reveal(large, swipingUp: true)
        large.tap()
        XCTAssertTrue(small.isSelected)
        XCTAssertTrue(large.isSelected)
        let note = questionField("Your answer")
        reveal(note, swipingUp: true)
        note.tap()
        note.typeText("Synthetic simulator note")
        let privateField = app.secureTextFields.matching(NSPredicate(format: "placeholderValue == %@ OR label == %@", "Private answer", "Private answer")).firstMatch
        reveal(privateField, swipingUp: true)
        privateField.tap()
        privateAnswerInFlight = true
        // A fixed, non-credential fixture value. Keep private input out of explicit
        // diagnostics and verify only the host's presence/count metadata.
        privateField.typeText("simulator-only")
        let submit = app.buttons["Send answers"]
        reveal(submit, swipingUp: true)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()
        reply("SIM-QUESTION answered")
        privateAnswerInFlight = false
        dismissOptionalPasswordOffer()
        var status = try await hostStatus()
        let answer = try XCTUnwrap(status.promptAnswers.first { !$0.cancelled })
        XCTAssertTrue(answer.expectedColor)
        XCTAssertTrue(answer.expectedSizes)
        XCTAssertTrue(answer.freeTextReceived)
        XCTAssertTrue(answer.secretReceived)
        XCTAssertEqual(answer.answerCounts, ["color": 1, "sizes": 2, "note": 1, "private-code": 1])
        XCTAssertEqual(status.pendingPrompts, 0)

        send("SIM-QUESTION")
        let cancel = app.buttons["Cancel request"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20))
        reveal(cancel, swipingUp: true)
        cancel.tap()
        reply("SIM-QUESTION cancelled")
        status = try await hostStatus()
        XCTAssertEqual(status.promptAnswers.count, 2)
        let cancelled = try XCTUnwrap(status.promptAnswers.first(where: \.cancelled))
        XCTAssertEqual(cancelled.answerCounts, ["color": 0, "sizes": 0, "note": 0, "private-code": 0])
        XCTAssertFalse(cancelled.freeTextReceived)
        XCTAssertFalse(cancelled.secretReceived)
        XCTAssertEqual(status.pendingPrompts, 0)
        XCTAssertEqual(status.messages.filter { $0.text == "SIM-QUESTION" }.count, 2)
    }

    private func stopStreamingResponse() async throws {
        let before = try await hostStatus()
        send("SIM-STREAM-1")
        reply("SIM-STREAM-1 partial")
        send("SIM-QUEUED-1")
        XCTAssertFalse(app.staticTexts["Waiting on your Mac"].exists, "The host queue exposed a technical explanation.")
        let queued = try await hostStatus()
        XCTAssertEqual(queued.queue.queued, 1, "The request did not enter the real host queue.")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 30))
        let restoredQueue = try await hostStatus()
        XCTAssertEqual(restoredQueue.queue.queued, 1, "The host queue was not recovered.")
        XCTAssertFalse(app.staticTexts["Waiting on your Mac"].exists)
        let stop = app.buttons["Stop response"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        reveal(stop, swipingUp: true)
        stop.tap()
        var status = try await hostStatus()
        let deadline = Date().addingTimeInterval(15)
        while (status.activeTurnId != nil || status.interruptedTurns == before.interruptedTurns) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            status = try await hostStatus()
        }
        XCTAssertNil(status.activeTurnId)
        XCTAssertEqual(status.interruptedTurns, before.interruptedTurns + 1)
        reply("SIM-QUEUED-1 received")
        status = try await hostStatus()
        XCTAssertEqual(status.queue.queued, 0)
        XCTAssertTrue(stop.waitForNonExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Working…"].exists)
    }

    private func reviewCompleteConfirmation() async throws {
        send("SIM-CONFIRM")
        XCTAssertTrue(app.staticTexts["Send synthetic draft?"].waitForExistence(timeout: 20))
        app.terminate()
        app.launch()
        let preview = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "SIM-CONFIRM-TAIL")).firstMatch
        reveal(preview, swipingUp: false, requiresInteraction: false)
        XCTAssertTrue(preview.waitForExistence(timeout: 20), "The complete confirmation preview was not recovered.")
        XCTAssertGreaterThan(preview.label.count, 2200)
        let sender = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "From")).firstMatch
        reveal(sender, swipingUp: false)
        sender.tap()
        let work = app.buttons["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.tap()
        let action = app.buttons["Send synthetic draft"]
        reveal(action, swipingUp: true)
        action.tap()
        let confirm = app.buttons["Confirm action"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "The privileged action skipped explicit confirmation.")
        let pending = try await hostStatus()
        XCTAssertTrue(pending.confirmAnswers.isEmpty, "The host received an action before confirmation.")
        confirm.tap()
        reply("SIM-CONFIRM answered")
        let answered = try await hostStatus()
        XCTAssertEqual(answered.confirmAnswers.count, 1)
        XCTAssertEqual(answered.confirmAnswers.first?.actionId, "send")
        XCTAssertEqual(answered.confirmAnswers.first?.sender, "Work")

        send("SIM-CONFIRM")
        let cancel = app.buttons["Cancel request"]
        reveal(cancel, swipingUp: true)
        cancel.tap()
        reply("SIM-CONFIRM cancelled")
        let cancelled = try await hostStatus()
        XCTAssertEqual(cancelled.confirmAnswers.count, 2)
        XCTAssertTrue(cancelled.confirmAnswers.last?.cancelled == true)
        XCTAssertNil(cancelled.confirmAnswers.last?.actionId)
    }

    private func recoverFailureAndBrowserRequest() async throws {
        send("SIM-FAIL")
        XCTAssertTrue(app.staticTexts["Something went wrong."].waitForExistence(timeout: 20), "A user-requested execution failure was silent.")
        XCTAssertFalse(app.staticTexts["Request failed"].exists)
        let failed = try await hostStatus()
        XCTAssertFalse(failed.failedTurns.isEmpty, "The fixture did not record the real failed turn.")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Request failed"].exists)
        XCTAssertFalse(app.staticTexts["Something went wrong."].exists, "A prior failure raised a new action error after restart.")
        let reopened = try await hostStatus()
        XCTAssertEqual(Set(reopened.failedTurns.map(\.turnId)), Set(failed.failedTurns.map(\.turnId)),
                       "Restart changed the host's actual failure record.")
        send("SIM-AFTER-1")
        reply("SIM-AFTER-1 received")
        XCTAssertTrue(app.staticTexts["Something went wrong."].waitForNonExistence(timeout: 15))

        send("SIM-BROWSER")
        let handoff = app.buttons["Cancel browser request"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["example.invalid"].exists)
        XCTAssertTrue(app.buttons["Open browser"].exists, "The supported host did not expose its phone browser action.")
        XCTAssertFalse(app.staticTexts["Working…"].exists, "The browser handoff was hidden behind generic Working.")
        app.terminate()
        app.launch()
        XCTAssertTrue(handoff.waitForExistence(timeout: 30), "The browser sign-in request did not recover.")
        let cancel = app.buttons["Cancel browser request"]
        reveal(cancel, swipingUp: true)
        cancel.tap()
        reply("SIM-BROWSER cancelled")
        let status = try await hostStatus()
        XCTAssertEqual(status.pendingBrowserTakeovers, 0)
        XCTAssertTrue(status.browserAnswers.last?.cancelled == true)
        XCTAssertGreaterThanOrEqual(status.browserSurface.secretCancels, 1)
        XCTAssertTrue(handoff.waitForNonExistence(timeout: 10))
    }

    private func signOutWithoutAccountService() async throws {
        _ = try await control("signout-revoke-unavailable", post: true)
        app.buttons["Done"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        _ = try await control("offline", post: true)
        send("SIM-LOGOUT-1")
        XCTAssertTrue(app.staticTexts["Waiting to send"].waitForExistence(timeout: 15))
        let draft = app.textFields.matching(identifier: "message-composer").firstMatch
        draft.tap()
        draft.typeText("UNSENT-LOGOUT-DRAFT")
        app.buttons["Back"].tap()
        openConnection()
        let signOut = app.buttons["Sign Out"]
        for _ in 0..<4 where !signOut.isHittable { app.swipeDown() }
        XCTAssertTrue(signOut.wait(for: \.isHittable, toEqual: true, timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "including those for other Macs")).firstMatch.waitForExistence(timeout: 5))
        let confirm = try XCTUnwrap(app.buttons.matching(identifier: "Sign Out").allElementsBoundByIndex.last)
        confirm.tap()
        let notice = app.staticTexts["Something went wrong."]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let status = try await hostStatus()
        XCTAssertEqual(status.signout.revokeFailures, 1)
        XCTAssertTrue(status.signout.rejectedSessionStillActive, "The test did not exercise unavailable remote revocation.")
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Email")).firstMatch.exists)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch.exists)
        XCTAssertFalse(textElements("SIM-DRAFT-1").firstMatch.exists)
        XCTAssertFalse(app.buttons["Send Message"].exists)
        _ = try await control("online", post: true)
        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
        getStarted.tap()
        let email = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Email")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("native-simulator@example.invalid")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Connect to Mac"].waitForExistence(timeout: 15))
        app.buttons["Connect to Mac"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The reset transport did not support fresh sign-in.")
        row.tap()
        XCTAssertTrue(draft.waitForExistence(timeout: 15))
        XCTAssertNotEqual(draft.value as? String, "UNSENT-LOGOUT-DRAFT")
        let reconnected = try await hostStatus()
        XCTAssertEqual(reconnected.messages.filter { $0.text == "SIM-LOGOUT-1" }.count, 0, "Sign-out replayed a deleted pending message.")
    }

    private func keepUnsentDraft() async throws {
        let marker = "SIM-DRAFT-1"
        let field = app.textFields.matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(marker)
        app.buttons["Back"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, marker, "Navigating away lost the unsent draft.")
        app.terminate()
        app.launch()
        if !field.waitForExistence(timeout: 5) {
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, marker, "The encrypted draft did not survive restart.")
        let before = try await hostStatus()
        XCTAssertEqual(before.messages.filter { $0.text == marker }.count, 0, "A draft was submitted without Send.")
        app.buttons["Send Message"].tap()
        reply(marker + " received")
        let after = try await hostStatus()
        XCTAssertEqual(after.messages.filter { $0.text == marker }.count, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        XCTAssertNotEqual(field.value as? String, marker, "Sending did not clear the saved draft.")
        XCTAssertFalse(app.buttons["Send Message"].exists)
    }

    private func loadOlderHistory() async throws {
        let seed = try JSONDecoder().decode(HistorySeed.self, from: await control("seed-history", post: true))
        XCTAssertEqual(seed.count, 60)
        XCTAssertTrue(seed.pageInfo.hasOlder)
        XCTAssertNotNil(seed.pageInfo.olderCursor)
        XCTAssertNotEqual(seed.firstMessageId, seed.lastMessageId)
        app.terminate()
        app.launch()
        let latestMarker = textElements(seed.lastMarker).firstMatch
        reveal(latestMarker, swipingUp: false, requiresInteraction: false)
        XCTAssertTrue(latestMarker.exists, "The latest host page did not arrive.")
        XCTAssertFalse(textElements(seed.firstMarker).firstMatch.exists, "The oldest marker should require another host page.")
        let older = app.buttons["Load earlier messages"]
        reveal(older, swipingUp: false)
        XCTAssertTrue(older.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        older.tap()
        let oldestMarker = textElements(seed.firstMarker).firstMatch
        reveal(oldestMarker, swipingUp: false, requiresInteraction: false)
        XCTAssertTrue(oldestMarker.exists, "Loading earlier messages did not restore the oldest host marker.")
        XCTAssertEqual(messageCount(seed.firstMarker), 1)
        reveal(latestMarker, swipingUp: true, requiresInteraction: false)
        XCTAssertEqual(messageCount(seed.lastMarker), 1, "The current page was duplicated when earlier history arrived.")
    }

    private func downloadHostAttachment() async throws {
        let seed = try JSONDecoder().decode(AttachmentSeed.self, from: await control("seed-attachment", post: true))
        XCTAssertNotNil(seed.messageId)
        XCTAssertEqual(seed.attachments.count, 1)
        let attachment = try XCTUnwrap(seed.attachments.first)
        XCTAssertEqual(attachment.name, "simulator-note.txt")
        XCTAssertGreaterThan(attachment.size, 0)
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", attachment.name)).firstMatch
        reveal(file, swipingUp: true)
        XCTAssertTrue(file.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        file.tap()
        // Quick Look owns the file renderer; this runtime does not expose its body
        // text through XCTest. Verify the authenticated download and presented preview.
        // The exact visible bytes are retained in the separate device inspection.
        let done = app.buttons.matching(identifier: "Done").firstMatch
        XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 30), "The downloaded file preview did not open.")
        XCTAssertTrue(app.buttons["Share File"].isHittable)
        let status = try await hostStatus()
        XCTAssertTrue(status.rpc.contains { $0.kind == "request" && $0.path == "/v1/attachments/" + attachment.id }, "The phone did not request the real host attachment.")
        done.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        reply("SIM-FILE received")
    }

    func testChatQueueAndLostReceipt() async throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openConnection()
        let email = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Email")).firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 15), app.debugDescription)
        email.tap()
        email.typeText("native-simulator@example.invalid")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons["Connect to Mac"].waitForExistence(timeout: 15))
        app.buttons["Connect to Mac"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
        row.tap()
        send("SIM-CHAT-1")
        reply("SIM-CHAT-1 received")
        var status = try await hostStatus()
        XCTAssertEqual(status.messages.filter { $0.text == "SIM-CHAT-1" }.count, 1)
        XCTAssertEqual(status.providerTurns, 1)
        XCTAssertTrue(status.paths.contains("p2p"), "No real RTC connection path was recorded.")

        _ = try await control("offline", post: true)
        send("SIM-OFFLINE-1")
        XCTAssertTrue(app.staticTexts["Waiting to send"].waitForExistence(timeout: 15))
        app.terminate()
        app.launch()
        XCTAssertTrue(textElements("SIM-OFFLINE-1").firstMatch.waitForExistence(timeout: 15))
        _ = try await control("online", post: true)
        reply("SIM-OFFLINE-1 received")
        status = try await hostStatus()
        XCTAssertEqual(status.messages.filter { $0.text == "SIM-OFFLINE-1" }.count, 1)
        XCTAssertEqual(status.providerTurns, 2)

        _ = try await control("drop-receipt", post: true)
        send("SIM-ONCE-1")
        // The host commits the request, then the real RPC response is dropped and RTC closes.
        let deadline = Date().addingTimeInterval(20)
        repeat {
            status = try await hostStatus()
            if status.droppedReceipts == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        XCTAssertEqual(status.droppedReceipts, 1)
        app.terminate()
        app.launch()
        reply("SIM-ONCE-1 received")
        status = try await hostStatus()
        XCTAssertEqual(status.messages.filter { $0.text == "SIM-ONCE-1" }.count, 1)
        XCTAssertEqual(status.providerTurns, 3, "Recovery started a duplicate provider turn.")
        for marker in ["SIM-CHAT-1", "SIM-OFFLINE-1", "SIM-ONCE-1"] {
            XCTAssertEqual(messageCount(marker), 1, "A sent placeholder was duplicated after relaunch.")
        }
        send("SIM-STREAM-1")
        reply("SIM-STREAM-1 partial")
        _ = try await control("finish-stream", post: true)
        reply("SIM-STREAM-1 partial and complete")

        send("SIM-APPROVAL")
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["printf simulator-only"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Allow once"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
        app.buttons["Allow once"].tap()
        reply("SIM-APPROVAL accepted")
        send("SIM-APPROVAL")
        XCTAssertTrue(app.buttons["Decline"].waitForExistence(timeout: 20))
        app.buttons["Decline"].tap()
        reply("SIM-APPROVAL declined")
        status = try await hostStatus()
        XCTAssertEqual(status.providerTurns, 6)
        XCTAssertEqual(status.pendingApprovals, 0)
        // Exercise the two-page fixture before later tool flows add more than
        // one page of newer rows. All sixty imported markers precede this chat.
        try await loadOlderHistory()
        try await answerQuestionsAfterRelaunch()
        try await stopStreamingResponse()
        try await keepUnsentDraft()
        try await reviewCompleteConfirmation()
        try await recoverFailureAndBrowserRequest()
        try await downloadHostAttachment()
        app.buttons["Back"].tap()
        openConnection()
        let allowNotifications = app.buttons["Allow Notifications"]
        if !allowNotifications.exists { app.swipeUp() }
        XCTAssertTrue(allowNotifications.waitForExistence(timeout: 15), app.debugDescription)
        allowNotifications.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAllow = springboard.alerts.buttons["Allow"]
        if systemAllow.waitForExistence(timeout: 5) { systemAllow.tap() }
        XCTAssertTrue(app.staticTexts["Notifications are allowed"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Alerts from your Mac are not configured for this build yet.")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Notification keys could not be saved safely."].exists)
        app.buttons["Send Test Alert"].tap()
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Notifications are working on this iPhone.")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "No real iOS local notification banner appeared.")
        app.buttons["Turn Off Alerts"].tap()
        XCTAssertTrue(app.buttons["Turn On Alerts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Turn On Alerts"].wait(for: \.isEnabled, toEqual: true, timeout: 15))
        XCTAssertTrue(app.staticTexts["Alerts are off in this app"].exists)
        XCTAssertFalse(app.buttons["Send Test Alert"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Notification settings after disabling alerts"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await signOutWithoutAccountService()
    }

    private struct HistorySeed: Decodable {
        struct PageInfo: Decodable { let hasOlder: Bool; let olderCursor: String? }
        let count: Int
        let firstMarker: String
        let lastMarker: String
        let firstMessageId: String?
        let lastMessageId: String?
        let pageInfo: PageInfo
    }

    private struct AttachmentSeed: Decodable {
        struct Attachment: Decodable { let id: String; let name: String; let size: Int }
        let messageId: String?
        let attachments: [Attachment]
    }

    private struct Status: Decodable {
        struct Message: Decodable { let id: String; let text: String }
        struct RPC: Decodable { let kind: String; let path: String? }
        struct PromptAnswer: Decodable {
            let cancelled: Bool
            let answerCounts: [String: Int]
            let expectedColor: Bool
            let expectedSizes: Bool
            let freeTextReceived: Bool
            let secretReceived: Bool
        }
        struct ConfirmAnswer: Decodable { let actionId: String?; let sender: String?; let cancelled: Bool }
        struct BrowserAnswer: Decodable { let cancelled: Bool }
        struct BrowserSurface: Decodable { let secretCancels: Int }
        struct Queue: Decodable { let queued: Int; let starting: Int }
        struct FailedTurn: Decodable { let agentId: String; let turnId: String }
        struct Signout: Decodable { let revokeFailures: Int; let rejectedSessionStillActive: Bool }
        let messages: [Message]
        let providerTurns: Int
        let droppedReceipts: Int
        let pendingApprovals: Int
        let pendingPrompts: Int
        let promptAnswers: [PromptAnswer]
        let activeTurnId: String?
        let interruptedTurns: Int
        let rpc: [RPC]
        let paths: [String]
        let confirmAnswers: [ConfirmAnswer]
        let pendingBrowserTakeovers: Int
        let browserAnswers: [BrowserAnswer]
        let browserSurface: BrowserSurface
        let queue: Queue
        let failedTurns: [FailedTurn]
        let signout: Signout
    }
}
