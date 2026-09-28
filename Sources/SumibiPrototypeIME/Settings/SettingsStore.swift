import Foundation
import SumibiPrototypeCore

/// 送信先の設定(エンドポイントとモデル名)を`UserDefaults`へ保存する。
///
/// APIキーはここでは扱わない。`APIKeyStore`がKeychainへ保存する。
struct SettingsStore {
    private enum Key {
        static let providerConfiguration = "providerConfiguration"
        static let consentEndpoint = "aiDataSharingConsentEndpoint"
        /// 以前の既定モデル(GPT-5.6 Terra)からGPT-6 Solへの移行を済ませたか。
        static let legacyDefaultModelMigrated = "legacyDefaultModelMigrated"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProviderConfiguration() -> ProviderConfiguration {
        guard let data = defaults.data(forKey: Key.providerConfiguration),
              let configuration = try? decoder.decode(ProviderConfiguration.self, from: data) else {
            // 保存済みの設定がなければ、新しい既定モデルで始まる。移行の対象はない。
            defaults.set(true, forKey: Key.legacyDefaultModelMigrated)
            return ProviderConfiguration()
        }
        return migrateLegacyDefaultModel(configuration.normalized)
    }

    /// 以前の既定モデルで保存された設定を、初回の読み込みで一度だけ新しい既定モデルへ移す。
    private func migrateLegacyDefaultModel(_ configuration: ProviderConfiguration) -> ProviderConfiguration {
        let alreadyMigrated = defaults.bool(forKey: Key.legacyDefaultModelMigrated)
        let migrated = configuration.migratingLegacyDefaultModel(alreadyMigrated: alreadyMigrated)
        if migrated != configuration {
            // 保存できなくても、次の読み込みでまた移すだけなので、移行済みの印は保存できたときだけ付ける。
            guard (try? saveProviderConfiguration(migrated)) != nil else { return migrated }
        }
        defaults.set(true, forKey: Key.legacyDefaultModelMigrated)
        return migrated
    }

    func saveProviderConfiguration(_ configuration: ProviderConfiguration) throws {
        defaults.set(try encoder.encode(configuration), forKey: Key.providerConfiguration)
    }

    /// データ送信への同意は送信先ごとに持つ。送信先を変えたら同意を取り直す。
    func hasConsent(for endpoint: String) -> Bool {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return defaults.string(forKey: Key.consentEndpoint) == normalized
    }

    func saveConsent(for endpoint: String) {
        defaults.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.consentEndpoint)
    }

    func revokeConsent() {
        defaults.removeObject(forKey: Key.consentEndpoint)
    }
}
