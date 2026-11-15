import Foundation
import Observation
import UniformTypeIdentifiers

nonisolated struct NativeAttachmentInput: Sendable {
    static let maximumBytes = 10 * 1024 * 1024
    let name: String
    let mimeType: String
    let bytes: Data

    static func read(_ url: URL) throws -> NativeAttachmentInput {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Read only the supported range, even when a provider changes the file after selection.
        var bytes = Data()
        while true {
            let chunk = try file.read(upToCount: min(64 * 1024, maximumBytes + 1 - bytes.count)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
            guard bytes.count <= maximumBytes else { throw NativeAttachmentFailure.tooLarge }
        }
        return NativeAttachmentInput(
            name: safeName(url.lastPathComponent),
            mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            bytes: bytes)
    }

    static func safeName(_ value: String) -> String {
        let name = value.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters)).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { return "attachment" }
        var scalars = String.UnicodeScalarView()
        var size = 0
        for scalar in name.unicodeScalars {
            let count = String(scalar).utf8.count
            if size + count > 255 { break }
            scalars.append(scalar); size += count
        }
        return String(scalars)
    }
}

nonisolated enum NativeAttachmentFailure: Error {
    case tooLarge, tooMany, invalidFile
}

/// Draft bytes stay in memory until the host confirms the upload. Downloaded bytes are temporary.
@Observable
@MainActor
final class NativeAttachments {
    private(set) var drafts: [HostAttachment] = []
    private(set) var isBusy = false
    private(set) var downloadingID: String?
    private(set) var problemRevision = 0
    private(set) var problem: LocalizedStringResource? {
        didSet { if problem != nil { problemRevision += 1 } }
    }
    private(set) var previewURL: URL?
    private var scope: String?
    private var hostID: String?
    private var generation = 0
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAttachments-" + UUID().uuidString, isDirectory: true)
    private static var removedPreviousDownloads = false

    init() {
        // The first manager is created before any preview in this process. Later managers must
        // not remove a file that another chat or window is still showing.
        guard !Self.removedPreviousDownloads else { return }
        Self.removedPreviousDownloads = true
        let temporary = FileManager.default.temporaryDirectory
        let properties: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: Array(properties)) else { return }
        for entry in entries {
            let prefix = "NativeAttachments-"
            guard entry.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(entry.lastPathComponent.dropFirst(prefix.count))) != nil,
                  let values = try? entry.resourceValues(forKeys: properties), values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func bind(_ connection: AgentConnection) {
        guard scope != connection.workspaceID || hostID != connection.hostID else { return }
        clear(connection: connection)
        scope = connection.workspaceID
        hostID = connection.hostID
    }

    func importFile(_ url: URL, connection: AgentConnection) async {
        bind(connection)
        guard begin(connection) else { return }
        let epoch = generation
        defer { if epoch == generation { isBusy = false } }
        do {
            let input = try await Task.detached(priority: .userInitiated) { try NativeAttachmentInput.read(url) }.value
            try Task.checkCancellation()
            guard epoch == generation else { return }
            try await upload(input, connection: connection, epoch: epoch)
        } catch { if epoch == generation { failed(error) } }
    }

    func importPhoto(_ input: NativeAttachmentInput, connection: AgentConnection) async {
        bind(connection)
        guard begin(connection) else { return }
        let epoch = generation
        defer { if epoch == generation { isBusy = false } }
        do { try await upload(input, connection: connection, epoch: epoch) }
        catch { if epoch == generation { failed(error) } }
    }

    func selectionFailed(_ error: Error) { failed(error) }

    private func begin(_ connection: AgentConnection) -> Bool {
        guard !isBusy, connection.canSend, scope != nil, hostID != nil else {
            problem = "native.files.offline"
            return false
        }
        guard drafts.count < 10 else { problem = "native.files.tooMany"; return false }
        isBusy = true; problem = nil
        return true
    }

