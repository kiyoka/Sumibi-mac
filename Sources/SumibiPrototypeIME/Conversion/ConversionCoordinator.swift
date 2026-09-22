import Foundation
import SumibiPrototypeCore

/// 設定とKeychainから変換の送信先を組み立て、要求を実行する。
///
/// 送信の前に、APIキーの有無とデータ送信への同意を確かめる。どちらか欠けていれば通信しない。
struct ConversionCoordinator {
    private let settings = SettingsStore()
    private let keys = APIKeyStore()

    /// 開発用の模擬応答。`defaults write dev.kiyoka.inputmethod.SumibiPrototypeProbe1 PrototypeResponseMode -string <mode>`で使う。
    /// api(既定・実際に通信する)、success、slow、failure、timeout。
    private static var responseMode: String {
        UserDefaults.standard.string(forKey: "PrototypeResponseMode") ?? "api"
    }

    static var usesMock: Bool { responseMode != "api" }

    func service() throws -> any ConversionService {
        switch Self.responseMode {
        case "success": return MockConversionService(delay: 0.6, succeeds: true)
        case "slow": return MockConversionService(delay: 5.0, succeeds: true)
        case "failure": return MockConversionService(delay: 0.6, succeeds: false)
        case "timeout": return MockConversionService(delay: 60.0, succeeds: true)
        default: break
        }

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
        return OpenAICompatibleClient(
            configuration: OpenAICompatibleConfiguration(
                endpoint: endpoint,
                model: configuration.model,
                apiKey: apiKey
            )
        )
    }

    func convert(_ request: ConversionRequest) async -> Result<ConversionResult, ConversionError> {
        do {
            return .success(try await service().convert(request))
        } catch let error as ConversionError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
