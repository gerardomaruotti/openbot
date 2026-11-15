import Foundation
import ImageIO
import Observation
import UIKit

/// A frame stays in memory for this view only. It is never an attachment or a cached chat value.
struct NativeBrowserFrame {
    let viewID: String
    let sequence: Int
    let width: Int
    let height: Int
    let image: UIImage
}

/// The request and view that were visible when the person made an action.
struct NativeBrowserIntent: Equatable {
    let request: AgentBrowserHandoff
    let hostID: String
    let workspaceID: String
    let transportIdentity: UUID
    let sessionID: UUID
    let generation: Int
    let viewID: String?
}

/// One exact host attention request. The bridge owns the stream and checks the current host,
/// session and complete request again before it sends input or a response.
@Observable
@MainActor
final class NativeBrowserSession {
    enum Phase: Equatable {
        case idle, checking, connecting, live, secret, unsupported, paused, ended, resolved
    }

    private(set) var request: AgentBrowserHandoff?
    private(set) var phase = Phase.idle
    private(set) var frame: NativeBrowserFrame?
    private(set) var problem: LocalizedStringResource?
    private(set) var responding = false
    private(set) var sendingInput = false
    private(set) var supportsView = false
    private(set) var supportsSecret = false
    private(set) var namesFrames = false
    private var clipboard = false
    private var featuresReady = false
    private var hostID: String?
    private var workspaceID: String?
    private var viewID: String?
    private var sessionID = UUID()
    private var generation = 0
    @ObservationIgnored private weak var connection: AgentConnection?
    @ObservationIgnored private weak var transport: HostTransport?
    @ObservationIgnored private var transportIdentity: UUID?

    var isOpen: Bool { request != nil }
    var canInteract: Bool { phase == .live && frame != nil && !responding && !sendingInput }
    var canRespond: Bool { request != nil && phase != .resolved && phase != .checking && !responding }
    var needsSecret: Bool {
        request?.wire["secret"] != nil && request?.wire["secret"] != .null &&
        request?.wire["secret"]?["requiresReload"]?.bool != true
    }
    var canSubmitSecret: Bool { phase == .secret && supportsSecret && !responding }

    var intent: NativeBrowserIntent? {
        guard let request, let hostID, let workspaceID, let transportIdentity else { return nil }
        return NativeBrowserIntent(request: request, hostID: hostID, workspaceID: workspaceID,
                                   transportIdentity: transportIdentity, sessionID: sessionID,
                                   generation: generation, viewID: viewID)
    }

    func accepts(_ intent: NativeBrowserIntent, connection: AgentConnection) -> Bool {
        self.intent == intent && connection.isAuthenticated && connection.hostID == intent.hostID &&
        connection.workspaceID == intent.workspaceID && connection.transport.identity == intent.transportIdentity
    }

    func prepare(_ request: AgentBrowserHandoff, connection: AgentConnection) {
        clear()
        self.request = request
        hostID = connection.hostID
        workspaceID = connection.workspaceID
        self.connection = connection
        transport = connection.transport
        transportIdentity = connection.transport.identity
    }

    func open(_ request: AgentBrowserHandoff, connection: AgentConnection) async {
        prepare(request, connection: connection)
        if let intent { await resume(intent: intent, connection: connection, userInitiated: true) }
    }

