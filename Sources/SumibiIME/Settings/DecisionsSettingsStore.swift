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

    func save(_ settings: DecisionsSettings) throws {
        guard settings.isValid else { throw DecisionsError.invalidSettings }
        defaults.set(try JSONEncoder().encode(settings), forKey: "decisionsSettings")
        touchRevision()
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
