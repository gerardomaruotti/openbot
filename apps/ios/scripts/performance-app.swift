import CryptoKit
import Foundation
import Observation
import SwiftUI

// Separate simulator app entry. Never include this file in a product target.
// Authoring gate: this drives the real native model/disk owners. It protects reply graph
// correctness and scaling, including nested replies that the small UI journey does not cover.
// No production test seam, account service, provider, restore or reconnect is used.
#if targetEnvironment(simulator)
@main
struct NativePerformanceApp: App {
    var body: some Scene { WindowGroup { NativePerformanceScreen() } }
}

private struct NativePerformanceScreen: View {
    @State private var runner = NativePerformanceRunner()

    var body: some View {
        Form {
            Section("Synthetic native benchmark") {
                Button("Run Projection") { Task { await runner.runProjection() } }
                    .disabled(runner.isRunning)
                Button("Run Storage") { Task { await runner.runStorage() } }
                    .disabled(runner.isRunning)
            }
            Section("Status") {
                Text(verbatim: runner.status)
                Text(verbatim: runner.summary).font(.caption).textSelection(.enabled)
                Text(verbatim: "Documents/performance-results.json").font(.caption)
            }
        }
    }
}

private struct PerformanceTiming: Encodable {
    let name: String
    let warmups: Int
    let sampleMilliseconds: [Double]
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let observedCounts: [Int]
}

private struct PerformanceProjection: Encodable {
    let rows: Int
    let tokenCallbacksPerSample: Int
    let timeline: PerformanceTiming
    let focusedRootsEightAndRepliesOne: PerformanceTiming
    let streamingCallbacks: PerformanceTiming
    let messageIDChecksum: String
    let invariants: [String: Bool]
}

private struct PerformanceProbe: Encodable {
    let name: String
    let actualRoots: [String: String]
    let expectedRoots: [String: String]
    let expectedAbsent: [String]
    let actualFocusedIDs: [String]
    let expectedFocusedIDs: [String]
    let immutableTarget: String?
    let immutableTargetPreserved: Bool
    let violations: Int
}

private struct PerformanceStorage: Encodable {
    let chats: Int
    let olderRowsInFirstChat: Int
    let timing: PerformanceTiming
    let loadedRows: Int
    let exactLastDraft: Bool
    let exactReplyTarget: Bool
    let olderReplyContextRetained: Bool
}

private struct NativePerformanceReport: Encodable {
    let schema = 1
    let bundleID: String
    let system: String
    let device: String
    let simulator = true
    let configuration: String
    let timing = "ContinuousClock wall time on MainActor; milliseconds; nearest-rank percentiles"
    let limits = [
        "Synthetic native model and encrypted disk paths only; no network, provider or account service.",
        "Projection timing consumes returned counts; this is not a frame rate, layout or scrolling measurement.",
        "Two warmups and seven samples. Yield between samples. Storage flushes are outside projection timing.",
        "Stream batches use 100 callbacks at 50/500 rows and 20 at 1500; compare per callback as well as batch time.",
        "Storage times direct production Disk.save calls, not text input, keyboard or UI rendering.",
        "Simulator and build configuration affect these values; no physical-device claim."
    ]
    var projection: [PerformanceProjection] = []
    var correctness: [PerformanceProbe] = []
    var storage: [PerformanceStorage] = []
    var error: String?
}

@Observable
@MainActor
private final class NativePerformanceRunner {
    private(set) var isRunning = false
    private(set) var status = "Ready. Local synthetic data only."
    private(set) var summary = ""
    @ObservationIgnored private var model: ConversationStore?
    @ObservationIgnored private var report: NativePerformanceReport
    private let agentID = "native-performance-agent"
    private let timestamp = "2026-11-14T10:00:00Z"

    private enum Failure: String, Error {
        case unsafeBundle = "unsafe-benchmark-bundle"
        case existingAccount = "existing-account-preserved"
        case existingWorkspace = "existing-workspace-preserved"
        case fixture = "fixture-operation-failed"
    }

