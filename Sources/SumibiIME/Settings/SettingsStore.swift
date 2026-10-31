import Foundation
import SumibiCore

/// 送信先の設定(接続先・エンドポイント・モデル名)、同意、ユーザー辞書、利用統計を`UserDefaults`へ保存する。
///
/// APIキーはここでは扱わない。`APIKeyStore`がKeychainへ保存する。
struct SettingsStore {
    private enum Key {
        static let providerConfiguration = "providerConfiguration"
        static let providerConfigurations = "providerConfigurations"
        static let consentEndpoint = "aiDataSharingConsentEndpoint"
        static let userDictionary = "userDictionary"
        /// 以前の既定モデル(GPT-5.6 Terra)からGPT-6 Solへの移行を済ませたか。
        static let legacyDefaultModelMigrated = "legacyDefaultModelMigrated"
        /// 接続先別保存の導入前にKeychainの`default`アカウントを所有していたエンドポイント。
        static let legacyAPIKeyOwnerEndpoint = "legacyAPIKeyOwnerEndpoint"
        static let usageStatistics = "usageStatistics"
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

    /// 指定した接続先の保持済み設定を返す。未保存ならその接続先の初期設定を返す。
    func loadProviderConfiguration(for provider: AIProvider) -> ProviderConfiguration {
        if let data = defaults.data(forKey: Key.providerConfigurations),
           let configurations = try? decoder.decode([String: ProviderConfiguration].self, from: data),
           let configuration = configurations[provider.rawValue] {
            return configuration.normalized
        }
        let active = loadProviderConfiguration()
        if active.provider == provider { return active }
        return Self.defaultConfiguration(for: provider)
    }

    static func defaultConfiguration(for provider: AIProvider) -> ProviderConfiguration {
        switch provider {
        case .openAI:
            ProviderConfiguration(
                endpoint: AIProvider.openAI.defaultEndpoint,
                model: ProviderConfiguration.defaultModel,
                provider: .openAI
            )
        case .google:
            ProviderConfiguration(
                endpoint: AIProvider.google.defaultEndpoint,
                model: ProviderConfiguration.defaultGoogleModel,
                provider: .google
            )
        case .other:
            ProviderConfiguration(endpoint: "", model: "", provider: .other)
        }
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
        recordLegacyKeyOwnerIfNeeded()
        // 接続先を切り替える前に、provider未記録の旧利用統計を現在の接続先へ確定させる。
        let migratedUsageData: Data?
        if let usageData = defaults.data(forKey: Key.usageStatistics),
           let rows = (try? JSONSerialization.jsonObject(with: usageData)) as? [[String: Any]],
           rows.contains(where: { $0["provider"] == nil }) {
            migratedUsageData = try encoder.encode(loadUsageStatistics())
        } else {
            migratedUsageData = nil
        }

        var configurations = (defaults.data(forKey: Key.providerConfigurations)
            .flatMap { try? decoder.decode([String: ProviderConfiguration].self, from: $0) }) ?? [:]
        if let previousData = defaults.data(forKey: Key.providerConfiguration),
           let previous = try? decoder.decode(ProviderConfiguration.self, from: previousData) {
            let normalizedPrevious = previous.normalized
            if configurations[normalizedPrevious.provider.rawValue] == nil {
                configurations[normalizedPrevious.provider.rawValue] = normalizedPrevious
            }
        }
        configurations[configuration.provider.rawValue] = configuration

        let data = try encoder.encode(configuration)
        let allData = try encoder.encode(configurations)
        if let migratedUsageData {
            defaults.set(migratedUsageData, forKey: Key.usageStatistics)
        }
        defaults.set(allData, forKey: Key.providerConfigurations)
        defaults.set(data, forKey: Key.providerConfiguration)
    }

