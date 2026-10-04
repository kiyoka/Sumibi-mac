# 仕様・資料と実装の照合記録（Issue #48）

確認日: 2026-10-04。対象: main `9baac75`（PR #51まで）と、#15の別ブランチのローカルコミット`c027ccf`。この記録は文書整理であり、コードや合意した仕様を変更しない。

後続の#12作業版では、ここで未実装とした専用メニューバーのエラー印・詳細と変換待ち表示を実装した。[表示方針・確認結果](CONVERSION_FEEDBACK.md)を参照。以下の表は#48で照合した時点の記録として残す。

## 現行実装の根拠

| 対象 | 確認した実装 | 検証の根拠・限界 |
| --- | --- | --- |
| 単一バンドル・起動 | [SumibiMain](../Sources/SumibiIME/SumibiMain.swift)、[Info.plist](../App/Info.plist)、[ビルド](../App/build.sh) | IMKServer、メニューバー、設定画面は同じ実行ファイル。別設定アプリはない |
| 状態の寿命 | [InputRuntime](../Sources/SumibiIME/InputRuntime.swift)、[コントローラー](../Sources/SumibiIME/SumibiInputController.swift)の`deactivateServer`・`liveInput` | 共有状態は一つの入力経路。0.3秒判定はmacOS 27での観測に基づく対処。独立文書ごとの状態ではない |
| 非同期応答 | [ConversionLifecycle](../Sources/SumibiIME/Conversion/ConversionLifecycle.swift)、[テスト](../Tests/SumibiIMETests/ConversionLifecycleTests.swift) | 要求ID、MainActorへの復帰、一度だけの取出し、取消、反映待ちの上限。240回の再試行はAPI再送ではない |
| 置換・取消 | [TextReplacementTracker](../Sources/SumibiIME/TextReplacementTracker.swift)、[InputEffectApplier](../Sources/SumibiIME/InputEffectApplier.swift)、[テスト](../Tests/SumibiIMETests/InputEffectApplierTests.swift) | 範囲・文字列の照合、UTF-16、古いカーソル、選択変換、取消と入力先変更。模擬入力先での検証であり全アプリの保証ではない |
| 候補表示 | [CandidatePresenter](../Sources/SumibiIME/CandidatePresenter.swift)、[CandidateWindow](../Sources/SumibiIME/CandidateWindow.swift)、[テスト](../Tests/SumibiIMETests/CandidatePresenterTests.swift) | 独自AppKit窓、選択・巡回。IMKCandidatesは現行で使わない |
| 要求と計数 | [Conversion](../Sources/SumibiCore/Conversion.swift)、[テスト](../Tests/SumibiCoreTests/ConversionTests.swift) | 初回1件、追加は最大12件。原文・現在結果・辞書を`String.count`で合算。固定プロンプトとJSONは数えない |
| 保存・UI | [SettingsStore](../Sources/SumibiIME/Settings/SettingsStore.swift)、[APIKeyStore](../Sources/SumibiIME/Settings/APIKeyStore.swift)、[APISettingsView](../Sources/SumibiIME/Settings/APISettingsView.swift) | 設定・移行・キーの分離テスト。辞書編集は自アプリの変換対象外判定の例外 |
| メニューバー | [MenuBarController](../Sources/SumibiIME/MenuBar/MenuBarController.swift)、コントローラーの`menu` | 専用アイコンは設定・ログイン起動。救済文字・未適用キー・エラーはIMEメニューにある |
| 開発機能 | [DevelopmentOptions](../Sources/SumibiIME/Development/DevelopmentOptions.swift)、[テスト](../Tests/SumibiIMETests/DevelopmentOptionsTests.swift)、[成果物検証](../Development/verify-build.rb) | 通常版では模擬応答・入力内容診断をコンパイルしない。旧設定値も無視する |

設定・Keychain・送信同意などの各テストと実行方法は[Tests/README](../Tests/README.md)にまとめる。現行は通常・開発構成それぞれ138件。#15の配布模擬テスト18項目は別コミットのスナップショットを対象とし、mainに配布スクリプトがあるという意味ではない。