    /// Foreground resume is a new view, not a replay of a click, key or secret.
    func resume(intent: NativeBrowserIntent, connection: AgentConnection, userInitiated: Bool = false) async {
        guard accepts(intent, connection: connection), connection.canSend else { return }
        let request = intent.request, hostID = intent.hostID
        guard viewID == nil, !responding, phase != .checking, phase != .connecting, phase != .resolved else { return }
        generation += 1
        let epoch = generation
        phase = .checking
        problem = nil
        do {
            let support = try await connection.transport.execute([
                "type": .string("browserSessionCapabilities"), "hostId": .string(hostID),
                "browserTakeover": request.wire
            ])
            guard current(epoch, connection: connection), self.request == request else { return }
            supportsView = support["view"]?.bool == true
            supportsSecret = support["secret"]?.bool == true
            if needsSecret {
                phase = supportsSecret ? .secret : .unsupported
                if !supportsSecret && userInitiated { problem = "native.error.generic" }
                return
            }
            guard supportsView else {
                phase = .unsupported
                if userInitiated { problem = "native.error.generic" }
                return
            }
            let nextID = UUID().uuidString
            viewID = nextID
            featuresReady = false
            phase = .connecting
            let features = try await connection.transport.execute([
                "type": .string("browserSessionOpen"), "hostId": .string(hostID),
                "viewId": .string(nextID), "browserTakeover": request.wire
            ])
            guard current(epoch, connection: connection), viewID == nextID else {
                // The earlier close can reach the bridge while open is still pending.
                // Release this exact late view as well; never close the replacement view.
                if connection.transport.identity == intent.transportIdentity {
                    _ = try? await connection.transport.execute([
                        "type": .string("browserSessionClose"), "hostId": .string(hostID), "viewId": .string(nextID)
                    ])
                }
                return
            }
            namesFrames = features["namesFrames"]?.bool == true
            clipboard = features["clipboard"]?.bool == true
            featuresReady = true
            // A frame can arrive before the open command finishes. It is the evidence of a view.
            if frame != nil { phase = .live }
        } catch {
            guard current(epoch, connection: connection) else { return }
            await releaseView()
            guard current(epoch, connection: connection) else { return }
            phase = .ended
            if userInitiated { problem = "native.error.generic" }
        }
    }

    func pause(intent: NativeBrowserIntent) {
        guard owns(intent) else { return }
        if phase != .resolved { invalidate(.paused) }
    }

    func close(intent: NativeBrowserIntent) {
        if owns(intent) { clear() }
    }

    func clear() {
        invalidate(.idle)
        request = nil
        hostID = nil
        workspaceID = nil
        sessionID = UUID()
        connection = nil
        transport = nil
        transportIdentity = nil
        frame = nil
        phase = .idle
        problem = nil
        supportsView = false
        supportsSecret = false
        namesFrames = false
        clipboard = false
        featuresReady = false
        responding = false
        sendingInput = false
    }

