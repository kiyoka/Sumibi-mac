import Foundation

/// 設定画面で選べるAI接続先。
///
/// 選択肢と既定エンドポイントはSumibi-iOS PR #137に合わせる(Sumibi-iOS#135)。コードは共有しない。
public enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI, google, other

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .google: "Google"
        case .other: "その他"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .openAI: ProviderConfiguration.defaultEndpoint
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .other: ""
        }
    }

    /// 保存済みの旧設定に`provider`がない場合、URLのホストから接続先を判定する。
    public static func inferred(from endpoint: String) -> AIProvider {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .openAI }
        guard let host = URL(string: trimmed)?.host()?.lowercased(), !host.isEmpty else {
            return .other
        }
        switch host {
        case "api.openai.com": return .openAI
        case "generativelanguage.googleapis.com": return .google
        default: return .other
        }
    }
}

/// BYOK(利用者のAPIキーを使うOpenAI互換API)の送信先設定。
///
/// 項目名と既定値はSumibi-iOSの`ProviderConfiguration`に合わせる。コードは共有しない。
/// APIキーはここに含めない。キーはKeychainへ保存する。
public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public static let defaultEndpoint = "https://api.openai.com"
    public static let defaultModel = ModelPreset.gpt6Sol.model
    public static let defaultGoogleModel = GeminiModelOption.quality.rawValue

    public var endpoint: String
    public var model: String
    public var provider: AIProvider

    public init(
        endpoint: String = Self.defaultEndpoint,
        model: String = Self.defaultModel,
        provider: AIProvider? = nil
    ) {
        self.endpoint = endpoint
        self.model = model
        self.provider = provider ?? AIProvider.inferred(from: endpoint)
    }

    public init(
        provider: AIProvider,
        endpoint: String,
        model: String
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
    }

    private enum CodingKeys: String, CodingKey { case endpoint, model, provider }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        provider = try values.decodeIfPresent(AIProvider.self, forKey: .provider)
            ?? AIProvider.inferred(from: endpoint)
    }

    /// 前後の空白を取り除き、空になった項目は接続先の既定値へ戻したもの。
    public var normalized: ProviderConfiguration {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackEndpoint = provider.defaultEndpoint
        let fallbackModel: String
        switch provider {
        case .openAI: fallbackModel = Self.defaultModel
        case .google: fallbackModel = Self.defaultGoogleModel
        case .other: fallbackModel = trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
        }
        return ProviderConfiguration(
            endpoint: trimmedEndpoint.isEmpty ? fallbackEndpoint : trimmedEndpoint,
            model: trimmedModel.isEmpty ? fallbackModel : trimmedModel,
            provider: provider
        )
    }
}

public enum ProviderConfigurationProblem: Equatable, Sendable {
    case endpointEmpty
    /// URLとして解釈できない、またはホストがない。
    case endpointNotAURL
    /// `http`でローカル以外へ送ろうとしている。APIキーが平文で流れるため許可しない。
    case endpointInsecure
    case endpointUnsupportedScheme(String)
    case modelEmpty

    public var message: String {
        switch self {
        case .endpointEmpty: "APIのURLを入力してください。"
        case .endpointNotAURL: "APIのURLとして解釈できません。例: https://api.openai.com"
        case .endpointInsecure: "httpは、localhost以外へは使えません。httpsを指定してください。"
        case .endpointUnsupportedScheme(let scheme): "\(scheme)は使えません。httpsを指定してください。"
        case .modelEmpty: "モデル名を入力してください。"
        }
    }
}

extension ProviderConfiguration {
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// 入力内容の問題を返す。空なら保存してよい。
    public func problems() -> [ProviderConfigurationProblem] {
        var problems: [ProviderConfigurationProblem] = []
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEndpoint.isEmpty {
            problems.append(.endpointEmpty)
        } else if let url = URL(string: trimmedEndpoint), let host = url.host(), !host.isEmpty {
            switch url.scheme?.lowercased() {
            case "https":
                break
            case "http":
                // 手元で動かすLLMサーバーを試せるよう、localhostに限り許す。
                if !Self.localHosts.contains(host.lowercased()) { problems.append(.endpointInsecure) }
            case let scheme?:
                problems.append(.endpointUnsupportedScheme(scheme))
            case nil:
                problems.append(.endpointNotAURL)
            }
        } else {
            problems.append(.endpointNotAURL)
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append(.modelEmpty)
        }
        return problems
    }
}

/// 保存済みのAPIキーを画面へ出すための伏せ字。キーそのものは表示しない。
public enum APIKeyDisplay {
    public static func masked(for apiKey: String) -> String? {
        guard !apiKey.isEmpty else { return nil }
        // Fixed-width mask: long keys must not produce several lines of bullets.
        // Short keys are fully hidden rather than displayed in their entirety.
        guard apiKey.count > 4 else { return "****" }
        return "****" + apiKey.suffix(4)
    }

    /// 入力されたAPIキーとして受け付けられるか。前後の空白は取り除いてから渡す。
    public static func isAcceptable(_ apiKey: String) -> Bool {
        !apiKey.isEmpty && !apiKey.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}
