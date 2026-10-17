import SwiftUI
import SumibiCore

struct DecisionsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = DecisionsSettingsModel(onChange: { InputRuntime.shared.ambient.settingsChanged() })
    @State private var resetting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Decisionsによる自動変換") {
                    Toggle("すべてのアプリで自動変換する", isOn: Binding(
                        get: { model.settings.enabled }, set: { model.setEnabled($0) }))
                    Text("既定はオフ。Sumibiが扱う入力欄が対象です。パスワード入力、Sumibiの設定欄、既存の対象外アプリ、範囲を安全に確認できない入力欄は除きます。手動変換は引き続き使えます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("全アプリの全テキストではなく、Sumibiが保持する現在の未確定文字列だけを判定します。コードの構文や独自の機密欄を確実には判別できないため、機密入力の前はオフにしてください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("OpenAI Decisions API") {
                    Text("判定先：https://api.openai.com/v1/decisions")
                        .textSelection(.enabled)
                    Text("モデル：gpt-6-luna")
                    LabeledContent("変換用OpenAIキー", value: model.storedKeyDisplay ?? "未設定")
                        .monospaced().privacySensitive()
                    Text("親画面の変換用APIキーを使います。APIのURLは公式OpenAI（https://api.openai.com）にしてください。キーの保存・変更は親画面で行います。旧Jev用キーは使用しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("送信と料金への同意") {
                    Toggle("OpenAIへの入力データ送信に同意する", isOn: Binding(
                        get: { model.settings.consent }, set: { model.setConsent($0) }))
                    Text("オンと同意の両方が揃うと、入力中の未確定文字列（1状態最大512文字）がOpenAIへ自動送信されます。最初の入力から200ms分の各状態をID付きでまとめ、最大32状態ずつ判定します。文書全体・周辺文脈・クリップボードは送信せず、入力内容はログへ記録しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Decisionsが日本語らしさを判定し、閾値以上で漢字変換を開始します。句読点・空白・入力停止は必須ではなく、短い途中入力も対象です。判定と漢字変換の料金が別々に発生します。同意を取り消すと自動変換もオフになります。旧Jevへの同意は引き継ぎません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("判定と費用の上限") {
                    HStack {
                        Text("判定閾値")
                        Slider(value: Binding(get: { model.settings.threshold },
                            set: { model.setThreshold($0) }), in: 0...1, step: 0.05)
                        Text(model.settings.threshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    Stepper("判定回数上限：\(model.settings.maximumCalls)回",
                            onIncrement: model.settings.maximumCalls < 1_000_000
                                ? { model.adjustMaximumCalls(increasing: true) } : nil,
                            onDecrement: model.settings.maximumCalls > 1_000
                                ? { model.adjustMaximumCalls(increasing: false) } : nil)
                    Text("設定は変更時に自動保存します。回数上限は1,000回以上・1,000回単位です。回数は判定した文字数や状態数ではなく通信の回数です。判定は10秒でタイムアウトします。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        LabeledContent("累積判定回数", value: "\(model.callCount)回")
                        LabeledContent("処理状態", value: InputRuntime.shared.ambient.phase.rawValue)
                        if let decision = InputRuntime.shared.ambient.lastDecision {
                            Label("直近のDecisions判定：\(decision.summary)",
                                  systemImage: decision.accepted ? "checkmark.circle.fill" : "pause.circle")
                                .font(.footnote)
                                .foregroundStyle(decision.accepted ? Color.green : Color.secondary)
                        }
                        if let reason = InputRuntime.shared.ambient.lastObservationBlock {
                            LabeledContent("直近の送信見送り理由", value: reason.rawValue)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let details = InputRuntime.shared.ambient.lastObservationDetails {
                            Text(details).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let ranges = InputRuntime.shared.ambient.lastObservationRanges {
                            LabeledContent("未確定範囲（UTF-16）", value: ranges.markedDescription)
                                .font(.footnote).foregroundStyle(.secondary)
                            LabeledContent("選択範囲（UTF-16）", value: ranges.selectionDescription)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let error = InputRuntime.shared.ambient.lastError {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        if let report = InputRuntime.shared.ambient.lastSourceReadReport {
                            LabeledContent("本文読取長（UTF-16）",
                                value: "要求 \(report.requestedLength)、取得 \(report.returnedDescription)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let failure = InputRuntime.shared.ambient.lastDeliveryFailure {
                            LabeledContent("直近の適用失敗", value: failure.rawValue)
                                .font(.footnote).foregroundStyle(.red)
                        }
                        if let report = InputRuntime.shared.ambient.lastCommitReport {
                            let ranges = AmbientRangeReport(marked: report.originalRange, selection: report.selection)
                            LabeledContent("確定前の範囲（UTF-16）", value: ranges.markedDescription)
                                .font(.footnote).foregroundStyle(.secondary)
                            LabeledContent("確定後の選択（UTF-16）", value: ranges.selectionDescription)
                                .font(.footnote).foregroundStyle(.secondary)
                            LabeledContent("記録範囲の読取",
                                value: "長さ \(report.originalReadLength.map(String.init) ?? "取得不可")・\(report.originalComparison.rawValue)")
                                .font(.footnote).foregroundStyle(.secondary)
                            LabeledContent("カーソル直前の読取",
                                value: "長さ \(report.caretReadLength.map(String.init) ?? "取得不可")・\(report.caretComparison.rawValue)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Text("回数は全アプリ共通で保存し、失敗した送信も数えます。アプリ切替・再起動ではリセットされません。上限に達しても手動変換は使えます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("費用を確認して判定回数をリセット") { resetting = true }
                }
                Section("一時デバッグ（確認後はオフにしてください）") {
                    Toggle("原文・取得文字列を設定画面に表示", isOn: Binding(
                        get: { InputRuntime.shared.ambient.debugTextEnabled },
                        set: { InputRuntime.shared.ambient.setDebugTextEnabled($0) }))
                    Text("閉じて短いテスト文を入力してください。失敗した変換の原文・期待する結果・置換前後の取得文字列を、このプロセスのメモリ上だけに保持します。取得範囲に別の文章が含まれる可能性があるため、機密情報は入力しないでください。ログ・設定・ファイルには保存しません。オフ・設定変更・次の適用試行・成功で文字列を消し、再起動後はオフになります。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if InputRuntime.shared.ambient.debugTextEnabled,
                           let report = InputRuntime.shared.ambient.lastCommitText {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("保持中の原文")
                                Text(String(reflecting: report.source)).monospaced().textSelection(.enabled)
                                Text("記録した範囲から取得した文字列")
                                Text(report.atOriginal.map { String(reflecting: $0) } ?? "取得不可")
                                    .monospaced().textSelection(.enabled)
                                Text("確定後のカーソル直前から取得した文字列")
                                Text(report.atCaret.map { String(reflecting: $0) } ?? "取得不可")
                                    .monospaced().textSelection(.enabled)
                            }.font(.footnote).privacySensitive()
                        }
                        if InputRuntime.shared.ambient.debugTextEnabled,
                           let report = InputRuntime.shared.ambient.lastResultText {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("置換直後の確認（即時読み取り）")
                                Text("期待する変換結果")
                                Text(String(reflecting: report.expected)).monospaced().textSelection(.enabled)
                                Text("結果追跡状態：\(report.stateMatches ? "一致" : "相違")")
                                Text("確認した範囲（UTF-16）：\(report.range.map { AmbientRangeReport(marked: $0, selection: report.selection).markedDescription } ?? "未記録")")
                                Text("置換後の選択（UTF-16）：\(AmbientRangeReport(marked: report.selection, selection: report.selection).selectionDescription)")
                                Text("置換後の記録範囲から取得した文字列")
                                Text(report.actual.map { String(reflecting: $0) } ?? "取得不可・確認未実行")
                                    .monospaced().textSelection(.enabled)
                                Text("置換後のカーソル直前の範囲（UTF-16）：\(report.caretRange.map { AmbientRangeReport(marked: $0, selection: report.selection).markedDescription } ?? "取得不可")")
                                Text("置換後のカーソル直前から取得した文字列")
                                Text(report.atCaret.map { String(reflecting: $0) } ?? "取得不可")
                                    .monospaced().textSelection(.enabled)
                            }.font(.footnote).privacySensitive()
                        }
                    }
                }
                if !model.statusMessage.isEmpty {
                    Section {
                        Text(model.statusMessage)
                            .foregroundStyle(model.statusIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction) }
                .padding()
        }
        .frame(width: 560, height: 650)
        .onAppear { InputRuntime.shared.ambient.stop(); model.reload() }
        .confirmationDialog("OpenAIの費用を確認しましたか？", isPresented: $resetting, titleVisibility: .visible) {
            Button("確認済み・リセットする") { model.resetCalls() }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("リセットすると上限まで新たな有料判定が可能になります。請求額や既に発生した料金は消えません。") }
    }
}
