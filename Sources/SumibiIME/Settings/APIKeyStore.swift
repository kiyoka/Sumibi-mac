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
/// アカウント名は送信先エンドポイントごとに分離し、別サービスへのキー誤送信を防ぐ(#69)。
struct APIKeyStore {
    private let service: String
    private static let legacyAccount = "default"
    private let keychain: any KeychainAccess

    init(keychain: any KeychainAccess = SystemKeychainAccess(),
         service: String = "org.sumibi.Sumibi-mac.api-key") {
        self.keychain = keychain
        self.service = service
    }

    static func account(for endpoint: String) -> String {
        "endpoint:\(endpoint.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func load(for endpoint: String, settings: SettingsStore) throws -> String? {
        try load(
            for: endpoint,
            legacyOwnerEndpoint: settings.legacyKeyOwnerEndpoint(),
            onLegacyChecked: { settings.clearLegacyKeyOwnerEndpoint() }
        )
    }

    func load(
        for endpoint: String,
        legacyOwnerEndpoint: String? = nil,
        onLegacyChecked: () -> Void = {}
    ) throws -> String? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let account = Self.account(for: trimmed)
        if let key = try load(account: account) { return key }

        // 接続先別保存の導入前に保存された単一キーは、元の設定エンドポイントに一致するときだけ引き継ぐ。
        guard let owner = legacyOwnerEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !owner.isEmpty,
              owner == trimmed else {
            return nil
        }
        guard let legacyKey = try load(account: Self.legacyAccount) else {
            onLegacyChecked()
            return nil
        }
        try save(legacyKey, account: account)
        try delete(account: Self.legacyAccount)
        onLegacyChecked()
        return legacyKey
    }

    func migrateLegacyKey(for endpoint: String, settings: SettingsStore) throws {
        _ = try load(for: endpoint, settings: settings)
    }

    func save(_ apiKey: String, for endpoint: String) throws {
        try save(apiKey, account: Self.account(for: endpoint))
    }

    func delete(for endpoint: String, settings: SettingsStore) throws {
        try delete(
            for: endpoint,
            legacyOwnerEndpoint: settings.legacyKeyOwnerEndpoint(),
            onLegacyChecked: { settings.clearLegacyKeyOwnerEndpoint() }
        )
    }

    func delete(
        for endpoint: String,
        legacyOwnerEndpoint: String? = nil,
        onLegacyChecked: () -> Void = {}
    ) throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        try delete(account: Self.account(for: trimmed))
        if let owner = legacyOwnerEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !owner.isEmpty,
           owner == trimmed {
            try delete(account: Self.legacyAccount)
            onLegacyChecked()
        }
    }

    func load() throws -> String? {
        try load(account: Self.legacyAccount)
    }

    func save(_ apiKey: String) throws {
        try save(apiKey, account: Self.legacyAccount)
    }

    func delete() throws {
        try delete(account: Self.legacyAccount)
    }

    private func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
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

    private func save(_ apiKey: String, account: String) throws {
        guard let data = apiKey.data(using: .utf8) else { throw APIKeyStoreError.invalidEncoding }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]

        let query = baseQuery(account: account)
        let updateStatus = keychain.update(query as CFDictionary, attributes: attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw APIKeyStoreError.keychain(updateStatus) }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = keychain.add(item as CFDictionary)
        guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
    }

    private func delete(account: String) throws {
        let status = keychain.delete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
