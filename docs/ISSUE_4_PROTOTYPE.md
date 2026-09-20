# Issue #4: InputMethodKit入力・置換・Undo試作の検証記録

2026-09-20時点。これは製品版ではなく、[Issue #4](https://github.com/kiyoka/Sumibi-mac/issues/4)の成立性を調べるための独立した試作である。iOS版とのコード共有、BYOK通信、設定アプリ、メニューバー常駐、配布パッケージは含めない。

## 構成と実行

- `SumibiPrototypeCore`: キー入力、待ち行列、初回変換、追加候補、失敗回復の状態管理。OSに依存しない自動テストの対象。
- `SumibiPrototypeIME`: `IMKServer`と`IMKInputController`を使うIME本体。変換は通信せず、0.6秒後の模擬応答を使う。`ohayou`は`おはよう`、`arigatou`は`ありがとう`、その他は`【原文】`を返す。
- `Prototype/build.sh`: 開発用の`.app`を`.build/prototype/`に作る。既定はアドホック署名。`SUMIBI_PROTOTYPE_SIGN_IDENTITY`に手元のApple Development証明書の名前またはIDを指定すれば開発者署名する。どちらも公証・配布用の署名ではない。

macOS 26以上とXcodeのSwift環境で`swift test`、`sh Prototype/build.sh`を実行する。実機の入力ソースとして試す場合は、`security find-identity -v -p codesigning`で自分のApple Development証明書を確認し、そのIDを`SUMIBI_PROTOTYPE_SIGN_IDENTITY`に指定してビルドする。生成された`.app`を`~/Library/Input Methods/`へコピーし、入力ソースに追加する。入力ソースがすぐに表示されない場合は、ログアウト・再ログイン後に確認する。ログアウトはユーザー自身の判断で行い、試作スクリプトからは行わない。入力ソースは自動選択しない。

`defaults write dev.kiyoka.SumibiPrototypeIME PrototypeResponseMode -string failure`で模擬失敗、`-string timeout`で60秒後の模擬タイムアウト、`-string success`で成功に切り替えられる。設定変更後はIMEプロセスを再起動する。実際のAPI通信や課金は一切発生しない。

## 確認済み

| 項目 | 結果 |
| --- | --- |
| ビルドと署名 | アドホック署名・Apple Development署名の両方で成功。`plutil -lint`と`codesign --verify`も成功 |
| 状態管理の自動テスト | 11件成功。初回結果後の待機文字、連続`Control + J`、失敗時の原文維持・入力順序・明示的な再試行、1,000文字の境界、候補切替の条件、入力先変更後の救済と遅延応答破棄を確認 |
| 開発用IMEの起動 | `open -n -a`でプロセス起動を確認 |
| 入力ソース登録 | `TISRegisterInputSource`は`noErr`を返した。ただし、初回のログアウト・再ログイン後もmacOSの入力ソース一覧と全入力ソース照会には表示されなかった。この時点の設置物はアドホック署名だった。その後、Apple Development証明書で署名し直した版を設置したが、ログイン後の一覧更新は未確認 |

試作IMEは`~/Library/Input Methods/SumibiPrototypeIME.app`に配置済み。これは開発用の一時的な設置で、配布経路の成立性を意味しない。

## 実アプリで未検証の項目

入力ソースとして選択できていないため、下記は**成功と判定していない**。

1. メモなどの標準テキスト欄で、英字追跡表示、初回`Control + J`の確定、2回目の候補表示・置換を確認する。
2. 通常Enterが改行1回、送信欄では送信1回となり、原文が欠落・重複しないことを確認する。
3. 標準テキスト欄と別のアプリで、初回変換・候補切替の`Command + Z`をそれぞれ試し、Undoが原文まで戻るか記録する。
4. 応答中の文字・Enter・Backspace・連続`Control + J`、模擬失敗と60秒タイムアウトを試す。
5. 応答中にカーソルまたは入力先を変え、古い結果が誤挿入されず、保留文字をIMEのメニューからコピーできることを試す。

macOSや入力先アプリが、`IMKTextInput`の範囲取得・置換・Undo履歴をどう扱うかは、実機のアプリ横断試験で確かめる必要がある。

## 現時点で分かった制限

`IMKInputController.handle(_:client:)`から通常のEnterは原文を確定して`false`を返せるため、同じキーイベントを入力先へ渡す構成にしている。ただし実アプリでの1回だけの改行・送信は未確認である。

一度IMEが消費して待ち行列に保管したEnter・Backspace・`Control + J`を、後から元のキーイベントとして入力先アプリに渡す公開`IMKTextInput` APIは確認できなかった。状態管理は入力順を保持するが、試作アダプターは遅延キーを勝手に改行や削除へ読み替えず、適用不能なキーをIMEメニューに表示する。したがって**待機中の制御キーの完全な再生は未実装**であり、Issue #4の受け入れ条件を満たしたとは扱わない。追加のイベント合成方式は権限・アプリ互換性・誤操作のリスクを検討し、採用するなら明示的に仕様を決める必要がある。

`setMarkedText`と`insertText`による確定が、利用者の求める「原文を選択して置換し、1回のUndoで原文へ戻す」と同じ履歴を作るかも未確認である。アプリ差異が出る可能性があるため、目視試験前に成立すると断定しない。

入力ソースの一覧更新は、アプリのInfo.plistに入力モード・アイコンを補い再登録した後も即時には反映されなかった。初回の再ログイン時も、アドホック署名版は一覧に現れなかった。開発者署名版で再ログインした場合の結果は未確認である。`codesign --verify`は両方で成功する一方、`spctl --assess`は開発者署名版も配布用アプリとして拒否する。後者は公証されていない開発ビルドでは想定されるため、この結果だけを入力ソース除外の原因とは断定しない。

## 関連するApple資料

- [InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)
- [IMKServerの初期化](https://developer.apple.com/documentation/inputmethodkit/imkserver/init%28name%3Abundleidentifier%3A%29)
- [IMKInputController](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)
- [第三者入力メソッドの管理](https://developer.apple.com/library/archive/qa/qa1810/_index.html)

ソース登録・入力モードのキーは、使用中のmacOS SDKの`TextInputSources.h`および`TextServices.h`も照合した。
