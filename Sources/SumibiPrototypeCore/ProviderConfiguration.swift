import Foundation

/// BYOK(利用者のAPIキーを使うOpenAI互換API)の送信先設定。
///
/// 項目名と既定値はSumibi-iOSの`ProviderConfiguration`に合わせる。コードは共有しない。
/// APIキーはここに含めない。キーはKeychainへ保存する。
public struct ProviderConfiguration: Codable, Equatable, Sendable {
    public static let defaultEndpoint = "https://api.openai.com"
    public static let defaultModel = "gpt-5.6-terra"

    public var endpoint: String
    public var model: String

    public init(endpoint: String = Self.defaultEndpoint, model: String = Self.defaultModel) {
        self.endpoint = endpoint
        self.model = model
    }

    /// 前後の空白を取り除き、空になった項目は既定値へ戻したもの。
    public var normalized: ProviderConfiguration {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderConfiguration(
            endpoint: trimmedEndpoint.isEmpty ? Self.defaultEndpoint : trimmedEndpoint,
            model: trimmedModel.isEmpty ? Self.defaultModel : trimmedModel
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
        guard apiKey.count > 4 else { return String(repeating: "•", count: apiKey.count) }
        let suffix = apiKey.suffix(4)
        return String(repeating: "•", count: apiKey.count - suffix.count) + suffix
    }

    /// 入力されたAPIキーとして受け付けられるか。前後の空白は取り除いてから渡す。
    public static func isAcceptable(_ apiKey: String) -> Bool {
        !apiKey.isEmpty && !apiKey.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}
