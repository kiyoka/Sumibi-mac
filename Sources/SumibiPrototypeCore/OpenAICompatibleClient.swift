import Foundation

public struct OpenAICompatibleConfiguration: Equatable, Sendable {
    public let endpoint: URL
    public let model: String
    public let apiKey: String
    public let timeout: TimeInterval

    /// タイムアウトの既定値は仕様どおり60秒。
    public init(endpoint: URL, model: String, apiKey: String, timeout: TimeInterval = 60) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.timeout = timeout
    }
}

/// OpenAI互換のchat completions APIへ変換を要求する。
///
/// リクエストの形、エンドポイントの補完、状態コードの分類はSumibi-iOSの`OpenAICompatibleClient`に合わせる。
/// コードは共有せず、macOS版として独立して実装する。
public struct OpenAICompatibleClient: ConversionService {
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        let model: String?
    }

    private struct Choice: Decodable {
        let message: Message
    }

    private let configuration: OpenAICompatibleConfiguration
    private let session: URLSession

    public init(configuration: OpenAICompatibleConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        try ConversionLimit.check(request)
        guard !configuration.apiKey.isEmpty else { throw ConversionError.apiKeyMissing }
        guard let url = Self.chatCompletionsURL(from: configuration.endpoint) else {
            throw ConversionError.invalidEndpoint
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: configuration.model,
                messages: [
                    Message(role: "system", content: PromptBuilder.systemMessage(for: request)),
                    Message(role: "user", content: PromptBuilder.userMessage(for: request)),
                ]
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw ConversionError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                throw ConversionError.offline
            default: throw ConversionError.network(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else { throw ConversionError.emptyResponse }
        try Self.validate(statusCode: http.statusCode)

        guard let chat = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw ConversionError.emptyResponse
        }
        let candidates = CandidateDecoder.normalize(
            chat.choices.flatMap { CandidateDecoder.decode($0.message.content) },
            limit: request.mode.candidateCount
        )
        guard !candidates.isEmpty else { throw ConversionError.emptyResponse }
        return ConversionResult(candidates: candidates, model: chat.model ?? configuration.model)
    }

    /// 利用者が入力したURLから、chat completionsの完全なURLを作る。
    public static func chatCompletionsURL(from baseURL: URL) -> URL? {
        guard let host = baseURL.host(), !host.isEmpty else { return nil }
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") { return baseURL }
        if path.hasSuffix("v1") {
            return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
        }
        return baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }

    static func validate(statusCode: Int) throws {
        switch statusCode {
        case 200 ..< 300: return
        case 401, 403: throw ConversionError.invalidCredentials
        case 429: throw ConversionError.rateLimited
        case 500 ..< 600: throw ConversionError.serverError(statusCode: statusCode)
        default: throw ConversionError.httpError(statusCode: statusCode)
        }
    }
}

/// 通信せずに固定の結果を返す。開発と試験に使う。
public struct MockConversionService: ConversionService {
    private let delay: TimeInterval
    private let succeeds: Bool

    public init(delay: TimeInterval = 0.6, succeeds: Bool = true) {
        self.delay = delay
        self.succeeds = succeeds
    }

    public func convert(_ request: ConversionRequest) async throws -> ConversionResult {
        try ConversionLimit.check(request)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard succeeds else { throw ConversionError.network("模擬失敗") }
        switch request.mode {
        case .first:
            return ConversionResult(candidates: [Self.mockFirst(request.source)])
        case .alternatives:
            let base = request.currentConversion ?? Self.mockFirst(request.source)
            return ConversionResult(candidates: [base] + (1 ... 10).map { "候補\($0)・\(base)" })
        }
    }

    private static func mockFirst(_ source: String) -> String {
        switch source.lowercased() {
        case "ohayou": "おはよう"
        case "arigatou": "ありがとう"
        default: "【\(source)】"
        }
    }
}
