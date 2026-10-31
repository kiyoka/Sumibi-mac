import Foundation

/// 接続先とモデルごとの変換API利用統計。
///
/// 原文・変換候補・APIキーは含めない。Decisions自動変換のHTTP通信回数とは区別する。
public struct ModelUsageStatistics: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(provider.rawValue):\(model)" }

    public let model: String
    public var provider: AIProvider
    public var conversionCount: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var unitemizedTokens: Int
    public var collectionStartedAt: Date?
    public var recordedCostUSD: Decimal?

    public init(
        model: String,
        provider: AIProvider = .openAI,
        conversionCount: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        unitemizedTokens: Int = 0,
        collectionStartedAt: Date? = nil,
        recordedCostUSD: Decimal? = nil
    ) {
        self.model = model
        self.provider = provider
        self.conversionCount = conversionCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.unitemizedTokens = unitemizedTokens
        self.collectionStartedAt = collectionStartedAt
        self.recordedCostUSD = recordedCostUSD
    }

    private enum CodingKeys: String, CodingKey {
        case model, provider, conversionCount
        case inputTokens, cachedInputTokens, outputTokens, unitemizedTokens
        case collectionStartedAt, recordedCostUSD
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        model = try values.decode(String.self, forKey: .model)
        provider = try values.decodeIfPresent(AIProvider.self, forKey: .provider) ?? .openAI
        conversionCount = try values.decode(Int.self, forKey: .conversionCount)
        inputTokens = try values.decode(Int.self, forKey: .inputTokens)
        cachedInputTokens = try values.decode(Int.self, forKey: .cachedInputTokens)
        outputTokens = try values.decode(Int.self, forKey: .outputTokens)
        unitemizedTokens = try values.decodeIfPresent(Int.self, forKey: .unitemizedTokens) ?? 0
        collectionStartedAt = try values.decodeIfPresent(Date.self, forKey: .collectionStartedAt)
        recordedCostUSD = try values.decodeIfPresent(Decimal.self, forKey: .recordedCostUSD)
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + unitemizedTokens
    }

    public var estimatedCostUSD: Decimal? {
        guard unitemizedTokens == 0 else { return nil }
        if let recordedCostUSD { return recordedCostUSD }
        return ModelPricing.pricing(for: model, provider: provider)?
            .estimatedCost(for: TokenUsage(
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                outputTokens: outputTokens
            ))
    }
}

/// OpenAIおよびGoogleの有料Standard料金（100万トークンあたりUSD、2026-10-31確認）。
///
/// - OpenAI Standard料金: https://platform.openai.com/docs/pricing
/// - Google Gemini API Paid tier Standard料金: https://ai.google.dev/gemini-api/docs/pricing
///   - `gemini-3.6-flash`: 2026-12-31まで導入価格（入力$0.75 / キャッシュ入力$0.075 / 出力$3.75）、
///     2027-01-01T00:00:00Z以降標準価格（入力$1.50 / キャッシュ入力$0.15 / 出力$7.50）
///   - `gemini-3.5-flash-lite`: 入力$0.30 / キャッシュ入力$0.03 / 出力$2.50
public struct ModelPricing: Equatable, Sendable {
    public let input: Decimal
    public let cachedInput: Decimal
    public let output: Decimal

    /// Gemini 3.6 Flashの導入価格が終了し標準価格へ切り替わる日時（2027-01-01T00:00:00Z）。
    public static let gemini36FlashStandardPricingStartDate = Date(timeIntervalSince1970: 1_798_761_600)

    public func estimatedCost(for usage: TokenUsage) -> Decimal {
        let cached = min(max(0, usage.cachedInputTokens), max(0, usage.inputTokens))
        let uncached = max(0, usage.inputTokens) - cached
        let output = max(0, usage.outputTokens)
        return (
            Decimal(uncached) * input
                + Decimal(cached) * cachedInput
                + Decimal(output) * self.output
        ) / 1_000_000
    }

    public static func pricing(for model: String, provider: AIProvider, at date: Date = Date()) -> ModelPricing? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .google:
            if normalized == GeminiModelOption.quality.rawValue {
                let introductory = date < gemini36FlashStandardPricingStartDate
                return introductory
                    ? ModelPricing(input: Decimal(string: "0.75")!, cachedInput: Decimal(string: "0.075")!, output: Decimal(string: "3.75")!)
                    : ModelPricing(input: Decimal(string: "1.5")!, cachedInput: Decimal(string: "0.15")!, output: Decimal(string: "7.5")!)
            }
            if normalized == GeminiModelOption.economy.rawValue {
                return ModelPricing(input: Decimal(string: "0.3")!, cachedInput: Decimal(string: "0.03")!, output: Decimal(string: "2.5")!)
            }
            return nil
        case .openAI:
            if normalized == "gpt-6-sol" || normalized.hasPrefix("gpt-6-sol-") {
                return ModelPricing(input: 2, cachedInput: Decimal(string: "0.2")!, output: 10)
            }
            if normalized == "gpt-6-luna" || normalized.hasPrefix("gpt-6-luna-") {
                return ModelPricing(input: Decimal(string: "0.1")!, cachedInput: Decimal(string: "0.01")!, output: Decimal(string: "0.5")!)
            }
            if normalized == "gpt-5.6-sol" || normalized.hasPrefix("gpt-5.6-sol-") {
                return ModelPricing(input: 4, cachedInput: Decimal(string: "0.4")!, output: 20)
            }
            if normalized == "gpt-5.6-terra" || normalized.hasPrefix("gpt-5.6-terra-") {
                return ModelPricing(input: 2, cachedInput: Decimal(string: "0.2")!, output: 12)
            }
            return nil
        case .other:
            return nil
        }
    }
}
