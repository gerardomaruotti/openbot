import CryptoKit
import Foundation

/// Separate executable benchmark of the production encrypted file boundary.
/// It uses only a caller-owned synthetic directory, never application data.
@main
struct PersistenceBenchmark {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var results: [[String: Any]] = []
        for chats in [20, 100] {
            let scope = "synthetic-persistence-benchmark-\(chats)"
            var state = LiveWorkspaceState(scope: scope)
            let text = String(repeating: "x", count: chats == 20 ? 256 : 1024)
            for index in 0..<chats {
                let id = "agent-\(index)"
                state.agents.append(HostAgent(id: id, name: "Synthetic \(index)", title: nil))
                let count = index == 0 ? 5050 : 50
                let messages = (0..<count).map { row in
                    HostMessage(id: "\(id)-\(row)", author: row.isMultiple(of: 2) ? "user" : "assistant",
                                text: text, createdAt: "2026-11-14T10:00:00Z", status: "completed", itemType: "final_answer")
                }
                state.pages[id] = HostPage(agentId: id, threadId: "thread-\(id)", activeTurnId: nil,
                    revision: count, messages: messages, pageInfo: .init(hasOlder: false, olderCursor: nil))
            }
            // A visible target still needs its older ancestor after clipping.
            state.pages["agent-0"]?.messages[5049].replyToMessageId = "agent-0-0"
            state.draftReplyTargets = ["agent-0": "agent-0-5049"]
            for index in 0..<100 {
                state.outbox.append(OutboxMessage(clientID: "queued-\(index)", agentID: "agent-\(index % chats)",
                    text: "Synthetic queued", createdAt: .now))
            }
            let disk = LiveWorkspaceDisk(directory: output.appendingPathComponent(scope), key: SymmetricKey(size: .bits256))
            let clock = ContinuousClock()
            var samples: [Double] = []
            for sample in 0..<33 {
                state.drafts = ["agent-0": "Synthetic draft \(sample)"]
                let start = clock.now
                try disk.save(state)
                let elapsed = start.duration(to: clock.now).components
                if sample >= 3 { samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
            }
            let restoreStart = clock.now
            guard let recovered = try disk.load(scope: scope),
                  recovered.drafts?["agent-0"] == "Synthetic draft 32",
                  recovered.draftReplyTargets?["agent-0"] == "agent-0-5049",
                  recovered.pages["agent-0"]?.messages.count == 50,
                  recovered.pages["agent-0"]?.references?["agent-0-0"]?.text == text,
                  recovered.outbox.count == 100 else { throw BenchmarkFailure.roundTrip }
            let restoreDuration = restoreStart.duration(to: clock.now).components
            let sorted = samples.sorted()
            let files = try FileManager.default.contentsOfDirectory(at: disk.directory, includingPropertiesForKeys: [.fileSizeKey])
            let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            results.append(["chats": chats, "recentMessagesPerChat": 50, "extraLoadedHistory": 5000,
                "queuedMessages": 100, "textBytesPerMessage": text.utf8.count,
                "samplesMs": samples, "p50Ms": sorted[sorted.count / 2],
                "p95Ms": sorted[Int(Double(sorted.count - 1) * 0.95)], "maxMs": sorted.last!,
                "restoreMs": Double(restoreDuration.seconds) * 1000 + Double(restoreDuration.attoseconds) / 1e15,
                "archiveBytes": bytes, "lastDraftAndReferencedAncestorRecovered": true])
        }
        let report: [String: Any] = ["cases": results, "passed": true,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "limits": "Optimized macOS executable using actual iOS production storage code and synthetic data. Measures synchronous file-boundary CPU/wall time, not iPhone typing latency or UI frame rate."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("report.json"))
        print(String(decoding: data, as: UTF8.self))
    }
    enum BenchmarkFailure: Error { case roundTrip }
}
