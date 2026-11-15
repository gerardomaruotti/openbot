import XCTest

@MainActor
class NativeFixtureCase: XCTestCase {
    let app = XCUIApplication()
    var privateAnswerInFlight = false

    var fixtureURL: URL {
        get throws {
            let value = try XCTUnwrap(Bundle(for: Self.self).object(forInfoDictionaryKey: "NativeFixtureURL") as? String)
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(url.host, "127.0.0.1")
            return url
        }
    }

    func control(_ path: String, post: Bool = false) async throws -> Data {
        var request = URLRequest(url: try fixtureURL.appending(path: "_control/" + path))
        request.httpMethod = post ? "POST" : "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))
        return data
    }

    func openConnection() {
        app.buttons["Edit"].tap()
        let item = app.buttons["Mac Connection"]
        XCTAssertTrue(item.wait(for: \.isHittable, toEqual: true, timeout: 10))
        item.tap()
        let form = app.navigationBars["Mac Connection"]
        if !form.waitForExistence(timeout: 3) && item.exists && item.isHittable {
            // A menu tap can precede its final position during the system presentation.
            // Retry this one transition only while the same menu is still visible.
            item.tap()
        }
        XCTAssertTrue(form.waitForExistence(timeout: 10), app.debugDescription)
    }

    func send(_ text: String) {
        let field = app.textFields.matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(text)
        let send = app.buttons["Send Message"]
        let ready = send.wait(for: \.isHittable, toEqual: true, timeout: 10)
        if !ready && !privateAnswerInFlight {
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "Composer send action is not reachable"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(ready)
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    func textElements(_ text: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %@ AND label == %@) OR (elementType == %@ AND value == %@)",
            NSNumber(value: XCUIElement.ElementType.staticText.rawValue), text,
            NSNumber(value: XCUIElement.ElementType.textView.rawValue), text
        ))
    }

    func messageCount(_ text: String) -> Int {
        // UITextView exposes its body as value; its nested text layout node can
        // repeat the label. Count the body once without hiding duplicate bubbles.
        let views = app.textViews.matching(NSPredicate(format: "value == %@", text))
        return views.count > 0 ? views.count : app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count
    }

    func reply(_ text: String) {
        let found = textElements(text).firstMatch.waitForExistence(timeout: 45)
        if !found && !privateAnswerInFlight {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Missing reply"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(found, privateAnswerInFlight ? "Missing reply after private answer submission." : "Missing reply: " + text + "\n" + app.debugDescription)
        XCTAssertFalse(textElements("SIM-COMMENTARY-HIDDEN").firstMatch.exists)
    }

    func reveal(_ element: XCUIElement, swipingUp: Bool, requiresInteraction: Bool = true) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 15))
        for _ in 0..<20 {
            let header = app.buttons["Simulator Agent"]
            let composer = app.textFields.matching(identifier: "message-composer").firstMatch
            let top = header.exists ? header.frame.maxY + 12 : scroll.frame.minY + 72
            let bottom = composer.exists ? composer.frame.minY - 12 : scroll.frame.maxY - 20
            var later = swipingUp
            if element.exists {
                let middle = element.frame.midY
                if !requiresInteraction || (element.isHittable && middle > top && middle < bottom) { return }
                if middle < top { later = false }
                else if middle > bottom { later = true }
            }
            // A full-height swipe can skip the entire area between the floating
            // bars. Use shorter drags inside that area, including during restore.
            let distance = max(50, min(220, (bottom - top) * 0.45))
            let middle = (top + bottom) / 2
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: scroll.frame.width / 2, dy: middle + (later ? distance / 2 : -distance / 2) - scroll.frame.minY))
            let end = origin.withOffset(CGVector(dx: scroll.frame.width / 2, dy: middle + (later ? -distance / 2 : distance / 2) - scroll.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        if !privateAnswerInFlight {
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "Conversation content could not be reached"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(element.exists && (!requiresInteraction || element.isHittable), "The requested conversation content could not be reached.")
    }

}
