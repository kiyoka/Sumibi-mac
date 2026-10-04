import Foundation
import SumibiCore

/// 送信先の設定(エンドポイントとモデル名)を`UserDefaults`へ保存する。
///
/// APIキーはここでは扱わない。`APIKeyStore`がKeychainへ保存する。
struct SettingsStore {
    private enum Key {
        static let providerConfiguration = "providerConfiguration"
        static let consentEndpoint = "aiDataSharingConsentEndpoint"
        static let userDictionary = "userDictionary"
        /// 以前の既定モデル(GPT-5.6 Terra)からGPT-6 Solへの移行を済ませたか。
        static let legacyDefaultModelMigrated = "legacyDefaultModelMigrated"
    }

    private let defaults: UserDefaults
    private let prototypeDefaults: () -> UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard,
         prototypeDefaults: @escaping () -> UserDefaults? = { UserDefaults(suiteName: SettingsStore.prototypeDomain) }) {
        self.defaults = defaults
        self.prototypeDefaults = prototypeDefaults
    }

    /// 試作版(識別子`dev.kiyoka.inputmethod.SumibiPrototypeProbe1`)の設定の保存先。
    static let prototypeDomain = "dev.kiyoka.inputmethod.SumibiPrototypeProbe1"

    /// 試作版で保存した送信先・モデル・同意を、製品版の識別子の保存先へ一度だけ写す。
    ///
    /// 識別子を変えると`UserDefaults`の保存先も変わり、そのままでは設定をやり直すことになる。
    /// 製品版に送信先の設定がまだないときだけ写し、試作版の設定は消さない。APIキーはKeychainにあり、識別子に依存しない。
    func importPrototypeSettingsIfNeeded() {
        guard defaults.data(forKey: Key.providerConfiguration) == nil,
              let prototype = prototypeDefaults(),
              let data = prototype.data(forKey: Key.providerConfiguration) else { return }
        defaults.set(data, forKey: Key.providerConfiguration)
        for key in [Key.consentEndpoint, Key.legacyDefaultModelMigrated] {
            if let value = prototype.object(forKey: key) { defaults.set(value, forKey: key) }
        }
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

    func loadUserDictionary() -> String {
        defaults.string(forKey: Key.userDictionary) ?? ""
    }

    func saveUserDictionary(_ dictionary: String) {
        defaults.set(dictionary, forKey: Key.userDictionary)
    }
}
