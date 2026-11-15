import Foundation
import Security
import CryptoKit

enum HostSessionStore {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "com.gerardomaruotti.openbot.native").connection"

    static func load() throws -> HostCredential? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ConnectionProblem.keychain }
        do { return try JSONDecoder().decode(HostCredential.self, from: data) }
        catch { throw ConnectionProblem.keychain }
    }

    static func save(_ credential: HostCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        let result = SecItemUpdate(item as CFDictionary, update as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw ConnectionProblem.keychain }
        var values = item
        values[kSecValueData as String] = data
        values[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw ConnectionProblem.keychain }
    }

    static func clear() throws {
        // Both connection records belong to this app-local service. Delete them with
        // one query so a second, separate deletion cannot leave a half-cleared session.
        var records = item
        records.removeValue(forKey: kSecAttrAccount as String)
        let status = SecItemDelete(records as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionProblem.keychain }
    }

    static func workspaceKey() throws -> SymmetricKey {
        var query = item
        query[kSecAttrAccount as String] = "workspace-key-v1"
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw ConnectionProblem.keychain }
        let key = SymmetricKey(size: .bits256)
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw ConnectionProblem.keychain }
        return key
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session-v1"]
    }
}