    /// 旧単一Keychain項目(`account = "default"`)を所有していたエンドポイント。
    /// 新規環境や移行完了後は`nil`を返し、別サービスへの付け替えを防ぐ。
    func legacyKeyOwnerEndpoint() -> String? {
        if let recorded = defaults.string(forKey: Key.legacyAPIKeyOwnerEndpoint) {
            return recorded.isEmpty ? nil : recorded
        }
        guard defaults.data(forKey: Key.providerConfigurations) == nil,
              let data = defaults.data(forKey: Key.providerConfiguration),
              let configuration = try? decoder.decode(ProviderConfiguration.self, from: data) else {
            return nil
        }
        return configuration.normalized.endpoint
    }

    func clearLegacyKeyOwnerEndpoint() {
        defaults.set("", forKey: Key.legacyAPIKeyOwnerEndpoint)
    }

    private func recordLegacyKeyOwnerIfNeeded() {
        guard defaults.object(forKey: Key.legacyAPIKeyOwnerEndpoint) == nil else { return }
        if let owner = legacyKeyOwnerEndpoint() {
            defaults.set(owner, forKey: Key.legacyAPIKeyOwnerEndpoint)
        } else {
            defaults.set("", forKey: Key.legacyAPIKeyOwnerEndpoint)
        }
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

    func loadUsageStatistics() -> [ModelUsageStatistics] {
        guard let data = defaults.data(forKey: Key.usageStatistics),
              let statistics = try? decoder.decode([ModelUsageStatistics].self, from: data) else {
            return []
        }
        var migrated = statistics
        if let rawRows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            let legacyProvider = loadProviderConfiguration().provider
            for index in migrated.indices where index < rawRows.count {
                if rawRows[index]["provider"] == nil {
                    migrated[index].provider = legacyProvider
                }
            }
        }
        return migrated.sorted {
            $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    func recordUsage(
        _ usage: TokenUsage,
        model: String,
        provider: AIProvider = .openAI,
        at timestamp: Date = Date()
    ) {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { return }
        var statistics = loadUsageStatistics()
        let requestCost: Decimal? = if usage.unitemizedTokens == 0 {
            ModelPricing.pricing(for: normalizedModel, provider: provider, at: timestamp)?
                .estimatedCost(for: usage)
        } else {
            nil
        }

        if let index = statistics.firstIndex(where: { $0.model == normalizedModel && $0.provider == provider }) {
            let existingCost = statistics[index].estimatedCostUSD
            if statistics[index].collectionStartedAt == nil {
                statistics[index].collectionStartedAt = timestamp
            }
            statistics[index].conversionCount += 1
            statistics[index].inputTokens += usage.inputTokens
            statistics[index].cachedInputTokens += usage.cachedInputTokens
            statistics[index].outputTokens += usage.outputTokens
            statistics[index].unitemizedTokens += usage.unitemizedTokens
            if statistics[index].unitemizedTokens > 0 || requestCost == nil {
                statistics[index].recordedCostUSD = nil
            } else if let requestCost, let baseline = existingCost {
                statistics[index].recordedCostUSD = baseline + requestCost
            }
        } else {
            statistics.append(
                ModelUsageStatistics(
                    model: normalizedModel,
                    provider: provider,
                    conversionCount: 1,
                    inputTokens: usage.inputTokens,
                    cachedInputTokens: usage.cachedInputTokens,
                    outputTokens: usage.outputTokens,
                    unitemizedTokens: usage.unitemizedTokens,
                    collectionStartedAt: timestamp,
                    recordedCostUSD: requestCost
                )
            )
        }
        if let data = try? encoder.encode(statistics) {
            defaults.set(data, forKey: Key.usageStatistics)
        }
    }

    func resetUsageStatistics(at timestamp: Date = Date()) {
        let reset = loadUsageStatistics().map {
            ModelUsageStatistics(model: $0.model, provider: $0.provider, collectionStartedAt: timestamp)
        }
        if let data = try? encoder.encode(reset) {
            defaults.set(data, forKey: Key.usageStatistics)
        }
    }
}