    init() {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        report = NativePerformanceReport(
            bundleID: Bundle.main.bundleIdentifier ?? "",
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            device: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator",
            configuration: configuration
        )
    }

    private func fixtureModel() async throws -> ConversationStore {
        if let model { return model }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        guard bundle.contains("performance"), UUID(uuidString: String(bundle.suffix(36))) != nil else {
            throw Failure.unsafeBundle
        }
        let credential = HostCredential(apiUrl: "http://127.0.0.1:9",
            sessionToken: "synthetic-native-performance-not-valid-remotely", userName: "Synthetic Performance",
            email: "native-performance@example.invalid", host: nil, hostKeys: [:],
            selectedHostID: "performance-host", membershipId: "performance-member")
        if let saved = try HostSessionStore.load() {
            guard saved.email == credential.email, saved.apiUrl == credential.apiUrl,
                  saved.selectedHostID == credential.selectedHostID, saved.membershipId == credential.membershipId,
                  saved.sessionToken == credential.sessionToken else { throw Failure.existingAccount }
        }
        guard let scope = credential.workspaceID else { throw Failure.fixture }
        let directory = LiveWorkspaceDisk.applicationDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            let allowed = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined() + ".sealed"
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard files.allSatisfy({ $0 == allowed }) else { throw Failure.existingWorkspace }
        }
        var state = LiveWorkspaceState(scope: scope)
        state.agents = [HostAgent(id: agentID, name: "Synthetic Performance", title: nil)]
        state.pages[agentID] = page(rows: 50, prefix: "seed", thread: "performance-seed")
        state.lastOpenedID = agentID
        let disk = LiveWorkspaceDisk(directory: directory, key: try HostSessionStore.workspaceKey())
        try disk.save(state)
        try HostSessionStore.save(credential)
        let loaded = ConversationStore()
        guard loaded.isLive, loaded.lastOpenedID == agentID,
              loaded.conversation(agentID)?.messages.count == 50 else { throw Failure.fixture }
        // This only pauses/flushes an uninstalled connection. It never loads transport JavaScript.
        await loaded.setActive(false)
        model = loaded
        return loaded
    }

    private func message(_ id: String, author: String = "assistant", text: String? = nil,
                         reply: String? = nil, turn: String? = nil, streaming: Bool = false) -> HostMessage {
        HostMessage(id: id, author: author, text: text ?? "Synthetic \(id)", createdAt: timestamp,
                    status: streaming ? "streaming" : "completed", itemType: "agentMessage",
                    replyToMessageId: reply, turnId: turn)
    }

    private func page(rows: Int, prefix: String, thread: String, streaming: Bool = false) -> HostPage {
        let root = "\(prefix)-P"
        var messages = [message("\(prefix)-seed-user", author: "user", turn: "\(prefix)-seed-turn"),
                        message(root, turn: "\(prefix)-seed-turn")]
        for index in 0..<((rows - 2) / 2) {
            let turn = "\(prefix)-T\(index)"
            messages.append(message("\(prefix)-U\(index)", author: "user", reply: root, turn: turn))
            messages.append(message("\(prefix)-A\(index)", turn: turn,
                                    streaming: streaming && index == (rows - 2) / 2 - 1))
        }
        return HostPage(agentId: agentID, threadId: thread,
                        activeTurnId: streaming ? messages.last?.turnId : nil, revision: 1_000,
                        messages: messages, pageInfo: .init(hasOlder: false, olderCursor: nil))
    }

    private func feed(_ page: HostPage, to model: ConversationStore) throws {
        let wire = try JSONDecoder().decode(WireValue.self, from: JSONEncoder().encode(page))
        model.connection.teamEvent?(.object(["type": .string("conversation-page"), "page": wire]))
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1_000_000_000_000_000
    }

    private func timing(_ name: String, operation: () throws -> Int) async throws -> PerformanceTiming {
        let clock = ContinuousClock()
        var samples: [Double] = [], counts: [Int] = []
        for index in 0..<9 {
            let start = clock.now
            let count = try operation()
            let elapsed = milliseconds(start.duration(to: clock.now))
            if index >= 2 { samples.append(elapsed); counts.append(count) }
            await Task.yield()
        }
        return summarize(name, samples: samples, counts: counts)
    }

    private func summarize(_ name: String, samples: [Double], counts: [Int]) -> PerformanceTiming {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        return PerformanceTiming(name: name, warmups: 2, sampleMilliseconds: samples,
                                 p50Milliseconds: percentile(0.5), p95Milliseconds: percentile(0.95), observedCounts: counts)
    }

    private func checksum(_ values: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for value in values {
            for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            hash = (hash ^ 0xff) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    func runProjection() async {
        guard !isRunning else { return }
        isRunning = true; status = "Preparing native projection fixture."
        defer { isRunning = false }
        do {
            let model = try await fixtureModel()
            report.error = nil; report.projection = []; report.correctness = []
            let run = UUID().uuidString
            for rows in [50, 500, 1_500] {
                status = "Projection: \(rows) rows."
                let prefix = "rows-\(rows)", root = "rows-\(rows)-P"
                let base = page(rows: rows, prefix: prefix, thread: "\(run)-\(rows)-base")
                try feed(base, to: model)
                await model.setActive(false)
                let timeline = try await timing("replyTimeline") {
                    model.replyTimeline(self.agentID).reduce(0) { $0 + $1.messages.count }
                }
                let focused = try await timing("replyRoots x8 + replies x1") {
                    var count = 0
                    for _ in 0..<8 { count += model.replyRoots(self.agentID).count }
                    return count + model.replies(to: root, in: self.agentID).count
                }
                let tokens = rows == 1_500 ? 20 : 100
                var streamSamples: [Double] = [], streamCounts: [Int] = []
                var finalTextCorrect = true, rowsCorrect = true
                for index in 0..<9 {
                    var streamed = page(rows: rows, prefix: prefix, thread: "\(run)-\(rows)-stream-\(index)", streaming: true)
                    try feed(streamed, to: model)
                    await model.setActive(false)
                    guard let last = streamed.messages.last, let thread = streamed.threadId else { throw Failure.fixture }
                    let events = (1...tokens).map { token in WireValue.object([
                        "type": .string("conversation-delta"), "agentId": .string(self.agentID),
                        "threadId": .string(thread), "messageId": .string(last.id), "delta": .string("x"),
                        "revision": .number(Double(streamed.revision + token))
                    ]) }
                    let clock = ContinuousClock()
                    let start = clock.now
                    for event in events { model.connection.teamEvent?(event) }
                    let elapsed = milliseconds(start.duration(to: clock.now))
                    let actual = model.conversation(agentID)?.messages ?? []
                    if index >= 2 { streamSamples.append(elapsed); streamCounts.append(actual.count) }
                    if let content = actual.last?.content, case .text(let text) = content {
                        finalTextCorrect = finalTextCorrect && text == last.text + String(repeating: "x", count: tokens)
                    } else { finalTextCorrect = false }
                    rowsCorrect = rowsCorrect && actual.count == rows
                    // Flush after callbacks, outside timing. Then close the synthetic final answer.
                    await model.setActive(false)
                    streamed.messages[streamed.messages.count - 1] = message(last.id,
                        text: last.text + String(repeating: "x", count: tokens), turn: last.turnId)
                    streamed.revision += tokens + 1
                    let final = HostPage(agentId: streamed.agentId, threadId: streamed.threadId, activeTurnId: nil,
                        revision: streamed.revision, messages: streamed.messages, pageInfo: streamed.pageInfo)
                    try feed(final, to: model)
                    await model.setActive(false)
                    await Task.yield()
                }
                let actualIDs = model.conversation(agentID)?.messages.map(\.id) ?? []
                report.projection.append(PerformanceProjection(rows: rows, tokenCallbacksPerSample: tokens,
                    timeline: timeline, focusedRootsEightAndRepliesOne: focused,
                    streamingCallbacks: summarize("conversation-delta callback batch", samples: streamSamples, counts: streamCounts),
                    messageIDChecksum: checksum(actualIDs), invariants: [
                        "timelineRowCounts": timeline.observedCounts.allSatisfy { $0 == rows },
                        "focusedCounts": focused.observedCounts.allSatisfy { $0 == (rows - 2) * 9 },
                        "streamedRowCounts": rowsCorrect, "finalTextExact": finalTextCorrect,
                        "messageIDsExact": actualIDs == base.messages.map(\.id)
                    ]))
                try writeReport()
                await Task.yield()
            }
            report.correctness = try await correctness(model)
            let violations = report.correctness.reduce(0) { $0 + $1.violations }
            try writeReport()
            status = "Projection complete. Correctness violations: \(violations)."
            summary = report.projection.map { "\($0.rows) rows: timeline p50 \(String(format: "%.3f", $0.timeline.p50Milliseconds)) ms; focus p50 \(String(format: "%.3f", $0.focusedRootsEightAndRepliesOne.p50Milliseconds)) ms" }.joined(separator: "\n")
        } catch { failed(error) }
    }

    private func correctness(_ model: ConversationStore) async throws -> [PerformanceProbe] {
        let parent = message("P", turn: "base")
        let u1 = message("U1", author: "user", reply: "P", turn: "T1")
        let a1 = message("A1", turn: "T1")
        let u2 = message("U2", author: "user", reply: "A1", turn: "T2")
        let a2 = message("A2", turn: "T2")
        let cases: [(String, [HostMessage], Bool, [String: HostMessage]?, [String: String], [String], [String])] = [
            ("nested-answer-reply", [parent, u1, a1, u2, a2], false, nil,
             ["U1": "P", "A1": "P", "U2": "P", "A2": "P"], [], ["U1", "A1", "U2", "A2"]),
            ("mixed-user-input", [parent, u1, message("plain", author: "user", turn: "T1"), a1], false, nil,
             ["U1": "P"], ["A1", "plain"], ["U1"]),
            ("agent-input", [parent, u1, message("teammate", author: "agent", turn: "T1"), a1], false, nil,
             ["U1": "P"], ["A1", "teammate"], ["U1"]),
            ("incomplete-turn-start", [u1, a1], true, ["P": parent],
             ["U1": "P"], ["A1"], ["U1"]),
            ("cycle", [message("cycle-A", author: "user", reply: "cycle-B"),
                       message("cycle-B", author: "user", reply: "cycle-A")], false, nil,
             [:], ["cycle-A", "cycle-B"], [])
        ]
        var results: [PerformanceProbe] = []
        for (name, messages, incomplete, references, expected, absent, focused) in cases {
            let page = HostPage(agentId: agentID, threadId: "probe-\(UUID().uuidString)", activeTurnId: nil,
                revision: 1, messages: messages, pageInfo: .init(hasOlder: incomplete, olderCursor: incomplete ? "synthetic-older" : nil), references: references)
            try feed(page, to: model)
            await model.setActive(false)
            let roots = model.replyRoots(agentID)
            let actualFocused = model.replies(to: "P", in: agentID).map(\.id)
            var violations = expected.filter { roots[$0.key] != $0.value }.count
            violations += absent.filter { roots[$0] != nil }.count
            if actualFocused != focused { violations += 1 }
            var immutable = true
            if name == "nested-answer-reply" {
                model.setReplyTarget("A1", in: agentID)
                await model.setActive(false)
                immutable = model.draftReplyTarget(agentID) == "A1"
                guard let scope = model.connection.workspaceID else { throw Failure.fixture }
                let disk = LiveWorkspaceDisk(directory: LiveWorkspaceDisk.applicationDirectory, key: try HostSessionStore.workspaceKey())
                let stored = try disk.load(scope: scope)
                immutable = immutable && stored?.draftReplyTargets?[agentID] == "A1"
                if !immutable { violations += 1 }
            }
            results.append(PerformanceProbe(name: name, actualRoots: roots, expectedRoots: expected,
                expectedAbsent: absent, actualFocusedIDs: actualFocused, expectedFocusedIDs: focused,
                immutableTarget: name == "nested-answer-reply" ? model.draftReplyTarget(agentID) : nil,
                immutableTargetPreserved: immutable, violations: violations))
            await Task.yield()
        }
        return results
    }

    func runStorage() async {
        guard !isRunning else { return }
        isRunning = true; status = "Preparing encrypted storage fixture."
        defer { isRunning = false }
        do {
            _ = try await fixtureModel()
            report.error = nil; report.storage = []
            for chats in [20, 100] {
                status = "Storage: \(chats) chats, 5000 older rows."
                var state = LiveWorkspaceState(scope: "synthetic-storage-\(UUID().uuidString)")
                for index in 0..<chats {
                    let id = "storage-agent-\(index)"
                    state.agents.append(HostAgent(id: id, name: "Synthetic \(index)", title: nil))
                    let source = page(rows: index == 0 ? 5_050 : 50, prefix: id, thread: "storage-thread-\(index)")
                    state.pages[id] = HostPage(agentId: id, threadId: source.threadId, activeTurnId: nil,
                        revision: 1, messages: source.messages, pageInfo: .init(hasOlder: false, olderCursor: nil),
                        recentPageInfo: .init(hasOlder: index == 0, olderCursor: index == 0 ? "synthetic-recent-fifty" : nil))
                }
                let id = "storage-agent-0", target = "storage-agent-0-P"
                state.draftReplyTargets = [id: target]
                let directory = URL.documentsDirectory.appendingPathComponent("PerformanceStorage/\(UUID().uuidString)", isDirectory: true)
                let disk = LiveWorkspaceDisk(directory: directory, key: SymmetricKey(size: .bits256))
                var ordinal = 0, lastDraft = ""
                let measured = try await timing("Disk.save accepted synthetic draft") {
                    lastDraft = "Synthetic draft edit \(ordinal)"
                    state.drafts = [id: lastDraft]
                    ordinal += 1
                    try disk.save(state)
                    return lastDraft.utf8.count
                }
                guard let loaded = try disk.load(scope: state.scope) else { throw Failure.fixture }
                report.storage.append(PerformanceStorage(chats: chats, olderRowsInFirstChat: 5_000,
                    timing: measured, loadedRows: loaded.pages.values.reduce(0) { $0 + $1.messages.count },
                    exactLastDraft: loaded.drafts?[id] == lastDraft,
                    exactReplyTarget: loaded.draftReplyTargets?[id] == target,
                    olderReplyContextRetained: loaded.pages[id]?.references?[target]?.id == target))
                try writeReport()
                await Task.yield()
            }
            status = "Storage complete."
            summary = report.storage.map { "\($0.chats) chats: p50 \(String(format: "%.3f", $0.timing.p50Milliseconds)) ms; cached rows \($0.loadedRows)" }.joined(separator: "\n")
        } catch { failed(error) }
    }

    private func writeReport() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL.documentsDirectory.appendingPathComponent("performance-results.json"), options: .atomic)
    }

    private func failed(_ error: Error) {
        let code = (error as? Failure)?.rawValue ?? Failure.fixture.rawValue
        report.error = code
        status = "Benchmark stopped: \(code)."
        try? writeReport()
    }
}
#else
@main
struct NativePerformanceApp: App {
    var body: some Scene { WindowGroup { Text("This benchmark can run only in the simulator.") } }
}
#endif
