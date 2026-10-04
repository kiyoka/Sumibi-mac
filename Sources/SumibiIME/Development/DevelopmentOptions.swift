import Foundation

/// The only reader of experimental preferences. Production ignores even stale values.
struct DevelopmentOptions {
    static var isEnabled: Bool {
        #if SUMIBI_DEVELOPMENT
        return true
        #else
        return false
        #endif
    }

    let responseMode: String
    let diagnoseText: Bool
    let pokeStyle: String

    static var current: Self { Self(defaults: .standard) }

    init(defaults: UserDefaults) {
        #if SUMIBI_DEVELOPMENT
        responseMode = Self.responseMode(defaults.string(forKey: "PrototypeResponseMode"))
        diagnoseText = defaults.bool(forKey: "PrototypeDiagnoseText")
        let requested = defaults.string(forKey: "PrototypePokeStyle") ?? "marked"
        pokeStyle = ["marked", "insert", "both", "off"].contains(requested) ? requested : "marked"
        #else
        responseMode = "api"
        diagnoseText = false
        pokeStyle = "marked"
        #endif
    }

    static func responseMode(_ requested: String?) -> String {
        #if SUMIBI_DEVELOPMENT
        let mode = requested ?? "api"
        return ["api", "success", "slow", "failure", "timeout"].contains(mode) ? mode : "api"
        #else
        return "api"
        #endif
    }
}
