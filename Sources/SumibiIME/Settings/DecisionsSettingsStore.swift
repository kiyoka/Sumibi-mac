import Foundation
import SumibiCore

/// Global persistent ceiling is stricter than per-document counts.
/// Short-lived IMK sessions, app/source switches and process restarts cannot reset it.
struct DecisionsSettingsStore {
    private let defaults: UserDefaults
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
              let settings = try? JSONDecoder().decode(DecisionsSettings.self, from: data),
              settings.isValid else { return DecisionsSettings() }
        return settings
    }

    func save(_ settings: DecisionsSettings, conversionEndpoint: String? = nil) throws {
        guard settings.isValid else { throw DecisionsError.invalidSettings }
        defaults.set(try JSONEncoder().encode(settings), forKey: "decisionsSettings")
        if settings.consent {
            let explicit = conversionEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
            let recorded = defaults.string(forKey: "decisionsConsentConversionEndpoint")
            let fallback = SettingsStore(defaults: defaults, prototypeDefaults: { nil }).loadProviderConfiguration().endpoint
            let target = (explicit?.isEmpty == false ? explicit : nil) ?? recorded ?? fallback
            if !target.isEmpty {
                defaults.set(target, forKey: "decisionsConsentConversionEndpoint")
            }
        } else {
            defaults.removeObject(forKey: "decisionsConsentConversionEndpoint")
        }
        touchRevision()
    }

    /// Decisionsの自動送信同意が、指定した変換接続先に対して与えられているか。
    /// 変換接続先を切り替えた場合は再同意が必要になる。
    func hasConsent(forConversionEndpoint endpoint: String) -> Bool {
        let normalized = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, load().consent else { return false }
        if let recorded = defaults.string(forKey: "decisionsConsentConversionEndpoint") {
            return recorded == normalized
        }
        return DecisionsCoordinator.isOfficialOpenAI(normalized)
    }

    /// 変換接続先が変更されたときに、自動変換をオフにし同意を取り直す状態へ戻す。
    func revokeConsentAndDisable() {
        var current = load()
        let hadActiveState = current.enabled || current.consent
            || defaults.object(forKey: "decisionsConsentConversionEndpoint") != nil
        current.enabled = false
        current.consent = false
        defaults.removeObject(forKey: "decisionsConsentConversionEndpoint")
        if hadActiveState, let encoded = try? JSONEncoder().encode(current) {
            defaults.set(encoded, forKey: "decisionsSettings")
            touchRevision()
        }
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
