# Issue #4: InputMethodKit入力・置換・Undo試作の検証記録

2026-09-22時点。これは製品版ではなく、[Issue #4](https://github.com/kiyoka/Sumibi-mac/issues/4)の成立性を調べるための独立した試作である。iOS版とのコード共有、BYOK通信、設定アプリ、メニューバー常駐、配布パッケージは含めない。

## 構成と実行

- `SumibiPrototypeCore`: キー入力、待ち行列、初回変換、追加候補、失敗回復の状態管理。OSに依存しない自動テストの対象。
- `SumibiPrototypeIME`: `IMKServer`と`IMKInputController`を使うIME本体。変換は通信せず、0.6秒後の模擬応答を使う。`ohayou`は`おはよう`、`arigatou`は`ありがとう`、その他は`【原文】`を返す。macOS 27では入力セッションがキー1つごとに終了するため、入力途中の状態は`PrototypeRuntime`(プロセス全体で1つ)が持つ。
- `SumibiPrototypeIME/CandidateWindow.swift`: 自前の候補一覧ウィンドウ。`IMKCandidates`の選択APIがこの環境で機能しないため、描画・選択位置・クリック判定を自分で持つ。
- `Prototype/build.sh`: リリース構成で開発用の`.app`を`.build/prototype/`に作る。入力メソッド用のTIFF、標準アプリアイコン、`PkgInfo`、日英の表示名を含める。既定はアドホック署名。`SUMIBI_PROTOTYPE_SIGN_IDENTITY`に手元のApple Development証明書の名前またはIDを指定すれば開発者署名する。どちらも公証・配布用の署名ではない。

macOS 26以上とXcodeのSwift環境で`swift test`、`sh Prototype/build.sh`を実行する。実機の入力ソースとして試す場合は、`security find-identity -v -p codesigning`で自分のApple Development証明書を確認し、そのIDを`SUMIBI_PROTOTYPE_SIGN_IDENTITY`に指定してビルドする。生成された`.app`を`~/Library/Input Methods/`へコピーする。インストール後の表示にはログアウト・ログインが必要になる場合があるが、試作スクリプトからは実行しない。システム設定の「キーボード → 入力ソース → 編集 → 追加」で日本語を選び、「Sumibi 試作版」を追加する。古い登録情報が残る環境では、項目名が`com.apple.inputmethod.Japanese`で、副題だけが「Sumibi 試作版」と表示されることがある。入力ソースは自動選択しない。

`swift Prototype/check-registration.swift`は読み取り専用で、登録台帳に本体・日本語モードが存在するかとAPI上の有効状態を表示する。登録APIが成功しただけでシステム設定への表示まで成功したとは判定しない。

`defaults write dev.kiyoka.inputmethod.SumibiPrototypeProbe1 PrototypeResponseMode -string failure`で模擬失敗、`-string timeout`で60秒後の模擬タイムアウト、`-string slow`で5秒後の模擬成功(応答待ち中の入力を手で試すため)、`-string success`で0.6秒後の成功に切り替えられる。設定変更後はIMEプロセスを再起動する。実際のAPI通信や課金は一切発生しない。

## 確認済み

| 項目 | 結果 |
| --- | --- |
| ビルドと署名 | アドホック署名・Apple Development署名の両方で成功。現行のリリース構成では`plutil -lint`と`codesign --verify`も成功。公証は未実施 |
| 状態管理の自動テスト | 11件成功。初回結果後の待機文字、連続`Control + J`、失敗時の原文維持・入力順序・明示的な再試行、1,000文字の境界、候補切替の条件、入力先変更後の救済と遅延応答破棄を確認 |
| 開発用IMEの起動 | `open -n -a`でプロセス起動を確認 |
| 入力ソース登録 | 旧識別子`dev.kiyoka.SumibiPrototypeIME`では、2回のログイン後も登録APIが`noErr`を返すだけで、全入力ソース照会に現れなかった。新しい試験用識別子`dev.kiyoka.inputmethod.SumibiPrototypeProbe1`とリリース構成では、再登録直後に本体と日本語モードを照会でき、別プロセスからも確認できた |
| システム設定への表示 | 新識別子のアプリを置いてログアウト・ログイン後、日本語一覧の`com.apple.inputmethod.Japanese`という名称で発見。副題は「Sumibi 試作版」。追加後、本体と日本語モードの両方がAPI上で有効となり、モード選択APIも成功した |
| 実アプリへの入力 | 当初は1字入力するたびに前の1字を上書きする不具合が出た。原因はmacOS 27のIMKが消費したキーごとに入力セッションを終了することと判明し(下の節を参照)、状態をプロセス共有へ移して解消した。メモ(Notes)での物理キーボードにより、文字の蓄積、初回変換、候補窓、キーボードとマウスでの候補選択、Undo、Enter、応答待ち中の入力、模擬失敗、入力先変更時の誤挿入防止を確認した(次表)。TextEditでも文字の蓄積、初回変換、候補窓、候補選択を確認した。Undoの粒度だけはアプリ差があり、60秒タイムアウトの実測は未確認 |

試作IMEは`~/Library/Input Methods/SumibiPrototypeIME.app`に配置済み。これは開発用の一時的な設置で、配布経路の成立性を意味しない。

## 実アプリで確認した動作(メモ・物理キーボード・2026-09-22)

| 操作 | 結果 |
| --- | --- |
| `ohayou`と入力 | 6文字すべてが未確定文字列として蓄積・表示される |
| `Control + J` | 約0.6秒後に`おはよう`へ置換される |
| もう一度`Control + J` | 候補窓が開き、先頭候補が強調される |
| 候補窓で下キー → Enter | 強調が移動し、強調中の候補に置換される |
| 候補窓で候補をクリック | クリックした候補に置換される |
| 候補窓でEscape | 窓が閉じ、本文は直前の変換結果のまま |
| 初回変換後に`Command + Z` | 原文`ohayou`へ戻る(戻った範囲が選択される。通常のテキスト編集Undoと同じ挙動) |
| 候補置換後に`Command + Z` | 原文`ohayou`まで戻る |
| 変換せずEnter | 改行が1回だけ入り、原文が残る(欠落・重複なし) |
| 応答待ち中の文字・Enter・Backspace・連続`Control + J` | 下の「応答待ち中の入力」の表を参照 |
| 模擬失敗(`failure`) | 原文が残り、そのまま入力を続けられる。IMEメニューにエラーが表示される |
| 応答待ち中に別アプリへ切り替え | 切り替え先へ誤挿入されず、元のアプリには原文が残る。待機中に打った文字はIMEメニューの「保留文字をコピー」で取り出せた |

TextEditでも、文字の蓄積、初回変換、2回目の`Control + J`での候補窓、下キーとEnterでの候補選択を同様に確認した。Undoの挙動だけがメモと異なる(下の「現時点で分かった制限」を参照)。

### まだ確認していないこと

1. チャット系アプリなどの送信欄でのEnter(送信が1回だけになるか)。
2. 60秒タイムアウトの実測(模擬失敗と同じ経路で、遅延だけが異なる)。
3. 1,000文字の境界は自動テストのみで、実アプリでは未確認。
4. 公証・配布経路。

macOSや入力先アプリが`IMKTextInput`の範囲取得・置換・Undo履歴をどう扱うかには差異があり得るため、アプリ横断の試験は引き続き必要である。

## 現時点で分かった制限

`IMKInputController.handle(_:client:)`から通常のEnterは原文を確定して`false`を返せるため、同じキーイベントを入力先へ渡す構成にしている。メモでは改行が1回だけ入り、原文の欠落・重複がないことを確認した。送信欄を持つアプリ(チャットなど)での1回だけの送信は未確認である。

一度IMEが消費して待ち行列に保管したEnter・Backspace・`Control + J`を、後から元のキーイベントとして入力先アプリに渡す公開`IMKTextInput` APIは確認できなかった。状態管理は入力順を保持するが、試作アダプターは遅延キーを勝手に改行や削除へ読み替えず、適用不能なキーをIMEメニューに表示する。したがって**待機中の制御キーの完全な再生は未実装**であり、Issue #4の受け入れ条件を満たしたとは扱わない。追加のイベント合成方式は権限・アプリ互換性・誤操作のリスクを検討し、採用するなら明示的に仕様を決める必要がある。

確定方式とUndo履歴の関係は実測で判明した。未確定文字列(`setMarkedText`)から`insertText`で確定すると、原文はUndo履歴に入らず、Undoでは原文へ戻せない。**原文をまず通常の文字として確定し、応答が返ってからその範囲を置換する**方式に変えることで、メモでは1回のUndoで原文へ戻った。

ただしUndoの粒度は入力先アプリの方針であり、公開`IMKTextInput` APIからは区切りを入れられない。実測は次のとおり。

| 入力先 | 初回変換後の`Command + Z`(1回) |
| --- | --- |
| メモ(Notes) | 原文`ohayou`へ戻る(戻った範囲が選択される) |
| TextEdit | 変換結果「おはよう」が消える。原文は戻らない。利用者が前に打った文字は残る |

TextEditでは、原文の確定と応答後の置換が1つのUndoにまとめられるため、原文の状態を経由できない。製品では、この差異を仕様として受け入れるか、アプリごとの挙動を調べて注意を出すかを決める必要がある。

旧識別子の版では、アプリの起動、LaunchServices登録、`TISRegisterInputSource`の`noErr`を確認しても、`TISCreateInputSourceList(nil, true)`には現れなかった。初回の再ログインではアドホック署名版、2回目の再ログインではApple Development署名版がそれぞれ表示されず、macSKKは同じ`~/Library/Input Methods`から正常に列挙できた。

新しい試験用識別子に`.inputmethod.`を含め、同時にリリース構成へ変更すると、同じログインセッションで`TISRegisterInputSource`後に本体と日本語モードを列挙できた。識別子とビルド構成を同時に変えたため、どちらが決定的だったかはまだ切り分けていない。入力コントローラーの実際のObjective-Cクラス名がInfo.plistと一致すること、`get-task-allow`の権限が付いていないこと、署名が有効なことも確認した。開発用署名のため`spctl --assess`は配布用アプリとして拒否するが、この環境ではそれでもTIS列挙までは成功した。公証がシステム設定への反映に必要かは未確定である。

`TISEnableInputSource`を試験用モードだけに適用すると、そのプロセスの有効な入力ソース一覧には現れた。しかし、システム設定を開き直しても追加画面には現れなかった。試験後に`TISDisableInputSource`は`noErr`を返したが、別プロセスで再照会するとモードが有効と報告されるため、両APIの返値だけでは永続的な有効状態を判断できない。

さらに、システム設定へ追加する前は親IME本体が`apiEnabled=false`、日本語モードが`apiEnabled=true`と判明した。使用中のSDKの`TextInputSources.h`によればモードを選ぶには親IMEも有効でなければならない。親本体とモードの両方に`TISEnableInputSource`を適用しても親は無効のままで、`TISSelectInputSource`は`paramErr`（-50）を返した。未使用の標準キーボード配列を一時的に有効化して一覧更新を促したが、当時はシステム設定にSumibiが現れず、その配列は元の無効状態へ戻した。表示サービスの再起動はSIPにより拒否されたため、それ以上のシステムサービス操作は行っていない。

新識別子の版でログアウト・ログインした後、日本語一覧を調べ直すと`com.apple.inputmethod.Japanese`という項目があり、副題が「Sumibi 試作版」だった。`Sumibi`検索では候補が消えるため見落としていた。`InfoPlist.strings`にモード識別子を書いていたが、一覧に用いるキーは`ComponentInputModeDict`のモードキー`com.apple.inputmethod.Japanese`だったため修正した。追加すると親IME本体も有効となり、`TISSelectInputSource`は`noErr`を返した。修正版を署名して上書きした後も、このセッションの設定画面には旧名称がキャッシュされている。表示名の更新には追加調査が必要であり、再ログインを繰り返して解決する方針は取らない。

TextEditで自動操作のキー入力を試したところ、試作IMEのプロセスは起動したが、模擬変換は起こらなかった。自動操作がIME経由のキーイベントを再現できていない可能性と、試作IMEがキーを受け取っていない可能性の両方が残る。人手で入力ソースを選択して物理キーボードから試すまで、実アプリ動作の成立は未確認とする。Issue #4は未完了である。

人手による初回入力では、キーを1字入力するたびに直前の1字を上書きし、最後の1字だけが見える不具合が再現した。入力先の同一性確認に`uniqueClientIdentifierString()`を使っていたが、この値は呼び出しごとに変化し得るため、毎回別の入力先と誤判定して状態を破棄していた。IMKクライアントプロキシのオブジェクト同一性へ変更すると自動操作では`ohayou`全体を保持できたが、物理キーボードでは同じ不具合が再発した。プロキシのオブジェクトもイベントごとに同一とは限らない。

AppleのSDKヘッダーでは`IMKServer`が入力セッションごとに`IMKInputController`を作成すると説明されている。そのため、コントローラー内で不安定な入力先識別子を重ねて比較する処理を除去した。実際には、macOS 27ではこの「入力セッション」がキー1つごとに終了・再作成されるため、状態はコントローラーの外へ出す必要があった(次節)。非同期応答の誤挿入防止は、要求ID、記録した置換位置(アンカー)、対象文字列の一致で検証する。

## macOS 27で判明したIMKの挙動(2026-09-22、物理キーボードと診断ログによる)

環境はmacOS 27.0、Xcode 27.0、Apple Development署名、非サンドボックス。入力先はメモ(Notes)とTextEdit。

### 消費したキーごとにセッションが終了する

IMEが`handle(_:client:)`で`true`(消費)を返すと、約6ms後に`-[_IMKServerLegacy sessionFinished_CommonWithClientWrapper:controller:]`経由で`deactivateServer`が呼ばれ、コントローラーは破棄されて作り直される。ログ上の順序は`Setting marked text` → `Menu` → `xpc_connection_cancel()` → `Deactivate Server`。入力先との接続もこのとき閉じられる。

- 入力先アプリ(メモ・TextEdit)、`setMarkedText`の引数の形(文字列・属性付き・非同期)、`insertText`だけの確定、何も呼ばずに`true`を返すだけ、App Sandboxの有無のいずれでも変わらなかった。
- `false`を返した(消費しない)キーではセッションは終了しない。
- クライアント側は`_IMKXPCCompatibilityDOProxyInterposerLegacy`、サーバー側は`_IMKServerLegacy`だった。IMKには`_Modern`系の型もあるが、どちらを使うかの条件は特定できていない。
- この状態では、コントローラー内のインスタンス変数に入力途中の状態を置くと、1キーごとに失われる。これが「1文字入力するたびに直前の1文字が上書きされる」不具合の原因だった。

対策として、入力途中の状態を`PrototypeRuntime`(プロセス全体で1つ)へ移した。消費したキーの直後0.3秒以内の`deactivateServer`は、実際のフォーカス移動ではないとみなして状態を保つ。未確定文字列がないときの`commitComposition`は何もしない(確定直後にも呼ばれ、直前の変換結果と置換位置を消してしまうため)。

### 応答待ちの完了は、入力先が生きている保証がない

セッション終了後は、以前のクライアントプロキシで入力先へ書き込めない。新しいコントローラー(新しいセッション)がいつ作られるかは入力先アプリ側の都合で、IME側から制御できない。作られる回と、数秒待っても作られない回があった。

診断の結果、**新しいセッションが作られる契機は「IMEが入力先へ書き込むこと」**と判明した。キーを消費してもセッションは終了するだけで、入力先は次のキーが来るまで新しいセッションを作らない。

- 初回変換の要求時は、原文を`insertText`で確定するため、その書き込みが契機となって約0.2秒後に新しいセッションが作られる。応答(模擬5秒)が返る時点で生きたセッションがあり、検証付きで書き込める。
- 一方、応答待ち中のキーは状態機械に溜めるだけで入力先へ何も書かないため、打鍵が止まるとセッションが生まれず行き止まりになる。実際に、応答が返っても15秒間何も起こらず、次のキーを押した時点で反映される状況を再現した。
- 対処として、**入力先へ無害な呼び出しを行い、次のセッションを作らせる**(`pokeClient(_:)`)。応答待ち中にキーを溜めたときと、追加候補を要求したときに呼ぶ。これにより上記の行き止まりは解消した。
- 呼び出しの種類は重要である。空文字の`insertText`は文書の変更として扱われ、**入力先のUndoのまとまりを壊した**。TextEditでは、利用者が試作IMEを使う前に打った文字(`hello `)まで1回の`Command + Z`で消えた。TextEditの通常のUndoは単語単位(`hello world`と打って`Command + Z`で`world`だけ消える)なので、これは試作側が引き起こした劣化である。
- 文書を変更しない`setMarkedText("")`だけの呼び出しに変えると、メモとTextEditの両方で約0.2秒後に新しいセッションが作られ、かつ利用者自身の入力は`Command + Z`で消えなくなった。既定はこの方式(`PrototypePokeStyle`の`marked`)。`insert`と`both`は比較用に残している。

なお、セッション終了後の窓口(`IMKTextInput`のプロキシ)は、`selectedRange()`などの読み取りは`NSNotFound`を返すが、**`insertText`による書き込みは通る**ことも実験で確認した(キーを押さずに変換結果が反映された)。ただしこの経路では対象の検証ができず、利用者がカーソルを動かしていた場合に誤挿入する恐れがあるため、採用していない。

現在の完了経路は、(1)0.25秒ごとの再試行、(2)新しいセッション作成時、(3)次のキー入力の冒頭、の3つで、いずれも検証付きで書き込む。

### 応答待ち中の入力(模擬5秒の`slow`モードで確認)

メモでの物理キーボードにより、次を確認した。

| 操作 | 結果 |
| --- | --- |
| `ohayou` → `Control + J` → すぐ`desu` | 応答後に`おはようdesu`。溜めた文字が入力順に反映される |
| `arigatou` → `Control + J` → すぐEnter | `ありがとう`。**改行は入らない**(下記の制限) |
| `ohayou` → `Control + J` → すぐBackspace | `おはよう`。**削除は適用されない**(下記の制限) |
| `ohayou` → `Control + J` → すぐ`Control + J` | `おはよう`になった後、候補窓が開く |

Enter・Backspaceが適用されないのは、消費済みの制御キーを後から本来のキーイベントとして入力先へ渡す公開APIがないという既知の制限による(下の「現時点で分かった制限」を参照)。試作は勝手に改行や削除へ読み替えず、IMEメニューに「未適用の制御キー」として記録する。

### 候補窓

- セッション終了のたびにIMKが候補窓を閉じる。`candidates(_:)`は呼ばれず、窓は空(幅51ピクセル)になるため、`setCandidateData(_:)`で候補を直接渡す必要がある。
- `setCandidateFrameTopLeft(_:)`は効かなかった。IMKが使う`IMKUIPanel`ウィンドウを直接動かして位置を決めた。
- 確定直後は、入力先が行矩形を返さない(`{{0,0},{0,0}}`)。未確定文字列の表示中に控えておいた矩形で位置を決めた。
- 窓が閉じられるため、「表示しているべきか」を自前で保持し、セッション終了のたびに再表示する。さらにパネルのNSWindowに`hidesOnDeactivate = false`を設定すると、キー入力のたびに窓が消える症状は止まった。
- **マウスクリックでの候補選択は動いた**。`candidateSelected(_:)`に正しい候補文字列が渡り、置換も成功した。
- **キーボードでの候補選択は`IMKCandidates`では成立しなかった**。`setCandidateData(_:)`で候補を直接渡した場合、パネルは文字列を描画するが、選択APIの層が機能しない。
  - `selectedCandidateString()`は常に`nil`を返す。
  - `candidateIdentifier(atLineNumber:)`は行番号にかかわらず常に`0`を返す(表示から0.1秒後に呼んでも同じ)。
  - そのため`selectCandidate(withIdentifier:)`は`true`を返すが実際には何も選択されず、`interpretKeyEvents`による`moveDown:`も起点がないまま何も起こらない。`update()`の呼び出し、初期選択の設定、遅延実行のいずれも効かなかった。
  - 本来は`IMKInputController.candidates(_:)`経由で候補を渡すと識別子が登録されるはずだが、セッションが1キーごとに終了するため、IMKはこのコールバックを呼ばない(`candidates()`が呼ばれた記録がない)。
  - `super.deactivateServer(_:)`を呼ばずに候補窓を保とうとする実験も行ったが、窓は隠れたままで改善しなかった。XPC接続の切断は、こちらの`deactivateServer`が呼ばれる前にIMKの内部で完了しているため。

### 自前の候補窓(`CandidateWindow.swift`)

上記のため、`IMKCandidates`をやめて候補一覧を自分で描くことにした。`.borderless`と`.nonactivatingPanel`のNSPanelに、候補の描画・選択位置・クリック判定を自前で持つ実装(`Sources/SumibiPrototypeIME/CandidateWindow.swift`)。IMKの選択APIには一切依存しない。

メモでの物理キーボードにより、次を確認した。

- 2回目の`Control + J`で候補窓が表示され、先頭候補が強調される。
- 下キーで強調が移動する。
- Enterで、強調中の候補に本文が置換される。

セッション終了で窓が隠れた場合に備えて`reshow()`も用意しているが、`hidesOnDeactivate = false`と`orderFrontRegardless()`により、実際には隠れずに済んでいる。

### 入力先の報告

- 未確定文字列の表示中、メモは`selectedRange`を未確定範囲と同じ`(0,6)`で返す。「カーソルは末尾で長さ0」を前提にした検証は成立しない。未確定範囲(`markedRange`)を対象として検証している。

### Undo

初回実装では、初回変換の確定を未確定文字列(`setMarkedText`)からの`insertText`で行っていた。この方式では原文が入力先のUndo履歴に一度も現れず、変換直後に`Command + Z`を押しても「おはよう」が選択状態になるだけで、`ohayou`へは戻らなかった。

対策として、原文をまず通常の文字として`insertText`で確定し(この時点でUndo履歴に入る)、応答が来たらその範囲を`replacementRange`付き`insertText`で置換する方式に変えた(`PrototypeRuntime.originalCommitted`で追跡)。この方式で、メモにおいて次を確認した。

- `ohayou` → `Control + J`(「おはよう」)→ すぐ`Command + Z` → `ohayou`に戻る(選択状態になるのは通常のテキスト編集Undoと同じ挙動)。ちらつきなし。
- 候補を選んで置換した場合は、確定と候補置換が別々のUndo単位になるため、`Command + Z`は直前の状態(候補選択前の「おはよう」)に戻る。もう一段階`Command + Z`を押せば`ohayou`まで戻ると推測されるが、この2段階目は未確認。
- 副作用として、2回目の`Control + J`後に候補窓が出るまでの待ち時間が短くなった(下の「応答待ちの完了」の節にある「空文字挿入」の実験による)。

### 診断ログ

`PrototypeInputController.swift`は挙動追跡用のログを出す。利用者の入力内容は記録せず、文字数・キーコード・インスタンス識別子・範囲だけを出す。読み方:

```bash
log show --last 5m --style compact --info \
  --predicate 'subsystem == "dev.kiyoka.inputmethod.SumibiPrototypeProbe1"'
```

macOS 27のセッション挙動はこのログなしには追えなかったため、試作では残している。製品化の際は出力量と項目を見直す。

## 関連するApple資料

- [InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)
- [IMKServerの初期化](https://developer.apple.com/documentation/inputmethodkit/imkserver/init%28name%3Abundleidentifier%3A%29)
- [IMKInputController](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)
- [第三者入力メソッドの管理](https://developer.apple.com/library/archive/qa/qa1810/_index.html)

ソース登録・入力モードのキーは、使用中のmacOS SDKの`TextInputSources.h`および`TextServices.h`も照合した。

識別子と設定画面の更新については、[nagiの開発記録](https://zenn.dev/nvalleo/articles/202608-nagi-macos-ime-mozc-swiftui)と[VietTelexの実機検証記録](https://github.com/ptrinh/viettelex/blob/main/docs/MACOS_IME_NOTES.md)も参照した。両者は独立した開発者の観測であり、SumibiやmacOS 27での保証された仕様としては扱わない。
