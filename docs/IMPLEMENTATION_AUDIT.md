# 現行仕様と実装の照合記録（Issue #63）

確認日: **2026-10-20**。Windows版Sumibi-winへの引き継ぎに使う現行の照合記録。
[SPEC](SPEC.md)の将来要件を実装済みと扱わず、コードとの差を残す。
以前の照合は[2026-10-04の履歴](IMPLEMENTATION_AUDIT_2026-10-04.md)に保存した。

## 基準と統合状態

| 区分 | 基準 | 状態 |
| --- | --- | --- |
| 基準main | `d2b96fc2d2e7bf08a597e2ba46132712b6785d93` | PR #59〜#61の実装とPR #65の仕様資料まで統合済み |
| 記号サポート | `401507c02a04f2a025540aeca8d1bc0829683053`／[PR #61](https://github.com/kiyoka/Sumibi-mac/pull/61) | 2026-10-20にマージ済み。記号入力・Undo・ライセンス表示は利用者確認済み |
| 原文比較・診断画面 | [PR #66](https://github.com/kiyoka/Sumibi-mac/pull/66) | #55の比較表示、#62の独立画面を本ブランチに収録。マージ前はmainとは区別する |
| 仕様資料・構成図 | #63／PR #65、#64／PR #67 | mainへ統合済み。本ブランチでは図を保持して#62の画面移動に追従 |

作業版を通常版として実機へ更新した履歴は、公開版・main統合・リリース完了を意味しない。
`App/Info.plist`は **0.4／build 4**。#57の0.9.0は目標で、まだ版数を変更していない。

## コードに基づく現在の状態

| 項目 | mainの実装 | 作業版との差／根拠 |
| --- | --- | --- |
| 入力・初回変換 | 追跡文字を確定後、成功結果を範囲置換。初回1候補。選択文字列も変換可能 | [InputSession](../Sources/SumibiCore/InputSession.swift)、[InputEffectApplier](../Sources/SumibiIME/InputEffectApplier.swift) |
| 手動変換の待機入力 | 文字・制御キーの順序付き待ち行列。対象変更では文字を救済 | 遅延したEnter等は記録のみで実際には送信しない。自動変換とは別 |
| 追加候補 | 最大12候補を要求し、現在結果を先頭に保持。選択時だけ対象を置換 | [Conversion](../Sources/SumibiCore/Conversion.swift)、[コントローラー](../Sources/SumibiIME/SumibiInputController.swift) |
| 辞書候補 | 中黒→Mozc記号→Sudachiで合計最大10件。記号は元入力全体、SudachiはLLMの全ひらがな単語から検索 | PR #61でmain統合済み。[補完処理](../Sources/SumibiCore/SupplementalCandidateDictionary.swift)。[記号仕様](SYMBOL_CANDIDATES.md) |
| Decisions | 既定オフ、独立同意、公式接続先（`OpenAI`または`Google`）・OpenAI判定キー、閾値0.5、200ms固定窓、32状態、待機256件、10秒、通信上限10,000回 | [詳細](DECISIONS_CONVERSION.md)。#71で`Google`変換接続先選択時にもOpenAI Decisions判定＋Google変換の併用、Decisions画面でのOpenAIキー入力・変更（削除不可）、接続先変更時の自動オフ・再同意に対応 |
| 自動変換中の入力 | 入力を即時処理し、古い世代の判定・変換結果は非適用 | 手動待機キーの待ち行列を流用しない。[AmbientConversionLifecycle](../Sources/SumibiIME/Conversion/AmbientConversionLifecycle.swift) |
| 位置・内容照合 | UTF-16範囲、選択、原文、要求ID、入力先・入力活動・認可を確認。未照合なら置換しない | [TextReplacementTracker](../Sources/SumibiIME/TextReplacementTracker.swift)、[AmbientInputSnapshot](../Sources/SumibiIME/Conversion/AmbientInputSnapshot.swift) |
| 読取待機 | 自動変換の確定原文を最大0.5秒読取確認、置換後の結果も読取だけ再確認 | API再送・全文探索・再書込ではない。恒久的な読取制約は解消しない |
| 状態・エラー | メニューバーの処理印、固定原因・対処・明示解除。カーソル付近の短時間チェック／赤い! | [表示](CONVERSION_FEEDBACK.md)。直近のスコアは現在入力の成功保証ではない |
| 一時デバッグ | 明示オン時の原文・確定前後の取得文字列をメモリ内表示。再起動後オフ | 本ブランチは観測時の比較を追加し、設定トップへ移動。[#62の仕様](DIAGNOSTICS_SETTINGS.md) |
| 保存・同意 | 接続先・モデル・辞書はUserDefaults、キーはKeychain。変換同意は接続先文字列ごと | #69ブランチで接続先（`OpenAI`／`Google`／`その他`）ごとの設定保持とKeychainの`endpoint:<url>`アカウント分離を追加。[SettingsStore](../Sources/SumibiIME/Settings/SettingsStore.swift)、[APIKeyStore](../Sources/SumibiIME/Settings/APIKeyStore.swift) |
| 利用状況・概算費用 | mainでは未実装（Decisionsの通信回数のみ） | #69ブランチで`provider + model`別の変換回数・トークン数・記録時概算USD費用表示とリセットを追加。[UsageStatistics](../Sources/SumibiCore/UsageStatistics.swift) |
| 周辺文脈等 | 周辺文脈・文体指示・設定画面の変換テストは未実装 | Decisionsの回数制限は、変換APIの利用統計・概算費用表示とは別管理 |
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

- 最新の実行記録（2026-10-20のPR #66、`fdf93bf`）：通常・開発構成それぞれCore 102件＋IME 228件＝330件。
  329件成功、実60秒タイムアウト1件は明示スキップ。main単体の件数ではない。
- #58作業版：生成処理3件、配布手順の模擬検査31項目、固定元データからの再生成一致、索引・ライセンス同梱を確認。
- 模擬通信・模擬Keychain・専用UserDefaultsを使い、本人のキーや実APIを自動テストで使用しない。
  #62の本ブランチでの再検証結果は[診断画面](DIAGNOSTICS_SETTINGS.md)に記録する。
- 利用者はDecisions版のCodexで短文変換・1回のUndo・追加入力・左矢印・Esc・他アプリ切替・Ctrl＋Jとの競合を確認。
  報告時点と限定条件は[詳細履歴](DECISIONS_CONVERSION.md)を参照する。
- 記号★・①・中黒とUndo、Mozcライセンス全文の表示は利用者確認済み。入力先アプリ名は再明示されていない。
- #62版は更新済み。2026-10-20、利用者は設定トップから開けること、Decisions設定に重複しないこと、
  オンにして閉じ再度開いてもオンであることの3点を確認。再発時の比較表示とオフでの表示消去は確認待ち。
  全OS・全アプリの合格としない。
- #69（PR #70マージ済み）・#71ブランチ（2026-10-31）：#69ではCore 111件＋IME 239件＝350件、#71では通常・開発両構成でCore 111件＋IME 241件＝352件（351件成功、実60秒タイムアウト1件は明示スキップ）。
  #69の通常版を実機へ更新後、利用者がDecisions自動変換をオフにした状態でGoogle Gemini APIによる変換が動作することを確認し、続けて#71の通常版へ更新後、Google接続先選択時にDecisions設定画面での両キー表示・判定回数リセット・手動変換および`nihongodesu.`によるDecisions自動変換が動作することを実機確認した。
  確認アプリ名や追加候補・Undo・接続先往復切替等の個別項目は未報告であり、全環境の確認済みとはしない。
- #68ブランチ（2026-11-01）：X（x.com、Google Chrome）の入力フォーム等でCtrl+J変換時に原文と変換結果が重複する（`nihongo日本語`）不具合への対策。
  原因調査により、(1) 入力先（Chrome/Draft.js）の早期未確定終了や再入確定による二重挿入（`nihongonihongo`）、(2) 二重挿入された後半への誤アンカーと誤置換、(3) 未確定範囲露出中の置換書き込み、(4) 置換後検証で末尾追記時のカーソル移動が沈黙中断されていたことの4段階を特定。
  対策として `lastMarkedStart`・`isMarkedTextAlreadyCommitted` による二重確定抑止、挿入前の確定フラグ設定、アンカー直後の重複検出と誤再アンカー拒否、未確定範囲露出時の置換拒否、および置換後検証における追記カーソル位置の不一致（`.mismatch`）検出を追加した。
  通常・開発両構成でCore 111件＋IME 248件＝359件（358件成功、実60秒タイムアウト1件スキップ）を確認した。
  実機更新後、利用者がGoogle Chrome上のX（x.com）投稿入力フォームにて、Ctrl+J変換で何度変換しても重複が再現しないこと、Esc取消および追加入力が正常に動作すること、Decisions自動変換も期待通り動作することを確認した（X上のUndoはWebフォーム側の履歴動作により直前入力文章への復帰となることを確認）。
- #15の実署名・公証は0.4／build 4／arm64の検証用pkg。0.9.0の配布物やWindows用成果物ではない。

## 保守

Issue #64ではmain `d2b96fc`（2026-10-20）を基準として、既存の技術解説へ
[全体図](TECHNICAL_OVERVIEW.md#runtime-architecture)・
[手動／自動フロー](TECHNICAL_OVERVIEW.md#conversion-flows)・
[保存と送信の境界](TECHNICAL_OVERVIEW.md#data-boundaries)、所有関係の資料へ
[寿命の補助図](INPUT_CONTROLLER_ARCHITECTURE.md#ownership-diagram)を追加する。
原文比較・独立診断画面は[PR #66](https://github.com/kiyoka/Sumibi-mac/pull/66)（`fdf93bf`、未マージ）に
切り分け済みで、図のmain実装とは区別する。コード・設定・配布物・Windows方式の変更は行わない。

[文書の入口と更新手順](README.md)、[Windows版への引き継ぎ](WINDOWS_HANDOFF.md)を参照。
将来機能の実装・仕様変更を、文書だけで追認しない。新しい確認結果は日付・対象コミット・
main／PR／作業版・アプリ・自動／実機の区別を付けて記録する。
