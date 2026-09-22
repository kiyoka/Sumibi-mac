import Foundation

public enum ConversionMode: Equatable, Sendable {
    /// 初回変換。第一候補だけを取る。
    case first
    /// 追加候補。現在の変換結果を含めて取り直す。
    case alternatives

    public var candidateCount: Int {
        switch self {
        case .first: 1
        case .alternatives: 12
        }
    }
}

public struct ConversionRequest: Equatable, Sendable {
    public let source: String
    public let mode: ConversionMode
    public let currentConversion: String?

    public init(source: String, mode: ConversionMode = .first, currentConversion: String? = nil) {
        self.source = source
        self.mode = mode
        self.currentConversion = currentConversion
    }

    /// LLMへ送る可変部分の文字数。固定のシステムプロンプトは数えない。
    ///
    /// 仕様では、原文・周辺文脈・ユーザー辞書・変換指示・現在の変換結果を合わせて1要求あたり1,000文字までとする。
    /// 周辺文脈・ユーザー辞書・変換指示は未実装なので、いまは原文と現在の変換結果だけを数える。
    public var payloadCharacterCount: Int {
        source.count + (currentConversion?.count ?? 0)
    }
}

public struct ConversionResult: Equatable, Sendable {
    public let candidates: [String]
    public let model: String?

    public init(candidates: [String], model: String? = nil) {
        self.candidates = candidates
        self.model = model
    }
}

public enum ConversionError: Error, Equatable, Sendable {
    case apiKeyMissing
    case consentMissing
    case overLimit(count: Int, limit: Int)
    case invalidEndpoint
    case invalidCredentials
    case rateLimited
    case serverError(statusCode: Int)
    case httpError(statusCode: Int)
    case emptyResponse
    case timedOut
    case offline
    case network(String)

    /// 利用者へ見せる短い説明。原文やAPIキーは含めない。
    public var message: String {
        switch self {
        case .apiKeyMissing: "APIキーが未設定です。Sumibi設定で登録してください。"
        case .consentMissing: "Sumibi設定で、AIへのデータ送信に同意してください。"
        case .overLimit(let count, let limit): "変換対象が\(limit)文字を超えています（\(count)文字）。"
        case .invalidEndpoint: "APIのURLが正しくありません。Sumibi設定で確認してください。"
        case .invalidCredentials: "APIキーを確認してください。"
        case .rateLimited: "APIの利用上限に達しました。しばらく待って試してください。"
        case .serverError(let code): "APIサーバーでエラーが発生しました（\(code)）。"
        case .httpError(let code): "APIがエラーを返しました（\(code)）。"
        case .emptyResponse: "APIから変換結果を取得できませんでした。"
        case .timedOut: "変換がタイムアウトしました。"
        case .offline: "ネットワークに接続できません。"
        case .network(let detail): "通信に失敗しました（\(detail)）。"
        }
    }

    /// 同じ操作をやり直す価値があるか。
    public var isRetryable: Bool {
        switch self {
        case .apiKeyMissing, .consentMissing, .overLimit, .invalidEndpoint, .invalidCredentials: false
        case .rateLimited, .serverError, .httpError, .emptyResponse, .timedOut, .offline, .network: true
        }
    }
}

public protocol ConversionService: Sendable {
    func convert(_ request: ConversionRequest) async throws -> ConversionResult
}

/// 送信するテキストの上限。仕様の1要求あたり1,000文字。
public enum ConversionLimit {
    public static let maximumCharacterCount = 1_000

    public static func check(_ request: ConversionRequest) throws {
        let count = request.payloadCharacterCount
        guard count <= maximumCharacterCount else {
            throw ConversionError.overLimit(count: count, limit: maximumCharacterCount)
        }
    }
}

/// LLMへ渡すメッセージを組み立てる。文面はSumibi-iOSの`OpenAICompatibleClient`に合わせる。コードは共有しない。
public enum PromptBuilder {
    public static func systemMessage(for request: ConversionRequest) -> String {
        """
        あなたはローマ字と英語を、通常は自然な日本語へ変換するIMEです。ユーザーによる追加の変換指示で出力言語が指定された場合は、その言語へ翻訳してください。
        Markdown記法、URL、固有名詞は可能な限り維持してください。
        入力にない情報は追加しないでください。
        ユーザー辞書は登録されていません。
        ユーザーによる追加の変換指示はありません。
        \(candidateInstructions(for: request))
        JSON以外の説明やMarkdownのコードフェンスは返さないでください。
        """
    }

    public static func userMessage(for request: ConversionRequest) -> String {
        """
        周辺文脈：


        現在の変換結果：
        \(request.currentConversion ?? "なし")

        変換対象：
        \(request.source)
        """
    }

    private static func candidateInstructions(for request: ConversionRequest) -> String {
        switch request.mode {
        case .alternatives:
            """
            内容と表記が重複しない候補を、次の順序で最大12件作り、{"candidates":["候補1","候補2"]}という形式のJSONだけを返してください。
            1. 「現在の変換結果」をそのまま使用した候補
            2. 変換対象の読みに同音異義語がある場合、「現在の変換結果」とは意味または漢字表記が異なる自然な候補を最大5件。単語だけの入力では文脈を限定しすぎず、「hashi」なら「橋」「箸」「端」などをなるべく多く含める。文章では該当箇所以外を維持し、周辺文脈から著しく外れる候補は除く。同音異義語が少ない場合は、数を満たすために不自然な候補を作らない
            3. QWERTYキーボードから入力されたものとみなし、入力意図を最大限推測してタイプミスを修正した自然な日本語の文章。隣接キーの押し間違い、文字の抜け・重複・順序違いを文脈から補正する
            4. 全文をひらがなにした候補（句読点は維持）
            5. 全文をカタカナにした候補（句読点は維持）
            6. 可能な限り漢字を多く使った候補
            7. 可能な限り送り仮名をひらいた候補
            8. 自然な英語へ翻訳した候補
            """
        case .first:
            """
            ユーザーによる追加の変換指示がある場合はそれを反映し、ない場合は文脈に最も自然な日本語変換を1件だけ作ってください。{"candidates":["候補1"]}というJSONだけを返してください。
            """
        }
    }
}

/// LLMの返答から候補を取り出す。JSON以外が返ることがあるため、いくつかの形を試す。
public enum CandidateDecoder {
    private struct Payload: Decodable { let candidates: [String] }

    public static func decode(_ content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let candidates = decodeJSON(trimmed) { return candidates }
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last,
           let candidates = decodeJSON(String(trimmed[first ... last])) {
            return candidates
        }
        if let first = trimmed.firstIndex(of: "["), let last = trimmed.lastIndex(of: "]"), first <= last,
           let candidates = decodeJSON(String(trimmed[first ... last])) {
            return candidates
        }
        return [trimmed]
    }

    /// 空要素と重複を取り除き、必要な件数までに切り詰める。
    public static func normalize(_ candidates: [String], limit: Int) -> [String] {
        candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { unique, candidate in
                if !unique.contains(candidate) { unique.append(candidate) }
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func decodeJSON(_ json: String) -> [String]? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(Payload.self, from: data) { return payload.candidates }
        return try? decoder.decode([String].self, from: data)
    }
}