## 仕様との差・未実装要件（追認しない）

[SPEC](SPEC.md)の要件をコードに合わせて黙って弱めない。以下の実装変更や仕様変更は、この文書整理では行わず、後続作業で判断する。

| SPECの参照 | 現在の差・未実装 | このIssueでの扱い |
| --- | --- | --- |
| 3.2・4.3の追加候補10件 | `candidateCount`・プロンプトは現在結果を含め最大12件。ローカル辞書からの最大10件は別枠 | 技術解説はコードを記述し、仕様の10件を変更しない |
| 3.2の候補を開いてから追加取得する流れ | 初回直後の変換キーで追加通信を始め、候補取得後に窓を開く。表示中は巡回する | 旧設計案と現行動作を区別。操作方針の変更はここで決めない |
| 3.2.1の待機中制御キーの処理 | Core内で処理できる削除などは動くが、遅延した`.passEnter`等は`deferredControls`に記録するだけ。`testDeferredControlsAreReportedInsteadOfDelivered`もその動作を確認 | アプリへの送信・改行が後で実行されるとは書かない。疑似キー送信を追加しない |
| 3.2.1のメニューバーからの文字救済 | コピー・破棄はIMEメニューに実装。専用NSStatusItemにはない | 二つのメニューを区別して記述 |
| 3.4・4.2の文脈・文体・変換テスト・利用状況 | 該当設定・取得・送信・集計は未実装 | 合意済みでも実装済みではないと明記 |
| 3.4の送信テキスト上限 | 可変部分の計数を実装。固定プロンプト・通信メタデータは計数外。文脈・文体は未実装 | 計数規則の未確定部分を残し、「要求全体が厳密に1000文字以内」とは書かない |
| 3.5の設定画面全体を対象外という説明と4.2の辞書編集 | コードは辞書シート中だけ自アプリで変換を許す。4.2に既に例外がある | 資料は例外を明記。SPEC本文の整合は後続で編集する |
| 6のエラー印と詳細表示 | 専用メニューバーの印・詳細は未実装。IMEメニューへ`lastError`を出す | 未実装（#12）とし、現在のエラー表示経路を書く |
| 7の要検討事項 | Escの一部は3.2と#43ですでに確定・実装済み。救済期限・待ち行列上限などは未実装 | 一律に「未確定」または「実装済み」とせず、対象を分ける |

## 観測・実機確認の範囲

- macOS 27でのコントローラー再生成、カーソルの遅延・折り返し、入力先ごとのキー配信は[履歴資料](TECHNICAL_OVERVIEW_HISTORY.md)と[Issue #4](ISSUE_4_PROTOTYPE.md)に残す。別OS・アプリへ一般化しない。
- #45では利用者が従来と同じ動作、続いてCodexアプリ内でも同じ確認に問題がないと報告。#47では通常版への更新後、通常変換・候補選択・Esc、設定・辞書・APIキーの保持に問題がないと報告。[構成資料](INPUT_CONTROLLER_ARCHITECTURE.md)・[ビルドモード](BUILD_MODES.md)に記録済み。
- 新規入力ソース登録、全アプリでのUndo、通信待ち中の全切替パターン、未確認TUI、全対応OSの実機確認は完了扱いにしない。残る確認は[手動チェックリスト](../Tests/README.md)で管理する。
- Chromium系入力欄の長文読取制限（#41）は未解消。1,000文字制限とは別の問題であり、短い入力の成功を長文の保証に使わない。

## 配布との照合

単一Sumibi.appを、インストールしたユーザーの`~/Library/Input Methods`へ置く方針は利用者の決定を反映する。全ユーザー用配置や別ヘルパーは未決の現行候補ではない。[配布資料](DIRECT_DISTRIBUTION.md)を参照。

#15の配布スクリプトは`codex/issue-15-developer-id-distribution`の`c027ccf`にあり未統合。開発署名ビルド・既存登録を使った更新は確認済みだが、Developer ID証明書による実署名・公証・未導入Macでのpkg検証は未実施。2026-10-04のGitHub Releases一覧は空だった。Pagesの公開設定・実ページの表示は今回確認していない。
