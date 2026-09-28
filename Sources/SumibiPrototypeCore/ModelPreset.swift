import Foundation

/// 設定画面で選べる代表的なモデルと、モデルごとに要求へ付ける設定。
///
/// 選択肢と指定する値はSumibi-iOSに合わせる(Sumibi-iOS#112)。コードは共有しない。
/// 指定する値は、Sumibiのベンチマークと同じ低遅延の条件にそろえる。
public enum ModelPreset: String, CaseIterable, Identifiable, Sendable {
    case gpt6Sol = "gpt-6-sol"
    case gpt6Luna = "gpt-6-luna"
    case gpt56Terra = "gpt-5.6-terra"

    public var id: String { rawValue }

    /// APIへ送るモデル名。
    public var model: String { rawValue }

    public var displayName: String {
        switch self {
        case .gpt6Sol: "GPT-6 Sol"
        case .gpt6Luna: "GPT-6 Luna"
        case .gpt56Terra: "GPT-5.6 Terra"
        }
    }

    public var summary: String {
        switch self {
        case .gpt6Sol: "既定・精度重視"
        case .gpt6Luna: "低コスト・高速重視"
        case .gpt56Terra: "旧既定"
        }
    }

    /// 思考を止めて応答を速くする。
    public var reasoningEffort: String? { "none" }

    public var verbosity: String? {
        switch self {
        case .gpt6Sol, .gpt6Luna: "low"
        case .gpt56Terra: nil
        }
    }

    /// モデル名に一致する代表モデル。自由入力のモデル名ならnil。
    public init?(model: String) {
        self.init(rawValue: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension ProviderConfiguration {
    /// 以前の既定モデル。保存済みの設定がこれなら、一度だけ新しい既定へ移す。
    public static let legacyDefaultModel = ModelPreset.gpt56Terra.model

    /// 以前の既定モデル(GPT-5.6 Terra)の設定を、新しい既定モデル(GPT-6 Sol)へ移したもの。
    /// 移行は一度だけ行う。移行後に利用者がGPT-5.6 Terraを選び直したら、そのままにする。
    public func migratingLegacyDefaultModel(alreadyMigrated: Bool) -> ProviderConfiguration {
        guard !alreadyMigrated,
              model.trimmingCharacters(in: .whitespacesAndNewlines) == Self.legacyDefaultModel else { return self }
        return ProviderConfiguration(endpoint: endpoint, model: Self.defaultModel)
    }
}
