import Foundation

/// Persistable preferences only. Credentials and observations never belong here.
public struct DecisionsSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var consent = false
    public var model = "gpt-6-luna"
    public var threshold = 0.5
    public var timeout: TimeInterval = 10
    public var maximumCharacters = 512
    public var maximumCalls = 10_000
    public var batchWindowMilliseconds = 200

    public init() {}

    public var isValid: Bool {
        threshold.isFinite && (0...1).contains(threshold)
            && timeout.isFinite && timeout > 0 && timeout <= 60
            && maximumCharacters > 0 && maximumCharacters <= 512
            && maximumCalls > 0 && maximumCalls <= 1_000_000
            && model == "gpt-6-luna"
            && (0...1_000).contains(batchWindowMilliseconds)
    }

    /// Global toggle, as requested. Input safety exclusions belong to the IMK adapter.
    public var permitsSending: Bool { isValid && enabled && consent }
}

public struct DecisionsObservation: Equatable, Sendable {
    public let text: String
    public let latestKey: String

    /// Never truncate a target or join lines. A missing observation means manual conversion.
    public init?(text: String, latestKey: String, maximumCharacters: Int = 512) {
        guard !text.isEmpty, maximumCharacters > 0, maximumCharacters <= 512,
              text.count <= maximumCharacters,
              !text.contains(where: { $0.isNewline }),
              text.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }),
              latestKey.count == 1 || ["BACKSPACE", "EDIT"].contains(latestKey),
              !["!", "！"].contains(latestKey) else { return nil }
        self.text = text
        self.latestKey = latestKey
    }
}

public enum DecisionsError: Error, Equatable, Sendable {
    case missingKey, invalidSettings, invalidResponse, authentication, rateLimited
    case server, http, timedOut, offline, network, requestLimit, unsupportedProvider, refused

    public var message: String {
        switch self {
        case .missingKey: "OpenAI用の変換APIキーが未設定、または読み出せません。"
        case .invalidSettings: "Decisionsの設定が正しくありません。"
        case .invalidResponse: "Decisionsから有効な判定結果を取得できませんでした。"
        case .authentication: "OpenAI用APIキーの認証に失敗しました。親画面の変換用キーを確認してください。"
        case .rateLimited: "OpenAI APIの利用上限に達しました。"
        case .server: "OpenAI APIでサーバーエラーが発生しました。"
        case .http: "OpenAI APIがエラーを返しました。"
        case .timedOut: "Decisions判定がタイムアウトしました。"
        case .offline: "Decisions判定に必要なネットワークへ接続できません。"
        case .network: "Decisions判定の通信に失敗しました。"
        case .requestLimit: "Decisions判定回数の上限に達しました。費用を確認してリセットしてください。"
        case .unsupportedProvider: "自動判定には公式OpenAI接続先が必要です。Googleやその他の接続先では利用できません。接続先をOpenAI（https://api.openai.com）に設定してください。"
        case .refused: "OpenAIがこの入力の自動判定を拒否しました。入力は変更していません。手動変換を試してください。"
        }
    }
}

public protocol DecisionsService: Sendable {
    func score(_ observation: DecisionsObservation) async throws -> Double
    func scores(_ observations: [DecisionsObservation]) async throws -> [DecisionsAnswer]
}

public enum DecisionsAnswer: Equatable, Sendable {
    case probability(Double), refused
}

/// Only Sumibi's own single-line roman composition; never collect a document's context.
public enum AmbientText {
    public static func isEligible(_ source: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,'?-。、？　")
        return !source.isEmpty && source.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func request(source: String, dictionary: String) -> ConversionRequest {
        var roman = source.trimmingCharacters(in: .whitespaces)
        if let last = roman.last, ".,?。、？".contains(last) { roman.removeLast() }
        return ConversionRequest(source: roman, userDictionary: dictionary)
    }

    public static func decorate(_ result: ConversionResult, source: String) -> ConversionResult {
        let last = source.trimmingCharacters(in: .whitespaces).last
        let suffix: String
        switch last {
        case "."?, "。"? : suffix = "。"
        case ","?, "、"? : suffix = "、"
        case "?"?, "？"? : suffix = "？"
        default: suffix = ""
        }
        let candidates = result.candidates.map { candidate -> String in
            var text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "" }
            if !suffix.isEmpty {
                while let last = text.last, ".,?。、？".contains(last) { text.removeLast() }
                text += suffix
            }
            return text
        }.filter { !$0.isEmpty }
        return ConversionResult(
            candidates: candidates,
            model: result.model,
            dictionaryCandidates: result.dictionaryCandidates,
            usage: result.usage
        )
    }
}
