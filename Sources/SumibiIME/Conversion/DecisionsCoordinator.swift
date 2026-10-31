import Foundation
import SumibiCore

struct AmbientWork {
    let score: (DecisionsObservation) async throws -> Double
    let convert: () async -> Result<ConversionResult, ConversionError>
    let remainsAuthorized: () -> Bool
    var scoreBatch: (([DecisionsObservation]) async throws -> [DecisionsAnswer])? = nil
}

/// Preparing work never sends. Both providers' consent/keys are checked before Decisions sends.
struct DecisionsCoordinator {
    let store: DecisionsSettingsStore
    let manualSettings: SettingsStore
    let keys: APIKeyStore
    let conversion: ConversionCoordinator
    let makeDecisions: (String, DecisionsSettings) -> any DecisionsService

    init(store: DecisionsSettingsStore = DecisionsSettingsStore(), manualSettings: SettingsStore = SettingsStore(),
         keys: APIKeyStore = APIKeyStore(),
         conversion: ConversionCoordinator = ConversionCoordinator(),
         makeDecisions: @escaping (String, DecisionsSettings) -> any DecisionsService = { DecisionsClient(key: $0, settings: $1) }) {
        self.store = store
        self.manualSettings = manualSettings
        self.keys = keys
        self.conversion = conversion
        self.makeDecisions = makeDecisions
    }

    func prepare(observation: DecisionsObservation, settings: DecisionsSettings) throws -> AmbientWork {
        guard settings.permitsSending, store.load() == settings else { throw DecisionsError.invalidSettings }
        let provider = manualSettings.loadProviderConfiguration()
        guard Self.isSupportedConversionProvider(provider) else {
            throw DecisionsError.unsupportedProvider
        }
        guard store.hasConsent(forConversionEndpoint: provider.endpoint) else {
            throw DecisionsError.invalidSettings
        }
        guard manualSettings.hasConsent(for: provider.endpoint) else { throw ConversionError.consentMissing }
        let dictionary = manualSettings.loadUserDictionary()
        let request = AmbientText.request(source: observation.text, dictionary: dictionary)
        try ConversionLimit.check(request)
        _ = try conversion.service()
        guard let key = try? keys.load(for: ProviderConfiguration.defaultEndpoint, settings: manualSettings), !key.isEmpty else {
            throw DecisionsError.missingKey
        }
        let decisions = makeDecisions(key, settings)
        let revision = store.revision
        return AmbientWork(
            score: { try await decisions.score($0) },
            convert: { await conversion.convert(request) },
            remainsAuthorized: {
                store.revision == revision && store.load() == settings
                    && store.hasConsent(forConversionEndpoint: provider.endpoint)
                    && manualSettings.loadProviderConfiguration() == provider
                    && manualSettings.loadUserDictionary() == dictionary
                    && manualSettings.hasConsent(for: provider.endpoint)
            }, scoreBatch: { try await decisions.scores($0) })
    }

    static func isSupportedConversionProvider(_ configuration: ProviderConfiguration) -> Bool {
        switch configuration.provider {
        case .openAI:
            isOfficialOpenAI(configuration.endpoint)
        case .google:
            isOfficialGoogle(configuration.endpoint)
        case .other:
            false
        }
    }

    static func isOfficialOpenAI(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.openai.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil && ["", "/", "/v1", "/v1/"].contains(url.path)
    }

    static func isOfficialGoogle(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "generativelanguage.googleapis.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && ["/v1beta/openai", "/v1beta/openai/"].contains(url.path)
    }
}
