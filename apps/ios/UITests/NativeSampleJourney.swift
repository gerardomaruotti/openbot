import XCTest

/// Samples use the same native menu and projection as connected chats. They
/// must support reversible reactions without submitting a host request.
@MainActor
final class NativeSampleJourney: NativeFixtureCase {
    func testContextPreviewAndEdgeNavigation() async throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let before = try await hostStatus()
        app.buttons["Edit"].tap()
        let restore = app.buttons["Restore Sample Conversations"]
        XCTAssertTrue(restore.wait(for: \.isHittable, toEqual: true, timeout: 10))
        restore.tap()
        openSample()

        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let field = app.textFields["message-composer"]
        let draft = "LOCAL-EDGE-DRAFT"
        field.tap()
        field.typeText(draft)
        XCTAssertEqual(field.value as? String, draft)
        let edge = origin.withOffset(CGVector(dx: window.minX + 2, dy: window.midY * 0.85))
        let short = origin.withOffset(CGVector(dx: window.minX + 28, dy: window.midY * 0.85))
        edge.press(forDuration: 0.05, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10), "A cancelled edge drag left the conversation.")
        XCTAssertEqual(field.value as? String, draft)
        XCTAssertFalse(app.buttons["Close replies"].exists, "An edge drag selected a message reply.")

        let end = origin.withOffset(CGVector(dx: window.maxX - 30, dy: window.midY * 0.85))
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Atlas,")).firstMatch
        let returned = row.wait(for: \.isHittable, toEqual: true, timeout: 10)
        captureContext("Completed edge back gesture")
        XCTAssertTrue(returned, "A swipe from the screen edge did not return to the bot list.")
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        openSample()
        XCTAssertEqual(field.value as? String, draft, "Back navigation lost the unsent draft.")
        let send = app.buttons["Send Message"]
        XCTAssertTrue(send.wait(for: \.isHittable, toEqual: true, timeout: 10))
        send.tap()

        let message = textElements(draft).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let startX = max(window.minX + 44, min(message.frame.midX, window.maxX - 140))
        let start = origin.withOffset(CGVector(dx: startX, dy: message.frame.midY))
        let replyEnd = origin.withOffset(CGVector(dx: startX + 105, dy: message.frame.midY))
        start.press(forDuration: 0.05, thenDragTo: replyEnd)
        let close = app.buttons["Close replies"]
        XCTAssertTrue(close.wait(for: \.isHittable, toEqual: true, timeout: 10), "An interior message swipe did not open Reply.")
        XCTAssertTrue(textElements(draft).firstMatch.exists)
        captureContext("Interior message reply gesture")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))

        let longMessage = (1...14).map {
            "Context preview paragraph \($0). Keep this long message readable and wrap its lines without squeezing the conversation into a narrow strip."
        }.joined(separator: "\n\n")
        self.send(longMessage)
        let longBody = textElements(longMessage).firstMatch
        XCTAssertTrue(longBody.waitForExistence(timeout: 10))
        let visibleY = min(field.frame.minY - 50, window.midY)
        origin.withOffset(CGVector(dx: longBody.frame.midX, dy: visibleY)).press(forDuration: 0.8)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(copy.wait(for: \.isHittable, toEqual: true, timeout: 10))
        captureContext("Long individual message context menu")
        origin.withOffset(CGVector(dx: window.minX + 3, dy: window.midY)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 10))
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 10), "Edge back stopped working immediately after the message menu closed.")
        XCTAssertFalse(app.buttons["Close replies"].exists, "The post-message-menu edge swipe selected a reply.")
        row.press(forDuration: 0.8)
        let pin = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pin")).firstMatch
        XCTAssertTrue(pin.wait(for: \.isHittable, toEqual: true, timeout: 10))
        captureContext("Long conversation context preview")
        // UIKit hosts SwiftUI preview content in a separate coordinate space.
        // Its visible native container reports the actual screen bounds.
        let preview = app.otherElements.matching(NSPredicate(format: "label == %@", "Preview")).firstMatch
        XCTAssertTrue(preview.wait(for: \.isHittable, toEqual: true, timeout: 10), "The conversation menu has no visible preview.")
        let bounds = preview.frame
        XCTAssertGreaterThan(bounds.width, window.width * 0.55, "The preview was squeezed into a narrow strip.")
        XCTAssertLessThanOrEqual(bounds.width, window.width)
        XCTAssertGreaterThan(bounds.height, 100)
        XCTAssertLessThanOrEqual(bounds.height, window.height * 0.75, "The preview left no room for its context actions.")
        XCTAssertGreaterThanOrEqual(bounds.minX, window.minX - 2)
        XCTAssertLessThanOrEqual(bounds.maxX, window.maxX + 2)
        XCTAssertGreaterThanOrEqual(bounds.minY, window.minY - 2)
        XCTAssertLessThanOrEqual(bounds.maxY, window.maxY + 2)

        origin.withOffset(CGVector(dx: window.minX + 3, dy: window.maxY - 120)).tap()
        XCTAssertTrue(pin.waitForNonExistence(timeout: 10))
        openSample()
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 10), "Edge back stopped working after context menus were dismissed.")
        XCTAssertFalse(app.buttons["Close replies"].exists, "The post-menu edge swipe selected a reply.")

        let after = try await hostStatus()
        XCTAssertEqual(after.messages, before.messages, "A sample gesture changed the host transcript.")
        XCTAssertEqual(after.providerTurns, before.providerTurns, "A sample gesture started a provider turn.")
    }

    func testSampleReactionAndRestart() async throws {
        continueAfterFailure = false
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let before = try await hostStatus()
        app.buttons["Edit"].tap()
        let restore = app.buttons["Restore Sample Conversations"]
        XCTAssertTrue(restore.wait(for: \.isHittable, toEqual: true, timeout: 10))
        restore.tap()
        openSample()
        let body = "For this sample dinner plan, compare a quiet cafe, a garden restaurant and a small neighbourhood bistro."
        let badge = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "React with 🩷")).firstMatch
        for adding in [true, false] {
            let message = textElements(body).firstMatch
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            message.press(forDuration: 0.8)
            let add = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Add Reaction")).firstMatch
            XCTAssertTrue(add.wait(for: \.isHittable, toEqual: true, timeout: 10),
                          "The sample message menu does not expose its reaction action.")
            add.tap()
            let pink = app.buttons["React with 🩷"].firstMatch
            XCTAssertTrue(pink.wait(for: \.isHittable, toEqual: true, timeout: 10))
            pink.tap()
            XCTAssertTrue(pink.waitForNonExistence(timeout: 10))
            if adding {
                XCTAssertTrue(badge.waitForExistence(timeout: 10))
                app.terminate()
                app.launch()
                openSample()
                XCTAssertTrue(badge.waitForExistence(timeout: 10), "Restart lost the saved sample reaction.")
            } else { XCTAssertTrue(badge.waitForNonExistence(timeout: 10)) }
        }
        let marker = "LOCAL-SAMPLE-REACTION-1"
        send(marker)
        XCTAssertTrue(textElements(marker).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(messageCount(marker), 1)
        let after = try await hostStatus()
        XCTAssertEqual(after.messages, before.messages, "A sample action changed the host transcript.")
        XCTAssertEqual(after.providerTurns, before.providerTurns, "A sample action started a provider turn.")
    }

    private func openSample() {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Atlas,")).firstMatch
        XCTAssertTrue(row.wait(for: \.isHittable, toEqual: true, timeout: 15))
        row.tap()
        XCTAssertTrue(app.textFields["message-composer"].waitForExistence(timeout: 10))
    }

    private func captureContext(_ name: String) {
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    private func hostStatus() async throws -> HostStatus {
        try JSONDecoder().decode(HostStatus.self, from: await control("status"))
    }

    private struct HostStatus: Decodable {
        struct Message: Decodable, Equatable { let id: String; let text: String }
        let messages: [Message]
        let providerTurns: Int
    }
}
