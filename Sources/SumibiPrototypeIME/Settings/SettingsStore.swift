import Foundation
import SumibiPrototypeCore

/// 送信先の設定(エンドポイントとモデル名)を`UserDefaults`へ保存する。
///
/// APIキーはここでは扱わない。`APIKeyStore`がKeychainへ保存する。
struct SettingsStore {
    private enum Key {
        static let providerConfiguration = "providerConfiguration"
        static let consentEndpoint = "aiDataSharingConsentEndpoint"
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
            return ProviderConfiguration()
        }
        return configuration.normalized
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