    /// Called with the same host-scoped events as AgentTasks. No raw page or error text is kept.
    func receive(_ event: WireValue, hostID currentHost: String?) {
        guard let request else { return }
        guard hostID == currentHost else { invalidate(.ended); return }
        switch event["type"]?.string {
        case "native-browser-frame":
            guard event["hostId"]?.string == hostID, event["viewId"]?.string == viewID,
                  let sequence = event["sequence"]?.integer, sequence > 0,
                  sequence > (frame?.sequence ?? 0), let width = event["width"]?.integer,
                  let height = event["height"]?.integer, width > 0, height > 0,
                  let jpeg = event["jpeg"]?.string, let viewID else { return }
            guard jpeg.utf8.count <= 2_796_208, let data = Data(base64Encoded: jpeg),
                  data.count <= 2 * 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelsWide = properties[kCGImagePropertyPixelWidth] as? Int,
                  let pixelsHigh = properties[kCGImagePropertyPixelHeight] as? Int,
                  pixelsWide == width, pixelsHigh == height,
                  width <= 8_192, height <= 8_192, width * height <= 16_777_216,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                acknowledge(sequence: sequence, drawn: false)
                return
            }
            frame = NativeBrowserFrame(viewID: viewID, sequence: sequence, width: width, height: height,
                                       image: UIImage(cgImage: decoded))
            phase = featuresReady ? .live : .connecting
            problem = nil
        case "native-browser-ended":
            guard event["hostId"]?.string == hostID, event["viewId"]?.string == viewID else { return }
            invalidate(.ended)
        case "browser-takeover-resolved":
            if event["agentId"]?.string == request.agentID && event["requestId"] == request.requestID {
                invalidate(.resolved)
            }
        case "browser-takeover-requested":
            guard let value = event["request"], let incoming = AgentBrowserHandoff(value),
                  incoming.id == request.id else { return }
            if incoming != request { self.request = incoming; invalidate(.paused) }
        case "runtime-snapshot":
            guard event["snapshot"]?["attentionComplete"]?.bool == true,
                  case .array(let pending) = event["snapshot"]?["pendingBrowserTakeovers"] else { return }
            if let value = pending.first(where: { AgentBrowserHandoff($0)?.id == request.id }),
               let incoming = AgentBrowserHandoff(value) {
                if incoming != request { self.request = incoming; invalidate(.paused) }
            } else { invalidate(.resolved) }
        case "turn-completed":
            if event["agentId"]?.string == request.agentID && event["threadId"]?.string == request.threadID &&
                event["turnId"]?.string == request.turnID { invalidate(.resolved) }
        case "reset", "offline": invalidate(.paused)
        default: break
        }
    }

    /// Called after the view assigns this decoded image in its display transaction.
    func frameDisplayed(viewID: String, sequence: Int, intent: NativeBrowserIntent,
                        connection: AgentConnection) {
        guard accepts(intent, connection: connection), intent.viewID == viewID,
              frame?.sequence == sequence else { return }
        acknowledge(sequence: sequence, drawn: true, intent: intent)
    }

    func click(x: Double, y: Double, sequence: Int, intent: NativeBrowserIntent,
               connection: AgentConnection) async {
        guard accepts(intent, connection: connection), x.isFinite, y.isFinite else { return }
        await input([
            pointer(action: "down", x: x, y: y, sequence: sequence),
            pointer(action: "up", x: x, y: y, sequence: sequence)
        ], intent: intent, connection: connection)
    }

    func scroll(x: Double = 0.5, y: Double = 0.5, deltaX: Double = 0, deltaY: Double,
                sequence: Int, intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), x.isFinite, y.isFinite,
              deltaX.isFinite, deltaY.isFinite else { return }
        await input([pointer(action: "wheel", x: x, y: y, sequence: sequence,
                             deltaX: max(-10_000, min(10_000, deltaX)),
                             deltaY: max(-10_000, min(10_000, deltaY)))], intent: intent, connection: connection)
    }

    func typeText(_ text: String, intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), !text.isEmpty, text.utf16.count <= 4_096 else { return }
        if clipboard {
            await input([.object(["type": .string("paste"), "text": .string(text)])], intent: intent, connection: connection)
            return
        }
        // The base browser-view key contract works without optional clipboard support.
        // One char event inserts one character; named keys are a separate explicit action.
        let inputs: [WireValue] = text.unicodeScalars.flatMap { scalar -> [WireValue] in
            let character = String(scalar)
            let named = character == "\n" || character == "\r" ? "Enter" : (character == "\t" ? "Tab" : nil)
            let code: String
            switch scalar.value {
            case 65...90, 97...122: code = "Key" + character.uppercased()
            case 48...57: code = "Digit" + character
            case 32: code = "Space"
            default: code = ""
            }
            return (named == nil ? ["down", "char", "up"] : ["down", "up"]).map { action in
                .object(["type": .string("key"), "action": .string(action), "key": .string(named ?? character),
                         "code": .string(named ?? code), "text": .string(action == "char" ? character : ""),
                         "modifiers": .number(0)])
            }
        }
        await input(inputs, intent: intent, connection: connection)
    }

    func key(_ name: String, intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), ["Enter", "Tab", "Backspace"].contains(name) else { return }
        let values: [WireValue] = ["down", "up"].map { action in
            .object(["type": .string("key"), "action": .string(action), "key": .string(name),
                     "code": .string(name), "text": .string(""), "modifiers": .number(0)])
        }
        await input(values, intent: intent, connection: connection)
    }

    func respond(_ decision: String, intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), ["complete", "cancel"].contains(decision) else { return }
        let type = needsSecret && supportsSecret && decision == "cancel" ? "browserSecretRespond" : "browserTakeoverRespond"
        await respond(type: type, decision: decision, secret: nil, intent: intent, connection: connection)
    }

    func submitSecret(_ secret: String, intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), canSubmitSecret, !secret.isEmpty,
              secret.utf16.count <= 4_096 else { return }
        await respond(type: "browserSecretRespond", decision: "submit", secret: secret, intent: intent, connection: connection)
    }

    func takeOverSecret(intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), canSubmitSecret, supportsView else { return }
        await respond(type: "browserSecretRespond", decision: "takeover", secret: nil, intent: intent, connection: connection)
    }

    private func respond(type: String, decision: String, secret: String?, intent: NativeBrowserIntent,
                         connection: AgentConnection) async {
        guard accepts(intent, connection: connection), canRespond, connection.canSend else { return }
        responding = true
        problem = nil
        defer { if self.intent == intent { responding = false } }
        var command: [String: WireValue] = ["type": .string(type), "hostId": .string(intent.hostID),
                                           "browserTakeover": intent.request.wire, "decision": .string(decision)]
        if let secret { command["secret"] = .string(secret) }
        do {
            _ = try await connection.transport.execute(command)
            guard accepts(intent, connection: connection) else { return }
            if decision == "takeover" {
                // The host publishes the changed request. Do not reuse the pre-takeover request.
                invalidate(.paused)
            } else { invalidate(.resolved) }
        } catch {
            guard accepts(intent, connection: connection) else { return }
            problem = "native.error.generic"
        }
    }

    private func input(_ inputs: [WireValue], intent: NativeBrowserIntent, connection: AgentConnection) async {
        guard accepts(intent, connection: connection), let viewID = intent.viewID,
              canInteract, connection.canSend else { return }
        sendingInput = true
        problem = nil
        defer { if self.intent == intent { sendingInput = false } }
        do {
            for offset in stride(from: 0, to: inputs.count, by: 128) {
                guard accepts(intent, connection: connection), connection.canSend else { return }
                _ = try await connection.transport.execute([
                    "type": .string("browserSessionInput"), "hostId": .string(intent.hostID),
                    "viewId": .string(viewID), "inputs": .array(Array(inputs[offset..<min(inputs.count, offset + 128)]))
                ])
            }
        } catch {
            guard accepts(intent, connection: connection) else { return }
            // A lost reply is not permission to repeat a click or key.
            invalidate(.ended)
            problem = "native.error.generic"
        }
    }

    private func pointer(action: String, x: Double, y: Double, sequence: Int,
                         deltaX: Double = 0, deltaY: Double = 0) -> WireValue {
        var value: [String: WireValue] = ["type": .string("pointer"), "action": .string(action),
            "x": .number(max(0, min(1, x))), "y": .number(max(0, min(1, y))),
            "button": .string("left"), "clickCount": .number(1),
            "deltaX": .number(deltaX), "deltaY": .number(deltaY), "modifiers": .number(0)]
        if namesFrames { value["sequence"] = .number(Double(sequence)) }
        return .object(value)
    }

    private func current(_ epoch: Int, connection: AgentConnection) -> Bool {
        epoch == generation && connection.isAuthenticated && connection.hostID == hostID &&
        connection.workspaceID == workspaceID && connection.transport.identity == transportIdentity
    }

    private func owns(_ intent: NativeBrowserIntent) -> Bool {
        intent.sessionID == sessionID && intent.hostID == hostID && intent.workspaceID == workspaceID &&
        intent.transportIdentity == transportIdentity
    }

    private func acknowledge(sequence: Int, drawn: Bool, intent shown: NativeBrowserIntent? = nil) {
        guard let intent = shown ?? self.intent, let connection, let transport, let viewID = intent.viewID,
              accepts(intent, connection: connection) else { return }
        Task { [weak self] in
            guard self?.accepts(intent, connection: connection) == true else { return }
            do {
                _ = try await transport.execute(["type": .string("browserSessionFrameDone"),
                    "hostId": .string(intent.hostID), "viewId": .string(viewID),
                    "sequence": .number(Double(sequence)), "drawn": .bool(drawn)])
            } catch {
                guard self?.accepts(intent, connection: connection) == true else { return }
                self?.invalidate(.ended)
            }
        }
    }

    private func releaseView() async {
        guard let viewID else { return }
        self.viewID = nil
        frame = nil
        guard let hostID, let transport, transport.identity == transportIdentity else { return }
        _ = try? await transport.execute(["type": .string("browserSessionClose"),
                                          "hostId": .string(hostID), "viewId": .string(viewID)])
    }

    private func invalidate(_ phase: Phase) {
        generation += 1
        self.phase = phase
        problem = nil
        frame = nil
        responding = false
        sendingInput = false
        let previousView = viewID
        let previousTransport = transportIdentity
        viewID = nil
        guard let previousView, let hostID, let transport, transport.identity == transportIdentity else { return }
        Task {
            guard transport.identity == previousTransport else { return }
            _ = try? await transport.execute(["type": .string("browserSessionClose"),
                "hostId": .string(hostID), "viewId": .string(previousView)])
        }
    }
}
