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
        /// 代表モデルまたはGeminiモデルにだけ付ける。自由入力や未知の接続先には送らない(nilは要求に含めない)。
        let reasoningEffort: String?
        let verbosity: String?
        let temperature: Double?

        enum CodingKeys: String, CodingKey {
            case model, messages, verbosity, temperature
            case reasoningEffort = "reasoning_effort"
        }
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        let model: String?
        let usage: Usage?
    }

    private struct Choice: Decodable {
        let message: Message
    }

    private struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int?
        let promptTokensDetails: PromptTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    private struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
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
        urlRequest.httpBody = try Self.requestBody(
            for: request,
            model: configuration.model,
            endpoint: configuration.endpoint
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
        let usage = chat.usage.flatMap(Self.decodeUsage)
        return ConversionResult(
            candidates: candidates,
            model: chat.model ?? configuration.model,
            usage: usage
        )
    }

    private static func decodeUsage(_ usage: Usage) -> TokenUsage? {
        guard usage.promptTokens >= 0, usage.completionTokens >= 0 else { return nil }
        if let total = usage.totalTokens, total < 0 { return nil }
        let rawCached = usage.promptTokensDetails?.cachedTokens ?? 0
        guard rawCached >= 0, rawCached <= usage.promptTokens else {
            let unitemized = max(
                1,
                (usage.totalTokens ?? (usage.promptTokens + usage.completionTokens))
                    - usage.promptTokens - usage.completionTokens
            )
            return TokenUsage(
                inputTokens: usage.promptTokens,
                cachedInputTokens: 0,
                outputTokens: usage.completionTokens,
                unitemizedTokens: unitemized
            )
        }
        let unitemized = max(
            0,
            (usage.totalTokens ?? (usage.promptTokens + usage.completionTokens))
                - usage.promptTokens - usage.completionTokens
        )
        return TokenUsage(
            inputTokens: usage.promptTokens,
            cachedInputTokens: rawCached,
            outputTokens: usage.completionTokens,
            unitemizedTokens: unitemized
        )
    }

    /// 要求の本文。接続先とモデルに応じて推論設定(`reasoning_effort`、`verbosity`、`temperature`)を付ける。
    /// OpenAI専用の設定値をGoogleや任意の互換サーバーへ無条件に流用しない。
    static func requestBody(
        for request: ConversionRequest,
        model: String,
        endpoint: URL = URL(string: ProviderConfiguration.defaultEndpoint)!
    ) throws -> Data {
        let options = requestOptions(for: model, endpoint: endpoint)
        return try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [
                    Message(role: "system", content: PromptBuilder.systemMessage(for: request)),
                    Message(role: "user", content: PromptBuilder.userMessage(for: request)),
                ],
                reasoningEffort: options.reasoningEffort,
                verbosity: options.verbosity,
                temperature: options.temperature
            )
        )
    }

    private static func requestOptions(
        for model: String,
        endpoint: URL
    ) -> (reasoningEffort: String?, verbosity: String?, temperature: Double?) {
        switch endpoint.host()?.lowercased() {
        case "generativelanguage.googleapis.com":
            guard let gemini = GeminiModelOption(model: model) else {
                return (nil, nil, nil)
            }
            return (gemini.reasoningEffort, nil, gemini.temperature)
        case "api.openai.com":
            guard let preset = ModelPreset(model: model) else {
                return (nil, nil, nil)
            }
            return (preset.reasoningEffort, preset.verbosity, nil)
        default:
            return (nil, nil, nil)
        }
    }

    /// 利用者が入力したURLから、chat completionsの完全なURLを作る。
    public static func chatCompletionsURL(from baseURL: URL) -> URL? {
        guard let host = baseURL.host(), !host.isEmpty else { return nil }
        let path = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") { return baseURL }
        if path.hasSuffix("v1beta/openai") || path.hasSuffix("v1") {
            return baseURL.appendingPathComponent("chat").appendingPathComponent("completions")
        }
        if host.lowercased() == "generativelanguage.googleapis.com" {
            let prefix = path == "v1beta" ? baseURL : baseURL.appendingPathComponent("v1beta")
            return prefix
                .appendingPathComponent("openai")
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
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
