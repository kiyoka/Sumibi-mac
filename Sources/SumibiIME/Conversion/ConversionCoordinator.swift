import Foundation
import SumibiCore

/// 設定とKeychainから変換の送信先を組み立て、要求を実行する。
///
/// 送信の前に、APIキーの有無とデータ送信への同意を確かめる。どちらか欠けていれば通信しない。
struct ConversionCoordinator {
    private let settings: SettingsStore
    private let keys: APIKeyStore
    private let readResponseMode: () -> String
    private let makeClient: (OpenAICompatibleConfiguration) -> any ConversionService

    init(settings: SettingsStore = SettingsStore(), keys: APIKeyStore = APIKeyStore(),
         responseMode: @escaping () -> String = { ConversionCoordinator.responseMode },
         makeClient: @escaping (OpenAICompatibleConfiguration) -> any ConversionService = { OpenAICompatibleClient(configuration: $0) }) {
        self.settings = settings
        self.keys = keys
        readResponseMode = responseMode
        self.makeClient = makeClient
    }

    private static let homophoneDictionary: HomophoneDictionary? = {
        guard let url = Bundle.main.url(forResource: "SudachiCandidates", withExtension: "tsv") else { return nil }
        return try? HomophoneDictionary(contentsOf: url)
    }()

    /// 明示的な開発版の模擬応答。通常版は保存済み設定に関係なくapiへ固定する。
    /// api(既定・実際に通信する)、success、slow、failure、timeout。
    private static var responseMode: String {
        DevelopmentOptions.current.responseMode
    }

    func service() throws -> any ConversionService {
        #if SUMIBI_DEVELOPMENT
        switch DevelopmentOptions.responseMode(readResponseMode()) {
        case "success": return MockConversionService(delay: 0.6, succeeds: true)
        case "slow": return MockConversionService(delay: 5.0, succeeds: true)
        case "failure": return MockConversionService(delay: 0.6, succeeds: false)
        case "timeout": return MockConversionService(delay: 60.0, succeeds: true)
        default: break
        }
        #endif

        let configuration = settings.loadProviderConfiguration()
        guard let endpoint = URL(string: configuration.endpoint), endpoint.host() != nil else {
            throw ConversionError.invalidEndpoint
        }
        guard let apiKey = try? keys.load(), !apiKey.isEmpty else {
            throw ConversionError.apiKeyMissing
        }
        guard settings.hasConsent(for: configuration.endpoint) else {
            throw ConversionError.consentMissing
        }
        return makeClient(
            OpenAICompatibleConfiguration(
                endpoint: endpoint,
                model: configuration.model,
                apiKey: apiKey
            )
        )
    }

    func convert(_ request: ConversionRequest) async -> Result<ConversionResult, ConversionError> {
        do {
            try ConversionLimit.check(request)
            let result = try await service().convert(request)
            guard request.mode == .alternatives, let dictionary = Self.homophoneDictionary else {
                return .success(result)
            }
            let combined = dictionary.supplement(result.candidates)
            return .success(ConversionResult(
                candidates: combined,
                model: result.model,
                dictionaryCandidates: Set(combined.dropFirst(result.candidates.count))
            ))
        } catch let error as ConversionError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
