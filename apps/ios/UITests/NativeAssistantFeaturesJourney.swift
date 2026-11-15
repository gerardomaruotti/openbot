import XCTest

/// The headless feature lane owns protocol guards. This journey owns the native forms,
/// presentation, gestures and cancellation paths that those requests cannot exercise.
@MainActor
final class NativeAssistantFeaturesJourney: NativeFixtureCase {
    func testNativeAssistantFeatures() async throws {
        signInAndOpenChat()
        try await submitBrowserSecret()
        try await controlBrowserAndComplete()
        try await cancelBrowserRequest()
        try await cancelCaptureWithoutLosingDraft()
        try await signOutAndCheckRestart()
    }

    func testNativeAgentManagement() async throws {
        signInAndOpenChat()
        try await changeOnlyMyAlerts()
        try await manageSyntheticAgent()
    }

    func testNativeReplies() async throws {
        signInAndOpenChat()
        send("SIM-FEATURE-1")
        reply("SIM-FEATURE-1 received")
        XCTAssertEqual(messageCount("SIM-FEATURE-1"), 1)

        try await addAndRemoveReaction()
        try await selectAndCopyReply()
        try await swipeReplyAndKeepTarget()
    }

    func testNativeRoutineReview() async throws {
        signInAndOpenChat()
        try await manageSyntheticRoutine()
    }

    private func signInAndOpenChat() {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openConnection()
        let email = editable(label: "Email")
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        email.typeText("native-simulator@example.invalid")
        tapButton("Continue")
        tapButton("Connect to Mac")
        openAgentChat("Simulator Agent")
    }

    private func status() async throws -> FeatureStatus {
        try JSONDecoder().decode(FeatureStatus.self, from: await control("status"))
    }

    @discardableResult
    private func waitForStatus(_ reason: String, timeout: TimeInterval = 30,
                               _ condition: (FeatureStatus) -> Bool) async throws -> FeatureStatus {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let value = try await status()
            if condition(value) { return value }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        XCTFail(reason)
        throw JourneyFailure.timedOut
    }

    private func addAndRemoveReaction() async throws {
        let message = textElements("SIM-FEATURE-1 received").firstMatch
        for adding in [true, false] {
            reveal(message, swipingUp: true)
            message.press(forDuration: 0.8)
            let add = contextAction("Add Reaction")
            XCTAssertTrue(add.wait(for: \.isHittable, toEqual: true, timeout: 10),
                          "A live-message long press did not expose its reaction action.")
            XCTAssertTrue(contextAction("Copy").exists, "The reaction menu lost the ordinary copy action.")
            add.tap()
            let reaction = app.buttons["React with 👍"].firstMatch
            XCTAssertTrue(reaction.wait(for: \.isHittable, toEqual: true, timeout: 10))
            reaction.tap()
            if adding {
                let value = try await waitForStatus("The native reaction was not stored by the host.") {
                    $0.features.reactions.count == 1 && $0.features.reactions[0].contains("👍")
                }
                XCTAssertEqual(value.features.reactions.count, 1)
                XCTAssertTrue(app.buttons["1 reactions"].waitForExistence(timeout: 10))
            } else {
                try await waitForStatus("Selecting the same reaction did not remove it.") { $0.features.reactions.isEmpty }
                XCTAssertTrue(app.buttons["1 reactions"].waitForNonExistence(timeout: 10))
            }
        }
    }

