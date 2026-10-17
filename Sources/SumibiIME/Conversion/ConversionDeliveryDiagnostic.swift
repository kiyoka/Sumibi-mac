import Foundation

/// Fixed classifications and counts only. No input/response text is retained here.
enum ConversionDeliveryStage: String {
    case sourceRead = "原文の読み取り（自動判定前）"
    case committedSource = "原文確定後の確認"
    case targetValidation = "変換結果の適用前・範囲照合"
    case replacement = "変換結果の置換"
    case resultVerification = "置換後の結果確認"
}

enum ConversionResultReadback: Equatable {
    case matching, unavailable, lengthMismatch(Int), mismatch
}

/// App compatibility guidance, not a new conversion limit or a confirmed universal cutoff.
/// Static copy only: do not include a runtime bundle name or user input.
enum LongInputGuidance {
    static let explanations = [
        "一部のアプリでは、100文字以上のローマ字の文章を変換できない場合があります。",
        "Codexアプリで確認されています（原文全文を読み取れないため）。",
        "確定済みの長文は、変換対象だけを選択してCtrl＋Jを試す方法もあります。"
    ]
    static let advice = "100文字未満の短い区切りで、こまめに変換してください。"

    static func forReadFailure(sourceCharacters: Int, unreadable: Bool) -> [String] {
        sourceCharacters >= 100 && unreadable ? explanations : []
    }
}

enum ReplacementValidationFailure: Equatable {
    // These indicate a normal cancellation, not a delivery error.
    case requestChanged, selectionChanged
    case trackingUnavailable, rangeUnavailable, sourceUnavailable
    case lengthMismatch(expected: Int, actual: Int)
    case sourceMismatch

    var isCancellation: Bool {
        self == .requestChanged || self == .selectionChanged
    }

    var message: String {
        switch self {
        case .requestChanged: return "変換要求が取り消されたか、別の要求に変わりました。"
        case .selectionChanged: return "選択位置が変わったため、変換結果を適用していません。"
        case .trackingUnavailable: return "置換対象の記録を取得できず、結果を適用していません。"
        case .rangeUnavailable: return "置換対象の範囲を確認できず、結果を適用していません。"
        case .sourceUnavailable: return "原文を読み取れず、結果を適用していません。入力先側の原因は未特定です。"
        case .lengthMismatch: return "原文の取得長が要求した範囲と一致しません。読取制限・折り返し等の原因は未特定です。"
        case .sourceMismatch: return "取得した文字列が原文と一致せず、結果を適用していません。座標変化等の原因は未特定です。"
        }
    }
}

extension ConversionNotice {
    static func resultConfirmation(_ readback: ConversionResultReadback, sourceCharacters: Int,
                                   sourceUTF16: Int, expectedUTF16: Int) -> Self {
        let cause: String
        var details = "対象 \(sourceCharacters)文字／UTF-16 \(sourceUTF16)、結果の読取要求 \(expectedUTF16)（UTF-16）、確認期限 0.5秒"
        switch readback {
        case .unavailable: cause = "置換後の文字列を時間内に読み取れませんでした。"
        case .lengthMismatch(let actual):
            cause = "置換後に取得した文字列の長さが、変換結果の長さと時間内に一致しませんでした。"
            details += "、取得 \(actual)（UTF-16）"
        case .mismatch: cause = "置換後に取得した文字列が、変換結果と時間内に一致しませんでした。"
        case .matching: cause = "置換後の変換結果を確認できませんでした。"
        }
        return Self(title: "変換結果を確認できませんでした", message: cause,
            advice: "入力欄を確認してください。変換済みなら再変換せず、エラー表示を解除してください。表示遅延・読取制限等の原因は未特定です。",
            stage: ConversionDeliveryStage.resultVerification.rawValue, details: details)
    }

    static func delivery(_ failure: ReplacementValidationFailure, stage: ConversionDeliveryStage,
                         sourceCharacters: Int, sourceUTF16: Int) -> Self {
        var details = "対象 \(sourceCharacters)文字／UTF-16 \(sourceUTF16)"
        if case .lengthMismatch(let expected, let actual) = failure {
            details += "、読取要求 \(expected)／取得 \(actual)（UTF-16）"
        }
        let unreadable: Bool
        switch failure {
        case .sourceUnavailable: unreadable = true
        case .lengthMismatch(let expected, let actual): unreadable = actual < expected
        default: unreadable = false
        }
        let explanations = LongInputGuidance.forReadFailure(sourceCharacters: sourceCharacters, unreadable: unreadable)
        return Self(title: stage == .sourceRead ? "自動変換の原文を確認できませんでした" : "変換結果を適用できませんでした", message: failure.message,
            advice: explanations.isEmpty ? "原文を確認し、短く区切るか、変換対象だけを確定・選択してCtrl＋Jを試してください。" : LongInputGuidance.advice,
            stage: stage.rawValue, details: details, explanations: explanations)
    }

    static func ambientDelivery(_ failure: AmbientDeliveryFailure, sourceCharacters: Int, sourceUTF16: Int) -> Self {
        let stage: ConversionDeliveryStage
        switch failure {
        case .targetChangedBeforeCommit: stage = .targetValidation
        case .emptyCandidate, .replacementRejected: stage = .replacement
        case .requestChangedDuringCommit, .committedSourceUnavailable,
             .committedSourceMismatch, .committedTargetMismatch: stage = .committedSource
        case .resultUnavailable: stage = .resultVerification
        }
        let verification = failure == .resultUnavailable
        let explanations = LongInputGuidance.forReadFailure(sourceCharacters: sourceCharacters,
            unreadable: failure == .committedSourceUnavailable)
        return Self(title: verification ? "変換結果を確認できませんでした" : "変換結果を適用できませんでした",
            message: failure.rawValue,
            advice: verification
                ? "入力欄を確認してください。変換済みなら再変換せず、エラー表示を解除してください。表示遅延・読取制限等の原因は未特定です。"
                : (explanations.isEmpty ? "原文を確認してください。長文は短く区切って試し、再現時はこの段階・原因・文字数をお知らせください。" : LongInputGuidance.advice),
            stage: stage.rawValue, details: "対象 \(sourceCharacters)文字／UTF-16 \(sourceUTF16)", explanations: explanations)
    }
}
