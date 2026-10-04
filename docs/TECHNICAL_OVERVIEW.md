# Sumibi for macOS 技術解説

## 1. 文書の範囲と状態

2026-10-04、mainの`9baac75`（PR #51まで）をコードと照合した現行実装の説明。Issue #48では機能・保存形式・製品仕様を変更しない。

[SPEC](SPEC.md)は合意した要件であり、全機能の実装完了を意味しない。本書では「実装済み」「未実装の要件」「観測・実機確認」「将来案」を分ける。仕様とコードの差、参照したコード・テストは[実装照合記録](IMPLEMENTATION_AUDIT.md)に記載する。以前の設計案と詳しいアプリ別の調査は[旧技術解説](TECHNICAL_OVERVIEW_HISTORY.md)・[Issue #4の調査記録](ISSUE_4_PROTOTYPE.md)へ保存した。

最小対応OSはmacOS 26という要件を維持する。以下のセッション再生成などの観測は開発環境のmacOS 27であり、全対応OS・全アプリでの確認とは扱わない。macOS版はiOS版を参考に独立実装し、共有パッケージを利用しない。自己配布版はBYOKを利用し、PCC経路は実装しない。

## 2. 単一バンドル・単一プロセスの構成（実装済み）

```text
Sumibi.app / 実行ファイル Sumibi
├─ SumibiMain: IMKServer生成、AppKitイベントループ
├─ SumibiInputController: IMKイベントの受付・接続
│  └─ InputRuntime.shared: 有効な入力経路の状態
│     ├─ InputSession: 追跡文字列・要求ID・待機キー・候補
│     ├─ TextReplacementTracker: 範囲と原文の照合
│     ├─ ConversionLifecycle: 通信・応答・反映待ちタイマー
│     └─ CandidatePresenter → CandidateWindow: 独自候補窓
├─ MenuBarController: NSStatusItem・ログイン項目
└─ SettingsWindowController → APISettingsView: SwiftUI設定画面
```

通常起動は[SumibiMain](../Sources/SumibiIME/SumibiMain.swift)がInfo.plistのBundle IDと接続名からIMKServerを作り、その寿命をイベントループ中保持する。同じプロセスでメニューバーを設置し、設定ウィンドウを必要時に開く。別の設定アプリ・常駐ヘルパー・App Groupは現行構成にない。別アプリへの分離は将来再設計する場合の案であり、配布の成立条件ではない。

Packageは`Sumibi`、モジュールは`SumibiCore`と`SumibiIME`。バンドル素材は`App/`、開発ツールは`Development/`。登録ID・設定・Keychainの互換性と通常／開発ビルドは[ビルドモード](BUILD_MODES.md)を参照。

## 3. 状態の所有者・寿命・入力先変更

`IMKInputController`の生成単位を、文書や変換対象の寿命と同一視しない。開発環境のmacOS 27では、キーを消費した直後にも終了・再生成が起きた。そのため[InputRuntime](../Sources/SumibiIME/InputRuntime.swift)がプロセス全体で一つの有効な入力経路の状態を保持し、短い再生成をまたぐ。文書ごとの独立状態や複数入力欄を並行管理する仕組みではない。

Runtimeは状態機械・範囲追跡・通信・候補表示と、最新コントローラーの弱参照、直前のハンドラー・入力先参照を持つ。これらは応答の適用先を探すための接続情報であり、参照があるだけで安全とは判定しない。所有者とスレッドは[構成資料](INPUT_CONTROLLER_ARCHITECTURE.md)を参照。

[SumibiInputController](../Sources/SumibiIME/SumibiInputController.swift)の`deactivateServer`は、消費したキーから0.3秒未満の終了通知を短い再生成として扱う。それ以外では、必要に応じて未確定原文を確定し、`cancelForTargetChange`で要求・待機キー・直前の候補対象・アンカーを解除する。対象外アプリへ移った場合も同じ取消経路を使う。この時間判定は観測に基づく実装上の対処であり、OSが完全に入力先変更を識別してくれる保証ではない。

応答の要求IDと、入力先から読んだ範囲・選択位置・原文を照合し、不一致・読取不能なら置換しない。遅延したカーソル位置や折り返しを補正する場合も、[TextReplacementTracker](../Sources/SumibiIME/TextReplacementTracker.swift)と[WrappedText](../Sources/SumibiCore/WrappedText.swift)で対象を検証する。別アプリ・同じ原文を含む別入力欄・異なるOSでの全経路の安全性を、この照合だけで実機検証済みとは扱わない。

## 4. 入力・初回変換・非同期応答（実装済み）

通常文字は[InputSession](../Sources/SumibiCore/InputSession.swift)で追跡し、`setMarkedText`で表示する。細い下線の属性を指定するが、描画するのは入力先であり、指定色が使われる保証はない。通常のEnterは原文を確定して追跡を終え、その場のイベントを入力先へ渡す。応答待ち中のEnterとは実装が異なる（次節）。

変換キーはControl + J、右Commandの短いタップ、「かな」キー。ターミナル.appで未確定文字列のないControl + JがIMEへ届かなかった観測を受け、後二つを追加した。全ターミナルで同じキー配信になるとは保証しない。

初回変換は以下の順序で行う。

1. 状態機械が原文を保持して要求IDを発行する。
2. [InputEffectApplier](../Sources/SumibiIME/InputEffectApplier.swift)が原文を通常文字として確定し、置換範囲を記録する。未確定のまま送信する方式ではない。
3. 保存済みユーザー辞書を付け、[ConversionCoordinator](../Sources/SumibiIME/Conversion/ConversionCoordinator.swift)が文字数・送信先・APIキー・送信同意を確認する。
4. [OpenAICompatibleClient](../Sources/SumibiCore/OpenAICompatibleClient.swift)がURLSessionで非同期通信する。応答保存はMainActorへ戻す。
5. 要求IDと入力先の対象を照合し、成功なら原文の範囲を結果で置換する。失敗なら原文を残して待機入力の処理を再開する。

[ConversionLifecycle](../Sources/SumibiIME/Conversion/ConversionLifecycle.swift)は一つの通信タスク、応答、反映待ちタイマーを所有する。入力先が一時的に無効なら0.25秒間隔で最大240回、応答の**反映先**を探す。これはAPIの再送ではない。照合後に応答を一度だけ取り出し、待機キーが次の要求を始める前に旧タスク・タイマーを解除する。通信のタイムアウト設定は60秒で、反映待ちの上限とは別である。

現在の文字数制限はSwiftの`String.count`で原文・現在の変換結果・ユーザー辞書を合算して1,000文字。固定システムプロンプト・JSONのメタデータはこの計数に含めない。位置と置換範囲はUTF-16で扱う。周辺文脈と文体指示は未実装であり、プロンプトの周辺文脈欄は空、追加指示は「ありません」。要件上の送信量と実装の計数範囲を混同しない。

選択範囲の変換は、追跡中の原文や安全に再変換できる直前結果がないとき、選択文字列を取得して同じ変換経路を使う。まず選択範囲を同じ文字列で確定し、応答時に照合してその範囲だけを置換する。

## 5. 待機入力・Esc・救済

応答待ち中の文字・Enter・Backspace・変換キーはCoreの順序付き待ち行列へ入る。通信完了後、元の対象を照合してCoreが順に処理する。追加入力は文字列へ反映され、次の変換が始まると排出を止める。追加候補取得だけを繰り返す連打は抑制する。

ただし、Coreが「入力先へ渡す」効果を返しても、遅延したEnter・空の追跡に対するBackspace・対象のない変換キーは、IME側では`deferredControls`へ記録するだけで入力先へ再送しない。追跡中の文字を削るBackspaceなど、Core内で完結する操作は処理する。したがって「待機中のEnterが後でチャット送信される」とは説明しない。[実装照合記録](IMPLEMENTATION_AUDIT.md)に要件との差を残す。

修飾キーなしのEscは、保留応答を反映するより先に処理する。候補窓があれば窓だけを閉じる。追跡・要求があれば、原文を維持して取消し、待機文字を救済し、制御キーを再実行しない。対象がなければEscを入力先へ渡す。修飾キー付きEscはこの取消経路では扱わない。

入力先変更や取消で救済した文字はRuntimeのメモリに残る。**IMEメニュー**から「保留文字をコピー」「保留文字を破棄」を選べる。コピーだけが明示操作でクリップボードへ書く。専用メニューバーのメニューに救済項目はない。保持期限・待ち行列容量の制限は実装されておらず、プロセス終了でメモリ上の情報は失われる。

## 6. 候補表示とUndo

現行実装は[CandidateWindow](../Sources/SumibiIME/CandidateWindow.swift)の独自AppKitウィンドウであり、IMKCandidatesは使わない。標準候補APIが調査環境で期待どおり機能しなかった経緯は[Issue #4の記録](ISSUE_4_PROTOTYPE.md)に残す。標準候補窓への変更は現行要件ではない。

初回は1件を取得して即確定する。直後の変換キーは追加候補の通信を開始する。候補取得後に表示するので、「まず窓を開き、さらに押してから初めて追加通信する」という旧設計案とは異なる。窓が表示中の変換キーは次の候補へ巡回してその場で置換する。矢印・Enter・数字1〜9・クリックによる移動／選択、Escによる窓の解除も実装するが、キーがIMEへ届くかは入力先に依存する。

追加要求のプロンプトと`ConversionMode.candidateCount`は現在結果を含む最大12件。候補は重複を除き、現在結果を先頭にする。ひらがなだけの単語候補には[HomophoneDictionary](../Sources/SumibiCore/HomophoneDictionary.swift)のローカル索引から最大10件を補足し、出所を「LLM」「辞書」として表示する。辞書全体はLLMへ送信しない。仕様書の「第二候補以降10件」との差は照合記録へ残し、仕様を書き換えて追認しない。

Undoは入力先の標準編集履歴へ委ねる。原文の確定と範囲指定の置換によって履歴に残す方式を採用しているが、全アプリで一回のUndoが同じ範囲を戻すという保証はしない。過去のアプリ別確認と追加の手動確認項目を区別する。

## 7. 設定・メニューバー（実装済みと未実装）

[SettingsWindowController](../Sources/SumibiIME/Settings/SettingsWindowController.swift)が一つのNSWindowとNSHostingViewを保持する。現在の画面はAPI設定、送信先・料金・同意の説明、ユーザー辞書への入口、保存・APIキー削除。文脈スイッチ・文体プリセット・設定画面の変換テスト・利用状況の集計は未実装の要件である。

送信先・モデル・辞書は[SettingsStore](../Sources/SumibiIME/Settings/SettingsStore.swift)のUserDefaults、APIキーは[APIKeyStore](../Sources/SumibiIME/Settings/APIKeyStore.swift)のKeychainへ保存する。キーは固定長の伏せ字と末尾4文字で表示し、「変更」から空の編集欄を開く。保存するまで既存キーは保持する。API入力欄は変換対象外で、辞書編集シート中だけ自アプリでの変換を許可する。

[MenuBarController](../Sources/SumibiIME/MenuBar/MenuBarController.swift)のNSStatusItemは同じプロセスが動いている間、Sumibiが入力ソースでなくても表示する。SMAppService.mainAppでアプリ自身をログイン項目へ登録し、利用者の解除は`MenuBarLoginItemOptOut`で記憶する。独立ヘルパーではない。

専用メニューバーには設定・ログイン起動の項目がある。#12の作業版では変換中・エラーの印と、クリック時の固定文による原因・対処・解除を追加した。`ConversionFeedback`は入力処理と独立し、最新エラー1件をメモリ上だけに保持する。実装・確認範囲は[変換状態の表示](CONVERSION_FEEDBACK.md)を参照。未適用制御キーは従来どおりIMEメニューへ表示する。設定画面だけを開く`--settings`は明示的な開発ビルド限定で、通常版の機能ではない。

## 8. 配布・検証の状態

現行ビルドはSwift Packageから単一のSumibi.appを組み立てる。[App/build.sh](../App/build.sh)はインストールしない。利用者が選んだ導入範囲は**インストールしたユーザーのみ**、配置先は`~/Library/Input Methods/Sumibi.app`。全ユーザー用を並列の未決案として扱わない。

Developer ID署名・公証済みpkg、GitHub ReleasesとPagesからの案内は配布方針であり、公開済みの成果物ではない。#15の配布スクリプトは別ブランチのローカルコミット`c027ccf`にあり、現行mainには未統合。開発署名のビルド・実機更新、模擬配布テストと、実署名／公証／新規導入は別の確認である。[配布資料](DIRECT_DISTRIBUTION.md)を参照。

現行自動テストは通常・開発構成それぞれ138件。#47通常版への更新では、利用者が通常変換・候補選択・Escと、設定・辞書・保存済みAPIキーの保持に問題がないことを確認した。#45ではCodexアプリ内も確認済み。ただし未指定のアプリやOSへ一般化しない。入力先切替・通信待ちなどの残る実機項目は[Tests/README](../Tests/README.md)へ残す。

Chromium系入力欄の長文読取制限（#41）は未解消。1000文字制限とは別の入力先側の制約であり、今回の整理で長文変換が保証されるとは扱わない。Codex CLIなど未確認のTUIも検証済みに含めない。
