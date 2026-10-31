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
    private let dictionary: SupplementalCandidateDictionary?

    init(settings: SettingsStore = SettingsStore(), keys: APIKeyStore = APIKeyStore(),
         responseMode: @escaping () -> String = { ConversionCoordinator.responseMode },
         dictionary: SupplementalCandidateDictionary? = nil,
         makeClient: @escaping (OpenAICompatibleConfiguration) -> any ConversionService = { OpenAICompatibleClient(configuration: $0) }) {
        self.settings = settings
        self.keys = keys
        readResponseMode = responseMode
        self.makeClient = makeClient
        self.dictionary = dictionary
    }

    private static let supplementalDictionary: SupplementalCandidateDictionary = {
        let homophones = Bundle.main.url(forResource: "SudachiCandidates", withExtension: "tsv")
            .flatMap { try? HomophoneDictionary(contentsOf: $0) }
        let symbols = Bundle.main.url(forResource: "MozcSymbols", withExtension: "tsv")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        // Missing either resource must not disable the other dictionary or middle dot.
        return SupplementalCandidateDictionary(symbolTSV: symbols, homophones: homophones)
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
        guard let apiKey = try? keys.load(for: configuration.endpoint, settings: settings), !apiKey.isEmpty else {
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
            let configuration = settings.loadProviderConfiguration()
            let result = try await service().convert(request)
            if let usage = result.usage {
                let recordedModel: String
                if let returned = result.model?.trimmingCharacters(in: .whitespacesAndNewlines), !returned.isEmpty {
                    recordedModel = returned
                } else {
                    recordedModel = configuration.model
                }
                settings.recordUsage(usage, model: recordedModel, provider: configuration.provider)
            }
            guard request.mode == .alternatives else {
                return .success(result)
            }
            // Load bundled indexes only when alternatives actually succeed, not on
            // the initial/manual or automatic conversion's latency-sensitive path.
            return .success((dictionary ?? Self.supplementalDictionary).supplement(result, source: request.source))
        } catch let error as ConversionError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
