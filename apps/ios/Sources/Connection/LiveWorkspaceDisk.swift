import CryptoKit
import Foundation

/// Only authenticated ciphertext is stored. The caller owns the device-only Keychain key.
struct LiveWorkspaceDisk {
    let directory: URL
    let key: SymmetricKey

    static var applicationDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("NativeWorkspace", isDirectory: true)
    }

    func load(scope: String) throws -> LiveWorkspaceState? {
        let url = file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(box, using: key, authenticating: Data(scope.utf8))
        var state = try JSONDecoder().decode(LiveWorkspaceState.self, from: data)
        guard state.scope == scope else { throw ConnectionProblem.storage }
        state.recoverInterruptedSends()
        return state
    }

    func save(_ state: LiveWorkspaceState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        var recent = state
        recent.pages = state.pages.mapValues { page in
            var cached = page
            cached.messages = Array(page.messages.suffix(50))
            cached.pageInfo = page.recentPageInfo ?? page.pageInfo
            cached.recentPageInfo = nil
            var source = page.references ?? [:]
            for message in page.messages { source[message.id] = message }
            var needed = cached.messages.compactMap(\.replyToMessageId)
            needed += state.outbox.filter { $0.agentID == page.agentId }.compactMap(\.replyToMessageId)
            if let draftTarget = state.draftReplyTargets?[page.agentId] { needed.insert(draftTarget, at: 0) }
            var references: [String: HostMessage] = [:]
            let visible = Set(cached.messages.map(\.id))
            var visited: Set<String> = []
            while !needed.isEmpty, references.count < 100 {
                let id = needed.removeFirst()
                guard visited.insert(id).inserted, let message = source[id] else { continue }
                if !visible.contains(id) { references[id] = message }
                if let parent = message.replyToMessageId { needed.append(parent) }
            }
            cached.references = references.isEmpty ? nil : references
            return cached
        }
        let data = try JSONEncoder().encode(recent)
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(state.scope.utf8))
        guard let combined = sealed.combined else { throw ConnectionProblem.storage }
        try combined.write(to: file(state.scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove(scope: String) throws {
        let url = file(scope)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Call only after a successful, authenticated directory refresh.
    func retain(scopes: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let allowed = Set(scopes.map { file($0).standardizedFileURL })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "sealed" && !allowed.contains(url.standardizedFileURL) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func clearApplicationData() throws {
        if FileManager.default.fileExists(atPath: applicationDirectory.path) {
            try FileManager.default.removeItem(at: applicationDirectory)
        }
    }

    private func file(_ scope: String) -> URL {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("sealed")
    }
}
