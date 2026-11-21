import Foundation
import SumibiCore

/// Global persistent ceiling is stricter than per-document counts.
/// Short-lived IMK sessions, app/source switches and process restarts cannot reset it.
struct DecisionsSettingsStore {
    private let defaults: UserDefaults
    private static let geminiConsentKey = "geminiDecisionsConsentEndpoint"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> DecisionsSettings {
        if defaults.object(forKey: "decisionsSettings") == nil {
            // Carry only numeric preferences forward. Never transfer TypeSafe consent,
            // enablement, credentials or call counts to a different paid destination.
            var fresh = DecisionsSettings()
            if let data = defaults.data(forKey: "jevSettings"),
               let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let threshold = legacy["threshold"] as? Double, threshold.isFinite, (0...1).contains(threshold) {
                    fresh.threshold = threshold
                }
                if let limit = legacy["maximumCalls"] as? Int, (1...1_000_000).contains(limit) {
                    fresh.maximumCalls = limit
                }
            }
            if let encoded = try? JSONEncoder().encode(fresh) { defaults.set(encoded, forKey: "decisionsSettings") }
            return fresh
        }
        guard let data = defaults.data(forKey: "decisionsSettings"),
              var settings = try? JSONDecoder().decode(DecisionsSettings.self, from: data),
              settings.isValid else { return DecisionsSettings() }
        // #71 recorded consent to OpenAI scoring against the Google conversion URL.
        // It is not consent to send the same text to Gemini Decisions.
        if let endpoint = defaults.string(forKey: "decisionsConsentConversionEndpoint"),
           DecisionsCoordinator.isOfficialGoogle(endpoint) {
            settings.enabled = false
            settings.consent = false
            try? save(settings)
        }
        return settings
    }

    func save(_ settings: DecisionsSettings, conversionEndpoint: String? = nil, grantingConsent: Bool = false) throws {
        guard settings.isValid else { throw DecisionsError.invalidSettings }
        let encoded = try JSONEncoder().encode(settings)
        if settings.consent {
            let explicit = conversionEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
            let gemini = defaults.string(forKey: Self.geminiConsentKey)
            let recorded = defaults.string(forKey: "decisionsConsentConversionEndpoint") ?? gemini
            let fallback = SettingsStore(defaults: defaults, prototypeDefaults: { nil }).loadProviderConfiguration().endpoint
            let target = (explicit?.isEmpty == false ? explicit : nil) ?? recorded ?? fallback
            if DecisionsCoordinator.isOfficialGoogle(target) {
                guard grantingConsent || gemini == target else { throw DecisionsError.invalidSettings }
                // Older builds must not read a Gemini grant as consent to mixed routing.
                defaults.removeObject(forKey: "decisionsConsentConversionEndpoint")
                defaults.set(target, forKey: Self.geminiConsentKey)
            } else {
                guard DecisionsCoordinator.isOfficialOpenAI(target) else { throw DecisionsError.invalidSettings }
                defaults.removeObject(forKey: Self.geminiConsentKey)
                defaults.set(target, forKey: "decisionsConsentConversionEndpoint")
            }
        } else {
            defaults.removeObject(forKey: "decisionsConsentConversionEndpoint")
            defaults.removeObject(forKey: Self.geminiConsentKey)
        }
        defaults.set(encoded, forKey: "decisionsSettings")
        touchRevision()
    }

    /// Decisionsの自動送信同意が、指定した変換接続先に対して与えられているか。
    /// 変換接続先を切り替えた場合は再同意が必要になる。
    func hasConsent(forConversionEndpoint endpoint: String) -> Bool {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, load().consent else { return false }
        if DecisionsCoordinator.isOfficialGoogle(normalized) {
            return defaults.string(forKey: Self.geminiConsentKey) == normalized
        }
        guard DecisionsCoordinator.isOfficialOpenAI(normalized),
              defaults.object(forKey: Self.geminiConsentKey) == nil else { return false }
        return defaults.string(forKey: "decisionsConsentConversionEndpoint").map { $0 == normalized } ?? true
    }

    /// 変換接続先が変更されたときに、自動変換をオフにし同意を取り直す状態へ戻す。
    func revokeConsentAndDisable() {
        var current = load()
        let hadActiveState = current.enabled || current.consent
            || defaults.object(forKey: "decisionsConsentConversionEndpoint") != nil
        current.enabled = false
        current.consent = false
        defaults.removeObject(forKey: "decisionsConsentConversionEndpoint")
        defaults.removeObject(forKey: Self.geminiConsentKey)
        if hadActiveState { try? save(current) }
    }

    var revision: Int { defaults.integer(forKey: "decisionsSettingsRevision") }
    func touchRevision() {
        defaults.set(revision == Int.max ? 0 : revision + 1, forKey: "decisionsSettingsRevision")
    }

    var calls: Int { max(0, defaults.integer(forKey: "decisionsCallCount")) }

    /// All callers run on the main thread. Reserve immediately before a send.
    func reserve(limit: Int) -> Bool {
        guard limit > 0, calls < limit else { return false }
        defaults.set(calls + 1, forKey: "decisionsCallCount")
        return true
    }

    func resetCalls() { defaults.removeObject(forKey: "decisionsCallCount") }
}
