import CryptoKit
import Foundation
import Security

nonisolated struct NotificationSecret: Codable, Sendable {
    let scope: String
    let hostID: String
    var name: String
    let secret: Data

    func key(_ label: String) -> SymmetricKey {
        let bytes = HMAC<SHA256>.authenticationCode(
            for: Data("openbot push notification \(label)".utf8), using: SymmetricKey(data: secret))
        return SymmetricKey(data: Data(bytes))
    }
}

nonisolated struct OpenedPush: Sendable {
    let scope: String
    let hostID: String
    let agentID: String
    let threadID: String?
    let kind: String
    let title: String
    let body: String
    let serverName: String?
}

/// The existing host's notification seal. No account credentials are shared with the extension.
nonisolated enum NotificationPayload {
    static let categoryIdentifier = "native.message"

    private struct Content: Decodable {
        let serverId: String
        let agentId: String
        let threadId: String?
        let kind: String
        let title: String
        let body: String
    }

    static func open(_ sealed: String, secrets: [NotificationSecret]) -> OpenedPush? {
        guard sealed.utf8.count <= 3_600, let bytes = decode(sealed), bytes.count > 32 else { return nil }
        let authenticated = Data(bytes.dropLast(16))
        let tag = Array(bytes.suffix(16))
        let nonce = Array(bytes.prefix(16))
        let cipher = Array(bytes.dropFirst(16).dropLast(16))
        for record in secrets where record.secret.count == 32 {
            let expected = Array(HMAC<SHA256>.authenticationCode(for: authenticated, using: record.key("tag")).prefix(16))
            var difference: UInt8 = 0
            for index in 0..<16 { difference |= tag[index] ^ expected[index] }
            guard difference == 0 else { continue }
            var plain = Data()
            var counter: UInt32 = 0
            var offset = 0
            while offset < cipher.count {
                let block = nonce + withUnsafeBytes(of: counter.bigEndian) { Array($0) }
                let stream = Array(HMAC<SHA256>.authenticationCode(for: Data(block), using: record.key("seal")))
                for index in 0..<min(32, cipher.count - offset) { plain.append(cipher[offset + index] ^ stream[index]) }
                offset += 32
                counter += 1
            }
            guard let value = try? JSONDecoder().decode(Content.self, from: plain), value.serverId == record.scope,
                  !value.agentId.isEmpty, value.agentId.utf8.count <= 128,
                  value.threadId.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
                  ["reply", "failed", "input", "approval", "browser"].contains(value.kind),
                  value.title.utf8.count <= 1_024, value.body.utf8.count <= 3_600 else { return nil }
            return OpenedPush(scope: record.scope, hostID: record.hostID, agentID: value.agentId,
                              threadID: value.threadId, kind: value.kind, title: value.title, body: value.body,
                              serverName: secrets.count > 1 ? record.name : nil)
        }
        return nil
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

/// Atomic Keychain values, available after the first unlock, including to the notification extension.
nonisolated struct NotificationKeyStore: Sendable {
    enum Failure: Error { case keychain }
    private let service: String
    private let group: String?

    init(bundle: Bundle = .main) {
        let appID = bundle.object(forInfoDictionaryKey: "OpenBotContainingAppID") as? String ?? bundle.bundleIdentifier ?? "com.gerardomaruotti.openbot.native"
        service = appID + ".notification-keys"
        group = bundle.object(forInfoDictionaryKey: "OpenBotNotificationKeychainGroup") as? String
    }

    private var item: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "hosts-v1"]
        if let group, !group.isEmpty { result[kSecAttrAccessGroup as String] = group }
        return result
    }

    func load() throws -> [NotificationSecret] {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = value as? Data, data.count <= 256 * 1_024 else { throw Failure.keychain }
        return try JSONDecoder().decode([NotificationSecret].self, from: data)
    }

    func save(_ records: [NotificationSecret]) throws {
        guard records.count <= 256 else { throw Failure.keychain }
        let data = try JSONEncoder().encode(records)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure.keychain }
        var query = item
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
    }

    func clear() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain }
    }
}
