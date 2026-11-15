import Foundation

@main
struct NotificationPayloadE2E {
    struct Fixture: Decodable {
        let name: String
        let sealed: String
        let secrets: [NotificationSecret]
        let kind: String?
        struct Expected: Decodable { let scope: String; let hostID: String; let agentID: String; let threadID: String?; let title: String; let body: String }
        let expected: Expected?
        let opens: Bool
    }
    enum Failure: Error { case check(String) }

    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
        for fixture in fixtures {
            let opened = NotificationPayload.open(fixture.sealed, secrets: fixture.secrets)
            guard (opened != nil) == fixture.opens else { throw Failure.check(fixture.name) }
            if let opened {
                guard opened.kind == (fixture.kind ?? "reply") else { throw Failure.check(fixture.name + "-kind") }
                if let expected = fixture.expected {
                    guard opened.scope == expected.scope, opened.hostID == expected.hostID,
                          opened.agentID == expected.agentID, opened.threadID == expected.threadID,
                          opened.title == expected.title, opened.body == expected.body else { throw Failure.check(fixture.name + "-host-content") }
                    continue
                }
                guard opened.scope == "synthetic-account-host-membership", opened.hostID == "synthetic-host",
                      opened.agentID == "synthetic-agent", opened.threadID == "synthetic-thread",
                      opened.title == "Synthetic Agent", opened.body == "SYNTHETIC-PUSH-BODY" else {
                    throw Failure.check(fixture.name + "-content")
                }
            }
        }
        print("{\"passed\":true,\"cases\":\(fixtures.count)}")
    }
}