    private func upload(_ input: NativeAttachmentInput, connection: AgentConnection, epoch: Int) async throws {
        guard input.bytes.count <= NativeAttachmentInput.maximumBytes else { throw NativeAttachmentFailure.tooLarge }
        guard scope == connection.workspaceID, let hostID, connection.hostID == hostID else { throw CancellationError() }
        let value = try await connection.transport.execute([
            "type": .string("uploadAttachment"), "hostId": .string(hostID),
            "upload": .object(["name": .string(input.name), "mimeType": .string(input.mimeType), "base64": .string(input.bytes.base64EncodedString())])
        ])
        let attachment = try value.decode(HostAttachment.self)
        guard attachment.size == input.bytes.count, attachment.size <= NativeAttachmentInput.maximumBytes else { throw NativeAttachmentFailure.invalidFile }
        guard epoch == generation, scope == connection.workspaceID, connection.hostID == hostID, !Task.isCancelled else {
            if connection.hostID == hostID && connection.canSend {
                _ = try? await connection.transport.execute(["type": .string("discardAttachment"), "hostId": .string(hostID), "attachmentId": .string(attachment.id)])
            }
            return
        }
        drafts.append(attachment)
    }

    func remove(_ attachment: HostAttachment, connection: AgentConnection) async {
        guard !isBusy, drafts.contains(where: { $0.id == attachment.id }) else { return }
        drafts.removeAll { $0.id == attachment.id }
        problem = nil
        guard scope == connection.workspaceID, let hostID, connection.hostID == hostID, connection.canSend else { return }
        let epoch = generation
        do {
            _ = try await connection.transport.execute(["type": .string("discardAttachment"), "hostId": .string(hostID), "attachmentId": .string(attachment.id)])
        } catch { if epoch == generation { problem = "native.files.removeFailed" } }
    }

    /// Call only after the app has saved the message and its draft IDs in the durable outbox.
    func consume() { drafts = []; problem = nil }

    func open(_ attachment: HostAttachment, connection: AgentConnection) async {
        bind(connection)
        guard !isBusy, connection.canSend, scope != nil, let hostID, connection.hostID == hostID else { problem = "native.files.offline"; return }
        guard attachment.size <= NativeAttachmentInput.maximumBytes else { problem = "native.files.tooLarge"; return }
        let epoch = generation
        isBusy = true; downloadingID = attachment.id; problem = nil
        defer { if epoch == generation { isBusy = false; downloadingID = nil } }
        do {
            let value = try await connection.transport.execute(["type": .string("downloadAttachment"), "hostId": .string(hostID), "attachmentId": .string(attachment.id)])
            guard let encoded = value["base64"]?.string, encoded.utf8.count <= ((NativeAttachmentInput.maximumBytes + 2) / 3) * 4,
                  let bytes = Data(base64Encoded: encoded), bytes.count == attachment.size else { throw NativeAttachmentFailure.invalidFile }
            try Task.checkCancellation()
            guard epoch == generation, scope == connection.workspaceID, connection.hostID == hostID else { return }
            closePreview()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let target = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let file = target.appendingPathComponent(NativeAttachmentInput.safeName(attachment.name))
            try bytes.write(to: file, options: [.atomic, .completeFileProtection])
            previewURL = file
        } catch { if epoch == generation { problem = "native.files.downloadFailed" } }
    }

    func closePreview() {
        previewURL = nil
        if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
    }

    func clear(connection: AgentConnection) {
        let abandoned = drafts
        let oldHost = hostID
        let oldScope = scope
        generation += 1
        drafts = []; isBusy = false; downloadingID = nil; problem = nil
        scope = nil; hostID = nil
        closePreview()
        // Never send cleanup to a different host or account after navigation or sign-out.
        if let oldHost, oldHost == connection.hostID, oldScope == connection.workspaceID, connection.canSend {
            Task {
                for attachment in abandoned {
                    guard oldHost == connection.hostID, oldScope == connection.workspaceID, connection.canSend else { return }
                    _ = try? await connection.transport.execute(["type": .string("discardAttachment"), "hostId": .string(oldHost), "attachmentId": .string(attachment.id)])
                }
            }
        }
    }

    private func failed(_ error: Error) {
        if error is CancellationError { return }
        if (error as? CocoaError)?.code == .userCancelled { return }
        switch error as? NativeAttachmentFailure {
        case .tooLarge: problem = "native.files.tooLarge"
        case .tooMany: problem = "native.files.tooMany"
        default: problem = "native.files.uploadFailed"
        }
    }
}
