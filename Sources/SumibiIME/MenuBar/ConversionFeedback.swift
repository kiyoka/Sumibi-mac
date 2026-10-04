import Foundation
import SumibiCore

/// Safe UI text only. Never retain provider responses, request text, URLs or keys.
struct ConversionNotice: Equatable {
    let title: String
    let message: String
    let advice: String

    static func failure(_ error: ConversionError) -> Self {
        switch error {
        case .apiKeyMissing:
            return Self(title: "APIキーを利用できません", message: "未設定、またはKeychainから読み取れないため送信していません。",
                        advice: "Sumibi設定のAPIキーと、このアプリのKeychainアクセスを確認してください。")
        case .consentMissing:
            return Self(title: "送信への同意が必要です", message: "変換を送信していません。",
                        advice: "Sumibi設定で送信先を確認し、データ送信に同意してください。")
        case .overLimit:
            return Self(title: "1,000文字の上限を超えています", message: "変換対象・現在の結果・ユーザー辞書の合計が上限を超え、送信していません。",
                        advice: "変換対象やユーザー辞書を短くして、もう一度変換してください。")
        case .invalidEndpoint:
            return Self(title: "APIのURLが正しくありません", message: "変換を送信していません。",
                        advice: "Sumibi設定でAPIのURLを確認してください。")
        case .invalidCredentials:
            return Self(title: "APIの認証に失敗しました", message: "送信先が認証情報を受け付けませんでした。",
                        advice: "Sumibi設定のAPIキーと、プロバイダー側の利用権限を確認してください。")
        case .rateLimited:
            return Self(title: "APIの利用が制限されています", message: "送信先の利用上限または一時的な制限に達しました。",
                        advice: "プロバイダーの利用枠を確認し、しばらく待ってから変換してください。")
        case .timedOut:
            return Self(title: "変換がタイムアウトしました", message: "APIの応答を待ちましたが、時間内に取得できませんでした。",
                        advice: "接続を確認し、しばらく待ってからもう一度変換してください。")
        case .offline, .network:
            return Self(title: "通信に失敗しました", message: "APIへ接続できないか、通信が中断されました。",
                        advice: "ネットワークと送信先の稼働状況を確認してください。")
        case .serverError:
            return Self(title: "APIサーバーでエラーが発生しました", message: "送信先が変換要求を処理できませんでした。",
                        advice: "しばらく待ってからもう一度変換してください。")
        case .httpError:
            return Self(title: "APIが要求を受け付けませんでした", message: "変換要求に対してエラーが返されました。",
                        advice: "APIのURL・モデル名とプロバイダーの対応状況を確認してください。")
        case .emptyResponse:
            return Self(title: "変換結果を取得できませんでした", message: "APIから利用できる候補が返されませんでした。",
                        advice: "モデルの対応状況を確認し、もう一度変換してください。")
        }
    }

    static let inputUnavailable = Self(title: "変換結果を適用できませんでした",
                                      message: "入力先に接続できませんでした。",
                                      advice: "入力先に戻り、原文を確認してもう一度変換してください。")
    static let selectionUnreadable = Self(title: "選択した文字列を読み取れませんでした",
                                         message: "この入力先から変換対象を取得できませんでした。",
                                         advice: "選択範囲を確認するか、別の入力欄で試してください。")
}

/// Main-thread UI state, separate from input recovery. Reading/clearing cannot touch input.
final class ConversionFeedback {
    enum Indicator: Equatable { case idle, converting, error }
    private(set) var isConverting = false
    private(set) var notice: ConversionNotice?
    var onChange: (() -> Void)?

    var indicator: Indicator { notice != nil ? .error : (isConverting ? .converting : .idle) }
    var accessibilityLabel: String {
        var label = "Sumibi"
        if isConverting { label += "、変換中" }
        if notice != nil { label += "、未確認の変換エラーがあります" }
        return label
    }

    func begin() { isConverting = true; onChange?() }
    func finish() { isConverting = false; onChange?() }
    func report(_ notice: ConversionNotice) { self.notice = notice; onChange?() }
    func clearNotice() { notice = nil; onChange?() }
}
