# 現行仕様と実装の照合記録（Issue #63）

確認日: **2026-10-20**。Windows版Sumibi-winへの引き継ぎに使う現行の照合記録。
[SPEC](SPEC.md)の将来要件を実装済みと扱わず、コードとの差を残す。
以前の照合は[2026-10-04の履歴](IMPLEMENTATION_AUDIT_2026-10-04.md)に保存した。

## 基準と統合状態

| 区分 | 基準 | 状態 |
| --- | --- | --- |
| main | `ac83ff09b1b5b640ac1d64d9066c710280c377dc` | PR #59の配布手順とPR #60のDecisions自動変換まで統合済み |
| 記号サポート | `401507c02a04f2a025540aeca8d1bc0829683053`／[PR #61](https://github.com/kiyoka/Sumibi-mac/pull/61) | OPEN。mainへ未統合。記号入力・Undo・ライセンス表示は利用者確認済み |
| 原文比較・診断画面 | `codex/issue-62-debug-settings`の未コミット作業ツリー | #55の比較表示、#62の独立画面。main／PR #61の内容ではない |
| 今回の資料更新 | [#63](https://github.com/kiyoka/Sumibi-mac/issues/63) | コード・設定・インストール済みアプリは変更しない |

作業版を通常版として実機へ更新した履歴は、公開版・main統合・リリース完了を意味しない。
`App/Info.plist`は **0.4／build 4**。#57の0.9.0は目標で、まだ版数を変更していない。

## コードに基づく現在の状態

| 項目 | mainの実装 | 作業版との差／根拠 |
| --- | --- | --- |
| 入力・初回変換 | 追跡文字を確定後、成功結果を範囲置換。初回1候補。選択文字列も変換可能 | [InputSession](../Sources/SumibiCore/InputSession.swift)、[InputEffectApplier](../Sources/SumibiIME/InputEffectApplier.swift) |
| 手動変換の待機入力 | 文字・制御キーの順序付き待ち行列。対象変更では文字を救済 | 遅延したEnter等は記録のみで実際には送信しない。自動変換とは別 |
| 追加候補 | 最大12候補を要求し、現在結果を先頭に保持。選択時だけ対象を置換 | [Conversion](../Sources/SumibiCore/Conversion.swift)、[コントローラー](../Sources/SumibiIME/SumibiInputController.swift) |
| 辞書候補 | Sudachiの同音異義語を最大10件補足。LLM内の全ひらがな単語が検索条件 | PR #61は元入力全体からMozc記号を検索し、中黒→記号→Sudachiで合計10件。[記号仕様](https://github.com/kiyoka/Sumibi-mac/blob/401507c02a04f2a025540aeca8d1bc0829683053/docs/SYMBOL_CANDIDATES.md) |
| Decisions | 既定オフ、独立同意、公式接続先・共有キー、閾値0.5、200ms固定窓、32状態、待機256件、10秒、通信上限10,000回 | [詳細](DECISIONS_CONVERSION.md)。Jev通信は廃止。保存済み閾値を既定値で上書きしない |
| 自動変換中の入力 | 入力を即時処理し、古い世代の判定・変換結果は非適用 | 手動待機キーの待ち行列を流用しない。[AmbientConversionLifecycle](../Sources/SumibiIME/Conversion/AmbientConversionLifecycle.swift) |
| 位置・内容照合 | UTF-16範囲、選択、原文、要求ID、入力先・入力活動・認可を確認。未照合なら置換しない | [TextReplacementTracker](../Sources/SumibiIME/TextReplacementTracker.swift)、[AmbientInputSnapshot](../Sources/SumibiIME/Conversion/AmbientInputSnapshot.swift) |
| 読取待機 | 自動変換の確定原文を最大0.5秒読取確認、置換後の結果も読取だけ再確認 | API再送・全文探索・再書込ではない。恒久的な読取制約は解消しない |
| 状態・エラー | メニューバーの処理印、固定原因・対処・明示解除。カーソル付近の短時間チェック／赤い! | [表示](CONVERSION_FEEDBACK.md)。直近のスコアは現在入力の成功保証ではない |
| 一時デバッグ | 明示オン時の原文・確定前後の取得文字列をメモリ内表示。再起動後オフ | 作業版は観測時の比較を追加し、設定トップへ移動。[#62の仕様](https://github.com/kiyoka/Sumibi-mac/issues/62) |
| 保存・同意 | 接続先・モデル・辞書はUserDefaults、キーはKeychain。変換同意は接続先文字列ごと | [SettingsStore](../Sources/SumibiIME/Settings/SettingsStore.swift)、[APIKeyStore](../Sources/SumibiIME/Settings/APIKeyStore.swift) |
| 周辺文脈等 | 周辺文脈・文体指示・設定画面の変換テスト・一般的なトークン／料金集計は未実装 | Decisionsの回数制限は、請求額や変換API全体の利用額表示とは別 |
| 配布 | 単一アプリ、ユーザー本人のみ。Developer ID署名・公証用スクリプトはPR #59でmain統合済み | 検証用pkgの実署名・公証は成功。新規導入・更新・削除のpkg実機検証は未完了 |

## 要件との差・未解決事項

- SPEC 4.3の追加取得「第二候補以降10件」と、現在結果を含む最大12件という実装の差は残る。
  辞書補足の10件とは別の数。今回プロンプトや候補数は変更しない。
- 手動変換待機中の制御キーを後でホストへ渡すという要件に対し、遅延したEnter・空入力への
  Backspace・対象のない変換キーは`deferredControls`へ記録するだけ。チャット送信を後から実行しない。
- 待機キーと救済文字の容量・保持期限は未実装。Decisionsの未送信256状態とは別。
- 読取待機の「0.5秒」は原文確認では単調時計の期限を検査するが、置換後の結果確認は100ms×最大5回という
  再試行回数で制限する。結果確認についてUI処理の遅延後も厳密な実時間上限を保証する実装ではない。
- Codex等の長文読取制約は未解消。#56はエラー捕捉・案内の対応であり、全文読取の修正ではない。
- #55では短文でも原文照合・選択位置で見送られることがある。30文字で要求／取得長が同じでも内容不一致が
  あった。原因未特定。作業版で比較表示を追加したが、相違文字列の報告はまだない。
- 失敗後にエラー解除まで自動変換が再開しないとの報告は、原因特定・実機での解消確認が未完了。
  表示解除が必要な設計要件ではない。エラー保持と処理状態は分離している。
- #28のターミナル上のClaude Code入力欄への結果適用は未解決。#57のリリースタスクには含めないという
  利用者の決定を維持する。Windowsの同名アプリへ一般化しない。

## 検証の根拠と限界

- 最新の実行記録（2026-10-18の#62作業版）：通常・開発構成それぞれCore 102件＋IME 228件＝330件。
  329件成功、実60秒タイムアウト1件は明示スキップ。main単体の件数ではない。
- #58作業版：生成処理3件、配布手順の模擬検査31項目、固定元データからの再生成一致、索引・ライセンス同梱を確認。
- 模擬通信・模擬Keychain・専用UserDefaultsを使い、本人のキーや実APIを自動テストで使用しない。
  今回は文書更新であり、これらの機能テストを新たに実行したとは記録しない。
- 利用者はDecisions版のCodexで短文変換・1回のUndo・追加入力・左矢印・Esc・他アプリ切替・Ctrl＋Jとの競合を確認。
  報告時点と限定条件は[詳細履歴](DECISIONS_CONVERSION.md)を参照する。
- 記号★・①・中黒とUndo、Mozcライセンス全文の表示は利用者確認済み。入力先アプリ名は再明示されていない。
- #62版は更新済みで、利用者は一時デバッグを再度オンにしたと報告。入口の配置・旧画面からの除去などの個別確認と
  再発時の比較表示は、まだ明示的な報告がない。全OS・全アプリの合格としない。
- #15の実署名・公証は0.4／build 4／arm64の検証用pkg。0.9.0の配布物やWindows用成果物ではない。

## 保守

[文書の入口と更新手順](README.md)、[Windows版への引き継ぎ](WINDOWS_HANDOFF.md)を参照。
将来機能の実装・仕様変更を、文書だけで追認しない。新しい確認結果は日付・対象コミット・
main／PR／作業版・アプリ・自動／実機の区別を付けて記録する。
