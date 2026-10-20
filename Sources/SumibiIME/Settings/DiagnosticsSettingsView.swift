import SwiftUI

/// Top-level diagnostics UI. Uses existing in-memory reports; opening this view does
/// not load credentials, grant consent, or read text from the focused application.
struct DiagnosticsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let runtime: InputRuntime

    init(runtime: InputRuntime = .shared) { self.runtime = runtime }

    var body: some View {
        VStack(spacing: 0) {
            Text("診断・デバッグ").font(.headline).padding(.top)
            Form {
                Section("一時デバッグ（確認後はオフにしてください）") {
                    Toggle("原文・取得文字列を設定画面に表示", isOn: Binding(
                        get: { runtime.ambient.debugTextEnabled },
                        set: { runtime.ambient.setDebugTextEnabled($0) }))
                    Text("閉じて短いテスト文を入力してください。原文照合で見送ったときの原文・取得文字列、失敗した変換の期待する結果・置換前後の取得文字列を、このプロセスのメモリ上だけに保持します。取得範囲に別の文章が含まれる可能性があるため、機密情報は入力しないでください。ログ・設定・ファイルには保存しません。オフ・設定変更・次の観測や適用試行・成功で文字列を消し、再起動後はオフになります。")
                        .font(.footnote).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        if runtime.ambient.debugTextEnabled,
                           let report = runtime.ambient.lastObservationText {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("自動変換を見送ったときの原文比較").fontWeight(.semibold)
                                Text("段階：\(report.stage.rawValue)")
                                Text("保持中の原文")
                                Text(String(reflecting: report.source)).monospaced().textSelection(.enabled)
                                Text("未確定範囲から実際に取得した文字列")
                                Text(report.actual.map { String(reflecting: $0) } ?? "取得不可")
                                    .monospaced().textSelection(.enabled)
                                Text("未確定範囲（UTF-16）：\(report.ranges.markedDescription)")
                                Text("選択範囲（UTF-16）：\(report.ranges.selectionDescription)")
                            }.font(.footnote).privacySensitive()
                        }
                        if runtime.ambient.debugTextEnabled,
                           let report = runtime.ambient.lastCommitText {
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
                        if runtime.ambient.debugTextEnabled,
                           let report = runtime.ambient.lastResultText {
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
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
        }
        .frame(width: 600, height: 650)
        // Keep failed reports while pausing automatic work, as the old screen did.
        .onAppear { runtime.ambient.stop() }
    }
}
