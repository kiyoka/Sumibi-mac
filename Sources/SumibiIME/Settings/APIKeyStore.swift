import Foundation
import Security

public enum APIKeyStoreError: Error, Equatable {
    case invalidEncoding
    case unexpectedData
    case keychain(OSStatus)
}

/// Injectable Security boundary. Tests never need to access the user's Keychain.
protocol KeychainAccess {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?)
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(_ item: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemKeychainAccess: KeychainAccess {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query, &result)
        return (status, result)
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
    func add(_ item: CFDictionary) -> OSStatus { SecItemAdd(item, nil) }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

/// APIキーをKeychainへ保存する。`UserDefaults`や設定ファイルには平文で置かない。
///
/// 項目の持ち方はSumibi-iOSの`APIKeyStore`に合わせる。コードは共有しない。
/// サービス名はバンドル識別子から作らない。識別子を変えても(#11)保存済みのキーを失わないため。
struct APIKeyStore {
    private static let service = "org.sumibi.Sumibi-mac.api-key"
    private static let account = "default"
    private let keychain: any KeychainAccess

    init(keychain: any KeychainAccess = SystemKeychainAccess()) { self.keychain = keychain }

    func load() throws -> String? {
        var query = Self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = keychain.copyMatching(query as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIKeyStoreError.keychain(status) }
        guard let data = result as? Data, let apiKey = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.unexpectedData
        }
        return apiKey
    }

    func save(_ apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        let updateStatus = keychain.update(Self.baseQuery as CFDictionary, attributes: attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw APIKeyStoreError.keychain(updateStatus) }

        var item = Self.baseQuery
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = keychain.add(item as CFDictionary)
        guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
    }

    func delete() throws {
        let status = keychain.delete(Self.baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
