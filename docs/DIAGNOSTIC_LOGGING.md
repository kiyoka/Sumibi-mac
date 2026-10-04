# 診断ログ（#14）

## 既定の動作

通常版・開発版とも、詳細ログは既定で無効。通常入力、セッション生成・終了、
変換成功、候補操作、応答を入力先へ届ける途中の再試行は記録しない。
失敗・異常だけを固定イベント名で記録する。

- `conversionFailed`: 変換失敗。固定の`reason`で種類を見分ける。
- `deliveryUnavailable`: 入力先へ応答を届ける240回の再試行を使い切った。
- `targetChanged`: 置換対象の確認に失敗し、安全のために変換を取り消した。
  カーソル移動・入力先変更でも起こり得るため、必ずしもAPI障害ではない。
- `selectionUnreadable`: 選択された文字列を入力先から取得できなかった。
- `overLimit`: 通信開始前の入力文字数制限に達した。
- `iconMissing` / `loginToggleFailed` / `loginRegistrationFailed`: アイコン・ログイン項目の異常。

既定のログには入力文字数や範囲も出さない。キー操作数に比例した通常ログはゼロ。
失敗を繰り返せば失敗した回数分のログは残る。OSや他アプリ自身が出すログは別である。

## 詳細ログを切り替える

調査に必要な間だけ、以下を設定する。通常版でも使える。

```sh
defaults write org.sumibi.inputmethod.Sumibi DiagnosticLoggingEnabled -bool true
```

無効に戻す：

```sh
defaults write org.sumibi.inputmethod.Sumibi DiagnosticLoggingEnabled -bool false
```

値を削除しても既定の無効に戻る。外部の`defaults`変更が実行中プロセスへ反映されない場合は、
入力ソースをABCにしてからSumibiを再起動する。入力中に強制終了しない。
入力ソースの切替だけではプロセスが再起動されるとは限らない。
アプリ自身はログ設定変更のために再起動・入力の取消を行わない。
古い`PrototypeDiagnoseText`は読み取らない。入力内容を出す旧診断コード自体を削除した。

## 読み方

リアルタイムで見る：

```sh
/usr/bin/log stream --style compact --predicate 'subsystem == "org.sumibi.inputmethod.Sumibi" AND category == "diag"'
```

直近10分の保存されたログを見る：

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "org.sumibi.inputmethod.Sumibi" AND category == "diag"'
```

出力例（ダミー数値）：

```text
event=conversionFailed reason=timedOut counters=[]
event=conversionSucceeded counters=[4,1]
event=deliveryRetried counters=[3]
```

`reason`は`apiKeyMissing`、`consentMissing`、`overLimit`、`invalidEndpoint`、
`invalidCredentials`、`rateLimited`、`serverError`、`httpError`、
`emptyResponse`、`timedOut`、`offline`、`network`のいずれか。
生のエラー文やHTTP応答は出さない。

詳細時の主な`counters`は、順番に次の意味を持つ。他のイベントでは空配列。

| イベント | 数値の意味 |
| --- | --- |
| keyHandled | 未確定文字数（キーコードではない） |
| conversionSucceeded | リクエストID、候補数 |
| deliveryTimer | リクエストID、再試行回数 |
| deliveryRetried | 再試行回数 |
| deliveryRangeChecked | 選択位置、選択範囲の長さ（UTF-16） |
| targetMismatch | 記録した位置、範囲の長さ（UTF-16）、返されたUnicode scalar数 |
| selectionConversionStarted | 選択された文字数 |
| candidatesShown | 候補数 |
| candidateMoved | 候補インデックス |
| candidateChosen / candidateCycled | 候補インデックス、適用するeffect数 |

`controllerCreated` / `controllerReleased` / `controllerActivated` /
`controllerDeactivated`で入力セッションの再生成を、
`targetReanchored`で置換位置の修正を追える。調査後は詳細ログを無効に戻す。
OSのログ保存期間・権限・永続化設定により、過去の詳細ログが残らない場合もある。

## プライバシーとレビューの約束

入口は[DiagnosticLog](../Sources/SumibiIME/DiagnosticLog.swift)だけとする。
呼出側が渡せるのは固定enumと数値だけ。文字列や生のErrorを受け取る出力APIを追加しない。
変換エラーは固定enumへ分類し、`network(String)`などの付随情報を捨てる。

どの設定・ビルドでも、原文、変換候補、周辺文字列、辞書の内容、クリップボード、
APIキー、URL、通信応答、生のエラー説明、キーコード、アプリ名を記録しない。
数値を使って文字コードや秘密情報を符号化して出すことも禁止する。
詳細ログの時刻・件数・範囲から操作の傾向は分かるため、共有する期間は必要最小限に絞る。

レビューではすべての呼出しと数値の由来を確認し、入力内容を
`privacy: .private`で隠すだけの処置を許可しない。記録しないことが原則。
この変更より前の開発版で保存されたログは、コード変更によって消えるわけではない。

## 検証

[DiagnosticLogTests](../Tests/SumibiIMETests/DiagnosticLogTests.swift)の6件で、
既定の通常イベント非出力・失敗だけの出力・詳細出力・設定切替・旧フラグ無効化・
全変換エラーの固定カテゴリ化・入口の一本化を確認する。
実ユーザーの文字列・設定・KeychainやOSの過去ログは読み取らない。
成果物検証でも旧入力文字列ログの識別文字列が存在しないことを確認する。

実機では通常変換・候補選択・Escが変わらないことと、設定の無効／有効／無効の順に
通常操作ログが出ない／詳細イベントが出る／出なくなることを確認する。
失敗したときだけ固定カテゴリのエラーが残ることも確認する。
実機確認は自動テストとは分けて記録する。

### 実機確認結果（2026-10-04）

- 通常版に更新後、利用者が通常変換・候補選択・Escの従来動作を確認した。
- 詳細設定が未設定の状態で、リアルタイム監視により
  `conversionFailed / offline`の1件を確認。数値情報も空で、生の入力・通信エラー文は記録されなかった。
- 詳細設定を有効にしてABCから安全に再起動したあと、変換成功・候補表示／移動／選択・
  Escによる取消・セッション操作のイベントを確認。固定名と数値だけの形式であることを検証した。
- 設定を削除して元の未設定（無効）へ戻し、ABCから再起動した。
  利用者が通常変換を再確認し、その間のリアルタイム診断ログは0件だった。
- 監視結果は固定名と数値形式の判定だけを集計し、入力文字列やログ本文をファイル保存していない。
  確認後に、この作業で開始した3本の監視を停止した。

保存済みログの絞り込み条件を修正しても実機のイベントを取得できなかったため、
実機の出力・非出力はリアルタイム監視で確認した。
実機で確認した失敗カテゴリは`offline`のみ。他の分類は自動テストの確認範囲であり、
全API事業者・全ネットワーク条件で実機試験済みとはしない。