    private func selectAndCopyReply() async throws {
        let body = "SIM-FEATURE-1 received"
        let message = textElements(body).firstMatch
        reveal(message, swipingUp: true)
        message.press(forDuration: 0.8)
        let selection = contextAction("Select Text")
        XCTAssertTrue(selection.wait(for: \.isHittable, toEqual: true, timeout: 10))
        selection.tap()
        XCTAssertTrue(app.navigationBars["Select Text"].waitForExistence(timeout: 10))
        XCTAssertTrue(textElements(body).firstMatch.exists, "The selection sheet did not show the complete reply.")
        tapButton("Copy")
        tapButton("Done")
        let composer = app.textFields["message-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.press(forDuration: 0.8)
        let paste = contextAction("Paste")
        XCTAssertTrue(paste.wait(for: \.isHittable, toEqual: true, timeout: 10))
        paste.tap()
        assertValue(composer, value: body, message: "Copy did not put the exact visible reply on the native clipboard.")
        let value = try await status()
        XCTAssertFalse(value.messages.contains { $0.text == body }, "Copy/paste sent a message without Send.")
        // Finish this synthetic exchange through the public send flow. Selection
        // menu mechanics are UIKit-owned and do not reset the next reply scenario.
        tapButton("Send Message")
        try await waitForStatus("The explicit synthetic clipboard send did not complete.") { state in
            guard let sent = state.messages.first(where: { $0.text == body }), let turn = sent.turnId else { return false }
            return state.chatMessages.contains { $0.author == "assistant" && $0.turnId == turn && $0.status == "completed" }
        }
        XCTAssertTrue(app.buttons["Send Message"].waitForNonExistence(timeout: 10))
    }

    private func swipeReplyAndKeepTarget() async throws {
        let parentText = "SIM-FEATURE-1"
        let initial = try await status()
        let parent = try XCTUnwrap(initial.messages.first { $0.text == parentText })
        let parentElement = textElements(parentText).firstMatch
        let composer = app.textFields["message-composer"].firstMatch

        // This is deliberately the native swipe. A context-menu Reply action cannot
        // substitute for a broken horizontal gesture on the actual message.
        reveal(parentElement, swipingUp: false)
        parentElement.swipeRight()
        let close = app.buttons["Close replies"].firstMatch
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "Swiping right on the message did not open focused replies.")
        let replyField = app.textFields.matching(identifier: "message-composer")
            .matching(NSPredicate(format: "placeholderValue == %@", "Reply")).firstMatch
        XCTAssertTrue(replyField.waitForExistence(timeout: 10))
        let cancelledDraft = "SIM-REPLY-CANCEL-DRAFT"
        composer.tap()
        composer.typeText(cancelledDraft)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        assertValue(composer, value: cancelledDraft, message: "Closing replies discarded unsent text.")
        let cancelled = try await status()
        XCTAssertEqual(cancelled.messages.count, initial.messages.count, "Closing replies sent a request.")
        XCTAssertFalse(cancelled.messages.contains { $0.text == cancelledDraft })
        // Explicit sign-out removes this retained test draft. The host conversation
        // remains available on fresh sign-in; the cancelled text must never be sent.
        try await signOutAndCheckRestart()
        signInAndOpenChat()
        let restored = try await status()
        XCTAssertFalse(restored.messages.contains { $0.text == cancelledDraft })
        XCTAssertEqual(restored.messages.count, initial.messages.count)
        XCTAssertTrue(app.buttons["Send Message"].waitForNonExistence(timeout: 10))

        reveal(parentElement, swipingUp: false)
        parentElement.swipeRight()
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("SIM-LINK-1")
        // Read the accepted value without a polling delay before termination. A
        // delayed assertion would hide the old pending-draft-write regression.
        XCTAssertEqual(composer.value as? String, "SIM-LINK-1", "The reply draft was not entered before restart.")
        app.terminate()
        app.launch()
        XCTAssertTrue(close.waitForExistence(timeout: 20), "Restart lost the reply draft's focused target.")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        assertValue(composer, value: "SIM-LINK-1", message: "Restart lost the unsent reply text.")
        let unsent = try await status()
        XCTAssertFalse(unsent.messages.contains { $0.text == "SIM-LINK-1" })

        // The core lane owns generic outbox recovery. This path verifies that a reply
        // target survives its own cached draft and the offline send handoff.
        _ = try await control("offline", post: true)
        tapButton("Send Message")
        XCTAssertTrue(app.staticTexts["Waiting to send"].waitForExistence(timeout: 15))
        XCTAssertTrue(close.exists, "Sending a reply unexpectedly closed its focused thread.")
        _ = try await control("online", post: true)
        reply("SIM-LINK-1 received")
        let delivered = try await waitForStatus("The reply did not retain its exact parent on the real host.") { value in
            let sent = value.messages.filter { $0.text == "SIM-LINK-1" }
            guard sent.count == 1, sent[0].replyToMessageId == parent.id, let turnID = sent[0].turnId else { return false }
            return value.chatMessages.contains {
                $0.turnId == turnID && ["assistant", "agent"].contains($0.author) && $0.text == "SIM-LINK-1 received"
            }
        }
        XCTAssertEqual(delivered.messages.filter { $0.text == "SIM-LINK-1" }.count, 1,
                       "The reply draft or offline send was submitted twice.")
        XCTAssertEqual(messageCount("SIM-LINK-1"), 1)
        XCTAssertEqual(messageCount("SIM-LINK-1 received"), 1)
        XCTAssertTrue(close.exists)
        close.tap()
        let original = app.buttons["Original message"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 15))
        assertValue(original, value: parentText, message: "The reply group points to a different original message.")
        let count = app.buttons["2 Replies"].firstMatch
        reveal(count, swipingUp: true)
        XCTAssertTrue(count.waitForExistence(timeout: 15), "The user reply and its same-turn answer were not grouped together.")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Native reply group"
        evidence.lifetime = .keepAlways
        add(evidence)
        count.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(textElements("SIM-LINK-1 received").firstMatch.exists)
        try await replyToDeliveredAnswer(in: delivered, root: parent)
    }

    private func replyToDeliveredAnswer(in delivered: FeatureStatus, root: FeatureStatus.Message) async throws {
        let firstReply = try XCTUnwrap(delivered.messages.first { $0.text == "SIM-LINK-1" })
        let firstTurnID = try XCTUnwrap(firstReply.turnId)
        let firstAnswer = try XCTUnwrap(delivered.chatMessages.first {
            $0.turnId == firstTurnID && ["assistant", "agent"].contains($0.author)
                && $0.text == "SIM-LINK-1 received" && $0.status == "completed"
        })
        let answerElement = textElements(firstAnswer.text).firstMatch
        reveal(answerElement, swipingUp: true)
        answerElement.press(forDuration: 0.8)
        let replyAction = contextAction("Reply")
        XCTAssertTrue(replyAction.wait(for: \.isHittable, toEqual: true, timeout: 10))
        replyAction.tap()
        let close = app.buttons["Close replies"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(textElements(root.text).firstMatch.exists,
                      "Replying to an answer changed the focused thread's original message.")

        send("SIM-LINK-2")
        let nested = try await waitForStatus("The nested reply did not keep the delivered answer as its exact parent.") { value in
            let sent = value.messages.filter { $0.text == "SIM-LINK-2" }
            guard sent.count == 1, sent[0].replyToMessageId == firstAnswer.id,
                  let turnID = sent[0].turnId else { return false }
            return value.chatMessages.contains {
                $0.turnId == turnID && ["assistant", "agent"].contains($0.author)
                    && $0.text == "SIM-LINK-2 received" && $0.status == "completed"
            }
        }
        XCTAssertEqual(nested.messages.filter { $0.text == "SIM-LINK-2" }.count, 1)
        let nestedBody = textElements("SIM-LINK-2").firstMatch
        let nestedAnswer = textElements("SIM-LINK-2 received").firstMatch
        let bodyAppeared = nestedBody.waitForExistence(timeout: 15)
        let answerAppeared = nestedAnswer.waitForExistence(timeout: 15)
        if !bodyAppeared || !answerAppeared {
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "Missing nested reply in focused root"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(bodyAppeared, "The nested user reply disappeared from its original focused thread.")
        XCTAssertTrue(answerAppeared, "The nested same-turn answer disappeared from its original focused thread.")
        XCTAssertTrue(close.exists)
        XCTAssertTrue(textElements(root.text).firstMatch.exists)
        XCTAssertEqual(messageCount("SIM-LINK-2"), 1)
        XCTAssertEqual(messageCount("SIM-LINK-2 received"), 1)
        reveal(nestedBody, swipingUp: true)
        XCTAssertTrue(nestedBody.isHittable)
        reveal(nestedAnswer, swipingUp: true)
        XCTAssertTrue(nestedAnswer.isHittable)
        close.tap()
        let originals = app.buttons.matching(NSPredicate(format: "label == %@", "Original message"))
        XCTAssertTrue(originals.firstMatch.waitForExistence(timeout: 10))
        for original in originals.allElementsBoundByIndex {
            XCTAssertEqual(original.value as? String, root.text)
        }
        // The main timeline may split one thread into chronological clusters.
        // Its loaded counts must still include both user replies and both answers.
        let counts = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+ Repl(y|ies)$"))
        let loadedReplies = counts.allElementsBoundByIndex.reduce(0) {
            $0 + (Int($1.label.split(separator: " ").first ?? "") ?? 0)
        }
        XCTAssertEqual(loadedReplies, 4, "The loaded reply groups omitted or duplicated a nested message.")
    }

    private func changeOnlyMyAlerts() async throws {
        let baseline = try await status()
        let agent = try XCTUnwrap(baseline.features.agents.first { $0.name == "Simulator Agent" })
        tapButton("Simulator Agent")
        let toggle = app.switches["Hide Alerts"].firstMatch
        reachForm(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        let muted = try await waitForStatus("Hide Alerts did not change this member's preference.") {
            $0.features.preferences.agents.contains { $0.agentId == agent.id && $0.level == "nothing" }
        }
        XCTAssertEqual(muted.features.preferences.server, baseline.features.preferences.server)
        XCTAssertEqual(muted.features.agents.first { $0.id == agent.id }?.notifications, agent.notifications,
                       "A member mute changed the agent's global notification setting.")
        assertValue(toggle, value: "1")
        toggle.tap()
        let restored = try await waitForStatus("Unmuting did not remove this member's override.") {
            !$0.features.preferences.agents.contains { $0.agentId == agent.id && $0.level == "nothing" }
        }
        XCTAssertEqual(restored.features.preferences.server, baseline.features.preferences.server)
        XCTAssertEqual(restored.features.agents.first { $0.id == agent.id }?.notifications, agent.notifications)
        assertValue(toggle, value: "0")
        tapButton("Back")
    }

    private func manageSyntheticAgent() async throws {
        let originalName = "Synthetic Native Agent"
        let editedName = "Synthetic Native Agent Edited"
        let instructions = "Only use synthetic simulator data."
        tapButton("Back")
        openListMenu("Agents")
        tapButton("New Agent")
        typeInto(id: "agent-name", text: originalName)
        typeInto(id: "agent-instructions", text: instructions)
        typeInto(id: "agent-first-message", text: "SIM-NEW-1")
        tapButton(id: "agent-save")
        let created = try await waitForStatus("The native agent form did not create an agent.") {
            $0.features.agents.contains { $0.name == originalName && $0.instructionsLength == instructions.count }
        }
        let agent = try XCTUnwrap(created.features.agents.first { $0.name == originalName })
        reply("SIM-NEW-1 received")
        tapButton("Back")
        openListMenu("Agents")
        tapRow(containing: originalName)
        replace(id: "agent-name", old: originalName, with: editedName)
        replace(id: "agent-title", old: agent.title, with: "Synthetic native UI role")
        replace(id: "agent-instructions", old: instructions, with: instructions + " Keep this agent paused unless asked.")
        tapButton(id: "agent-save")
        try await waitForStatus("The native agent editor did not save its changes.") {
            $0.features.agents.contains { $0.id == agent.id && $0.name == editedName && $0.title == "Synthetic native UI role" && $0.instructionsLength > instructions.count }
        }
        tapRow(containing: editedName)
        tapButton("Delete Agent")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", editedName, "This cannot be undone."
        )).firstMatch.waitForExistence(timeout: 10), "The destructive agent warning was not shown.")
        confirm(title: "Delete this agent?", action: "Delete Agent")
        try await waitForStatus("The confirmed native delete did not remove the synthetic agent.") {
            !$0.features.agents.contains { $0.id == agent.id }
        }
        tapButton("Done")
        openAgentChat("Simulator Agent")
    }

    private func manageSyntheticRoutine() async throws {
        let name = "Synthetic Native Routine"
        let editedName = "Synthetic Native Routine Edited"
        tapButton("Simulator Agent")
        tapButton("Routines")
        tapButton("New Routine")
        typeInto(id: "routine-name", text: name)
        typeInto(id: "routine-instruction", text: "SIM-ROUTINE-1")
        XCTAssertEqual(app.switches["routine-active"].value as? String, "0", "A new routine must start paused.")
        tapButton(id: "routine-save")
        let created = try await waitForStatus("The native routine form did not save a paused routine.") {
            $0.features.routines.contains { $0.name == name && !$0.active && $0.schedule?.kind == "daily" }
        }
        let routine = try XCTUnwrap(created.features.routines.first { $0.name == name })
        tapRow(containing: name)
        tapButton("Edit")
        replace(id: "routine-name", old: name, with: editedName)
        let frequency = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Repeat")).firstMatch
        reachForm(frequency)
        frequency.tap()
        tapButton("Hourly")
        tapButton(id: "routine-save")
        try await waitForStatus("The native routine editor did not save the new schedule.") {
            $0.features.routines.contains { $0.id == routine.id && $0.name == editedName && $0.schedule?.kind == "hourly" && !$0.active }
        }
        tapButton("Resume")
        try await waitForStatus("Resume did not activate the actual routine.") {
            $0.features.routines.contains { $0.id == routine.id && $0.active }
        }
        tapButton("Pause")
        try await waitForStatus("Pause did not stop future scheduled runs.") {
            $0.features.routines.contains { $0.id == routine.id && !$0.active }
        }
        tapButton(id: "routine-run")
        let completed = try await waitForStatus("The real manual routine never completed successfully.", timeout: 60) {
            $0.features.routines.first { $0.id == routine.id }?.runs.contains { $0.kind == "manual" && $0.status == "succeeded" } == true
        }
        XCTAssertEqual(completed.features.routines.first { $0.id == routine.id }?.runs.filter { $0.kind == "manual" }.count, 1,
                       "One Run Now tap started duplicate manual runs.")
        tapButton("Refresh Runs")
        let completedLabel = app.staticTexts["Completed"].firstMatch
        reachForm(completedLabel)
        XCTAssertTrue(completedLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Manual"].exists)
        try await reviewUnconfirmedRun(routineID: routine.id)
        tapButton("Delete Routine")
        confirm(title: "Delete this routine and stop its future scheduled runs?", action: "Delete Routine")
        try await waitForStatus("Confirmed routine deletion did not remove the actual routine.") {
            !$0.features.routines.contains { $0.id == routine.id }
        }
        tapButton("Done")
        tapButton("Back")
        reply("SIM-ROUTINE-1 received")
    }

    private func reviewUnconfirmedRun(routineID: String) async throws {
        let baseline = try await status()
        let earlier = try XCTUnwrap(baseline.features.routines.first { $0.id == routineID })
        let priorIDs = Set(earlier.runs.filter { $0.kind == "manual" }.map(\.id))
        XCTAssertEqual(priorIDs.count, 1)
        _ = try await control("routines/drop-manual-response", post: true)
        tapButton(id: "routine-run")
        let committed = try await waitForStatus("The dropped receipt did not name one actual completed manual run.", timeout: 60) { value in
            value.routineFaults.droppedManualResponses == baseline.routineFaults.droppedManualResponses + 1 &&
            value.routineFaults.droppedManualRuns.contains { dropped in
                dropped.routineId == routineID && !priorIDs.contains(dropped.runId) &&
                value.features.routines.first { $0.id == routineID }?.runs.contains { $0.id == dropped.runId && $0.kind == "manual" && $0.status == "succeeded" } == true
            }
        }
        let dropped = try XCTUnwrap(committed.routineFaults.droppedManualRuns.last { $0.routineId == routineID })
        let expectedIDs = priorIDs.union([dropped.runId])
        XCTAssertEqual(expectedIDs.count, 2)
        XCTAssertTrue(committed.routineFaults.runsReadbackBlocked)

        let runNow = app.buttons["routine-run"].firstMatch
        let refreshRuns = app.buttons["Refresh Runs"].firstMatch
        let review = app.buttons["Refresh routines"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 20), "An unconfirmed run did not expose explicit review.")
        XCTAssertTrue(app.staticTexts["Something went wrong."].firstMatch.waitForExistence(timeout: 10),
                      "The explicit unconfirmed Run Now action did not receive generic feedback.")
        reachForm(refreshRuns)
        // This control is disabled only while busy/offline. Its enabled state makes the
        // disabled Run Now assertion about review, rather than a lost connection.
        XCTAssertTrue(refreshRuns.wait(for: \.isEnabled, toEqual: true, timeout: 30))
        XCTAssertFalse(runNow.isEnabled)
        let failuresBefore = try await status().routineFaults.failedRunReadbacks
        refreshRuns.tap()
        try await waitForStatus("Refresh Runs did not reach the real blocked history route.") {
            $0.routineFaults.failedRunReadbacks > failuresBefore
        }
        XCTAssertTrue(refreshRuns.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        XCTAssertTrue(review.exists)
        XCTAssertFalse(runNow.isEnabled, "A failed history read cleared the unconfirmed-run review guard.")

        // Even the explicit acknowledgement cannot succeed while required history fails.
        let failedReviewBefore = try await status().routineFaults.failedRunReadbacks
        tapButton("Refresh routines")
        try await waitForStatus("Explicit review did not require the missing run history.") {
            $0.routineFaults.failedRunReadbacks > failedReviewBefore
        }
        XCTAssertTrue(refreshRuns.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        XCTAssertTrue(review.exists)
        XCTAssertFalse(runNow.isEnabled)

        _ = try await control("routines/runs-readback", post: true)
        tapButton("Refresh Runs")
        let secondCompleted = app.staticTexts.matching(NSPredicate(format: "label == %@", "Completed")).element(boundBy: 1)
        reachForm(secondCompleted)
        XCTAssertTrue(secondCompleted.exists, "Fresh native history did not show both completed runs.")
        reachForm(review, towardEnd: true)
        XCTAssertTrue(review.exists)
        reachForm(runNow, towardEnd: false)
        XCTAssertFalse(runNow.isEnabled, "Refreshing history silently acknowledged the global review requirement.")
        reachForm(review, towardEnd: true)
        tapButton("Refresh routines")
        reachForm(runNow, towardEnd: false)
        XCTAssertTrue(runNow.wait(for: \.isEnabled, toEqual: true, timeout: 20))
        XCTAssertTrue(review.waitForNonExistence(timeout: 10))
        let checked = try await status()
        let actualIDs = Set(try XCTUnwrap(checked.features.routines.first { $0.id == routineID }).runs.filter { $0.kind == "manual" }.map(\.id))
        XCTAssertEqual(actualIDs, expectedIDs, "Run receipt recovery started a duplicate manual run.")
        XCTAssertEqual(checked.routineFaults.droppedManualResponses, baseline.routineFaults.droppedManualResponses + 1)
    }

    private func submitBrowserSecret() async throws {
        let before = try await status()
        send("SIM-BROWSER")
        openBrowser()
        let field = app.secureTextFields["Password"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        privateAnswerInFlight = true
        defer { privateAnswerInFlight = false }
        field.tap()
        field.typeText("NATIVE-SYNTHETIC-ONLY")
        tapButton("Submit securely")
        try await waitForStatus("The secure native form did not reach the actual secret adapter.") {
            $0.browserSurface.secretSubmitted == before.browserSurface.secretSubmitted + 1 && $0.pendingBrowserTakeovers == 0
        }
        XCTAssertTrue(app.staticTexts["This browser request has ended."].waitForExistence(timeout: 15))
        XCTAssertFalse(field.exists)
        dismissOptionalPasswordOffer()
        tapButton("Close")
        reply("SIM-BROWSER resolved")
    }

    private func controlBrowserAndComplete() async throws {
        let before = try await status()
        send("SIM-BROWSER-RELOAD")
        openBrowser()
        tapButton("Open browser instead")
        let image = app.images["Browser page"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 20), "The native browser never displayed an actual host frame.")
        try await waitForStatus("The real browser view did not start or send frames.") {
            $0.browserSurface.viewsStarted > before.browserSurface.viewsStarted && $0.browserSurface.frames > before.browserSurface.frames
        }
        reachForm(image)
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.405)).tap()
        try await waitForStatus("The normalized native tap did not click the real page button.") {
            $0.browserSurface.pageClicks > before.browserSurface.pageClicks
        }
        // These fractions identify the harmless fixture page's notes field in its 1280x800 frame.
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.615)).tap()
        let field = editable(label: "Text for the focused field")
        reachForm(field)
        field.tap()
        field.typeText("SYNTHETIC-NATIVE-INPUT")
        tapButton("Send text")
        try await waitForStatus("Native typed text did not reach the real page field.") {
            $0.browserSurface.pageTextLength >= "SYNTHETIC-NATIVE-INPUT".count
        }
        tapButton("Return")
        try await waitForStatus("The native Return control did not send a real page key.") {
            $0.browserSurface.pageKeys > before.browserSurface.pageKeys
        }
        tapButton("Scroll down")
        try await waitForStatus("The native scroll control did not scroll the real page.") {
            $0.browserSurface.pageWheels > before.browserSurface.pageWheels
        }
        tapButton("I completed this step")
        confirm(title: "Give control back to the agent?", action: "I completed this step")
        try await waitForStatus("The explicit native completion did not resolve the browser request.") {
            $0.pendingBrowserTakeovers == 0 && $0.browserSurface.completedTakeovers > before.browserSurface.completedTakeovers &&
            $0.browserSurface.viewsStopped > before.browserSurface.viewsStopped
        }
        XCTAssertTrue(app.staticTexts["This browser request has ended."].waitForExistence(timeout: 15))
        tapButton("Close")
        reply("SIM-BROWSER resolved")
        XCTAssertEqual(messageCount("SIM-BROWSER-RELOAD"), 1)
    }

    private func cancelBrowserRequest() async throws {
        let before = try await status()
        send("SIM-BROWSER-RELOAD")
        openBrowser()
        tapButton("Open browser instead")
        XCTAssertTrue(app.images["Browser page"].firstMatch.waitForExistence(timeout: 20))
        tapButton("Cancel request")
        confirm(title: "Cancel this browser request?", action: "Cancel request")
        try await waitForStatus("The native cancel did not resolve its exact request and close the view.") {
            $0.pendingBrowserTakeovers == 0 && $0.browserAnswers.filter(\.cancelled).count > before.browserAnswers.filter(\.cancelled).count &&
            $0.browserSurface.viewsStopped > before.browserSurface.viewsStopped
        }
        tapButton("Close")
        reply("SIM-BROWSER cancelled")
    }

    private func cancelCaptureWithoutLosingDraft() async throws {
        let draft = "SIM-CAPTURE-DRAFT"
        let composer = app.textFields["message-composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText(draft)
        app.resetAuthorizationStatus(for: .camera)
        tapButton("Add Attachment")
        tapButton("Camera")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cameraMessages = [
            "A camera is not available. You can choose a photo or a file instead.",
            "Allow camera access in Settings to take a photo.",
            "Camera access is restricted on this device."
        ]
        let cameraDeadline = Date().addingTimeInterval(25)
        var cameraUnavailable = false
        repeat {
            let denial = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
            if denial.exists && denial.isHittable { denial.tap() }
            if app.staticTexts.matching(NSPredicate(format: "label IN %@", cameraMessages)).firstMatch.exists {
                cameraUnavailable = true
                break
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < cameraDeadline
        XCTAssertTrue(cameraUnavailable, "Camera did not show its denied or unavailable state.")
        tapButton("Cancel")
        XCTAssertEqual(composer.value as? String, draft)

        // XCTest can reset this isolated app's microphone permission. Speech starts with
        // this run's fresh bundle identity. Never allow either system permission prompt.
        app.resetAuthorizationStatus(for: .microphone)
        tapButton("Dictate a message")
        let deniedMessages = [
            "Allow speech recognition in Settings to dictate a message.",
            "Speech recognition is restricted on this device.",
            "On-device dictation is unavailable for this language. You can type your message instead.",
            "Allow microphone access in Settings to dictate a message.",
            "A microphone is not available."
        ]
        let deadline = Date().addingTimeInterval(25)
        var deniedOrUnavailable = false
        repeat {
            if app.buttons["dictation.stop"].exists {
                tapButton("Cancel")
                XCTFail("Dictation started recording instead of staying denied or unavailable.")
                throw JourneyFailure.unexpectedRecording
            }
            let denial = NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])
            let systemDeny = springboard.alerts.buttons.matching(denial).firstMatch
            let appDeny = app.alerts.buttons.matching(denial).firstMatch
            if systemDeny.exists && systemDeny.isHittable { systemDeny.tap() }
            else if appDeny.exists && appDeny.isHittable { appDeny.tap() }
            deniedOrUnavailable = deniedMessages.contains { app.staticTexts[$0].exists }
            if deniedOrUnavailable { break }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        XCTAssertTrue(deniedOrUnavailable, "No denied or unavailable dictation state appeared.")
        XCTAssertFalse(app.buttons["dictation.insert"].isEnabled)
        tapButton("Cancel")
        XCTAssertEqual(composer.value as? String, draft)
        let value = try await status()
        XCTAssertFalse(value.messages.contains { $0.text == draft }, "Cancelling capture submitted the draft.")
    }

    private func signOutAndCheckRestart() async throws {
        tapButton("Back")
        openConnection()
        XCTAssertTrue(app.staticTexts["native-simulator@example.invalid"].waitForExistence(timeout: 15))
        tapButton("Sign Out")
        confirm(title: "Sign out on this iPhone?", action: "Sign Out")
        XCTAssertTrue(editable(label: "Email").waitForExistence(timeout: 15))
        let value = try await status()
        XCTAssertEqual(value.signout.revokeFailures, 0)
        XCTAssertGreaterThan(value.signout.revokeAttempts, 0)
        XCTAssertEqual(value.pendingBrowserTakeovers, 0)
        XCTAssertFalse(value.messages.contains { $0.text == "SIM-CAPTURE-DRAFT" })
        tapButton("Done")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Simulator Agent")).firstMatch.exists)
        app.terminate()
        app.launch()
        openConnection()
        XCTAssertTrue(editable(label: "Email").waitForExistence(timeout: 15), "Restart restored a signed-out account.")
        XCTAssertFalse(app.buttons["Sign Out"].exists)
        tapButton("Done")
    }

    private func openBrowser() {
        let button = app.buttons["Open browser"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        reveal(button, swipingUp: true)
        button.tap()
        XCTAssertTrue(app.navigationBars["Browser"].waitForExistence(timeout: 15))
    }

    private func openAgentChat(_ name: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 40))
        row.tap()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 15))
    }

    private func openListMenu(_ item: String) { tapButton("Edit"); tapButton(item) }

    private func contextAction(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %@ OR elementType == %@) AND label == %@",
            NSNumber(value: XCUIElement.ElementType.menuItem.rawValue),
            NSNumber(value: XCUIElement.ElementType.button.rawValue), title
        )).firstMatch
    }

    private func assertValue(_ element: XCUIElement, value: String, message: String = "A native value did not update.") {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed, message)
    }

    private func tapRow(containing text: String) {
        // Native List cells have no raw XCTest label. Scope their named buttons to
        // the foremost list so a covered conversation row cannot match first.
        let lists = app.collectionViews.allElementsBoundByIndex
        guard let list = lists.last(where: { $0.isHittable && $0.frame.intersection(app.frame).height > 120 }) ?? lists.last else {
            XCTFail("The native management list was not present.")
            return
        }
        let row = list.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        reachForm(row)
        row.tap()
    }

    private func editable(id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %@ OR elementType == %@ OR elementType == %@) AND identifier == %@",
            NSNumber(value: XCUIElement.ElementType.textField.rawValue), NSNumber(value: XCUIElement.ElementType.textView.rawValue),
            NSNumber(value: XCUIElement.ElementType.secureTextField.rawValue), id
        )).firstMatch
    }

    private func editable(label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %@ OR elementType == %@) AND (label == %@ OR placeholderValue == %@)",
            NSNumber(value: XCUIElement.ElementType.textField.rawValue), NSNumber(value: XCUIElement.ElementType.textView.rawValue), label, label
        )).firstMatch
    }

    private func typeInto(id: String, text: String) {
        let field = editable(id: id)
        reachForm(field)
        field.tap()
        field.typeText(text)
    }

    private func replace(id: String, old: String, with text: String) {
        let field = editable(id: id)
        reachForm(field)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }

    private func tapButton(_ label: String) {
        // Match the visible label, rather than a keyboard identifier with the same name.
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let button = matches.allElementsBoundByIndex.first(where: \.isHittable) ?? matches.firstMatch
        reachForm(button)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        button.tap()
    }

    private func tapButton(id: String) {
        let button = app.buttons.matching(identifier: id).firstMatch
        reachForm(button)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15))
        button.tap()
    }

    private func confirm(title: String, action: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "The native confirmation was not presented.")
        let buttons = app.buttons.matching(NSPredicate(format: "label == %@", action))
        XCTAssertGreaterThan(buttons.count, 0)
        let button = buttons.element(boundBy: max(0, buttons.count - 1))
        XCTAssertTrue(button.wait(for: \.isHittable, toEqual: true, timeout: 10))
        button.tap()
    }

    private func reachForm(_ element: XCUIElement, towardEnd: Bool? = nil) {
        if element.wait(for: \.isHittable, toEqual: true, timeout: 3) { return }
        let candidates = app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
        guard let scroll = candidates.first(where: { $0.isHittable && $0.frame.intersection(app.frame).height > 120 }) else {
            XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 15), "A native control was not reachable.")
            return
        }
        for _ in 0..<14 {
            if element.exists && element.isHittable { return }
            let top = max(scroll.frame.minY + 40, 120)
            let bottom = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY - 24 : min(scroll.frame.maxY - 30, app.frame.maxY - 70)
            let middle = (top + bottom) / 2
            let later = towardEnd ?? (!element.exists || element.frame.midY >= middle)
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let startY = top + (bottom - top) * (later ? 0.82 : 0.20)
            let endY = top + (bottom - top) * (later ? 0.35 : 0.65)
            let start = origin.withOffset(CGVector(dx: scroll.frame.width / 2, dy: startY - scroll.frame.minY))
            let end = origin.withOffset(CGVector(dx: scroll.frame.width / 2, dy: endY - scroll.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let reached = element.exists && element.isHittable
        if !reached {
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "Native form target"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(reached, "A native form control could not be reached. " + element.debugDescription + "\n" + app.debugDescription)
    }

    private func dismissOptionalPasswordOffer() {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let notNow = system.buttons["Not Now"].firstMatch
        if notNow.exists && notNow.isHittable { notNow.tap() }
    }

    private enum JourneyFailure: Error { case timedOut, unexpectedRecording }

    private struct FeatureStatus: Decodable {
        struct Message: Decodable {
            let id: String; let text: String; let replyToMessageId: String?; let turnId: String?
        }
        struct ChatMessage: Decodable {
            let id: String; let text: String; let author: String; let turnId: String?; let replyToMessageId: String?
            let itemType: String?; let status: String
        }
        struct Agent: Decodable {
            let id: String; let name: String; let title: String; let instructionsLength: Int; let notifications: Bool
        }
        struct Routine: Decodable {
            struct Schedule: Decodable { let kind: String }
            struct Run: Decodable { let id: String; let status: String; let kind: String }
            let id: String; let agentId: String; let name: String; let active: Bool; let schedule: Schedule?; let runs: [Run]
        }
        struct Preferences: Decodable {
            struct Level: Decodable { let agentId: String; let level: String }
            let server: String?; let agents: [Level]
        }
        struct Reaction: Decodable {
            struct Entry: Decodable { let emoji: String }
            let id: String; let reaction: String?; let reactions: [Entry]?
            func contains(_ emoji: String) -> Bool { reaction == emoji || reactions?.contains { $0.emoji == emoji } == true }
        }
        struct Features: Decodable {
            let agents: [Agent]; let routines: [Routine]; let preferences: Preferences; let reactions: [Reaction]
        }
        struct BrowserSurface: Decodable {
            let secretSubmitted: Int; let completedTakeovers: Int; let viewsStarted: Int; let viewsStopped: Int
            let frames: Int; let pageClicks: Int; let pageKeys: Int; let pageWheels: Int; let pageTextLength: Int
        }
        struct BrowserAnswer: Decodable { let cancelled: Bool }
        struct RoutineFaults: Decodable {
            struct DroppedRun: Decodable { let agentId: String; let routineId: String; let runId: String }
            let droppedManualResponses: Int; let droppedManualRuns: [DroppedRun]
            let runsReadbackBlocked: Bool; let failedRunReadbacks: Int
        }
        struct Signout: Decodable { let revokeAttempts: Int; let revokeFailures: Int }
        let messages: [Message]; let chatMessages: [ChatMessage]; let features: Features; let browserSurface: BrowserSurface
        let pendingBrowserTakeovers: Int; let browserAnswers: [BrowserAnswer]; let signout: Signout; let routineFaults: RoutineFaults
    }
}
