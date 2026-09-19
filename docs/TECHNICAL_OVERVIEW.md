# Sumibi for macOS 技術解説

## 1. この文書の目的

本書は、macOSのIME開発経験がなくてもSumibi for macOSの構成を理解できるように、使用する技術と処理の流れを説明する。

仕様として合意済みの内容は[`SPEC.md`](SPEC.md)を正とする。本書に記載する推奨構成や実装案は、仕様検討と実装設計のための技術的な説明であり、未合意のものを製品仕様として確定するものではない。

## 2. 使用する主な技術

| 技術 | 役割 |
| --- | --- |
| InputMethodKit | macOSの入力メソッド本体と、入力先アプリとの通信 |
| AppKit | 候補ウィンドウ、状態表示、入力メニューなどIME固有のUI |
| SwiftUI | API設定やユーザー辞書などの設定画面 |
| Foundation Models | macOS 27以降で利用条件を満たす場合のApple Private Cloud Compute（PCC）への接続 |
| URLSession | 利用者のAPIキーを使うOpenAI互換API（BYOK）との非同期通信 |
| Keychain Services | APIキーの安全な保存 |
| UserDefaults | APIエンドポイント、モデル名など機密ではない設定の保存 |

macOS版では、iOS版のような画面上のキーボードを描画しない。物理キーボードからの入力をmacOS経由で受け取り、入力先アプリへ文字列を返す。

Appleの資料：

- [InputMethodKit](https://developer.apple.com/documentation/inputmethodkit)
- [IMKInputController](https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller)
- [IMKServerInput](https://developer.apple.com/documentation/inputmethodkit/imkserverinput)
- [NSEvent](https://developer.apple.com/documentation/appkit/nsevent)
- [IMKCandidates](https://developer.apple.com/documentation/inputmethodkit/imkcandidates)

## 3. 全体構成

```text
物理キーボード
      │
      ▼
macOS
      │ キーイベント
      ▼
Sumibi InputMethodKit
  ├─ 入力文字列を追跡
  ├─ Control + Jを判定
  ├─ PCCまたはBYOKのLLMへ変換を依頼
  └─ 原文を変換結果で置換
      │
      ▼
メモ、Safari、VS Codeなどの入力先アプリ
```

アプリ内部は、次の3領域に分割する。

```text
Sumibi.app
├─ InputMethodServer
│  ├─ IMKServer
│  ├─ SumibiInputController
│  └─ 候補ウィンドウ
├─ ConversionCore
│  ├─ PCC利用可否・利用枠の判定とBYOKへの切替
│  ├─ Foundation ModelsのPCCクライアント
│  ├─ OpenAI互換APIクライアント
│  ├─ プロンプト生成
│  ├─ レスポンス解析
│  └─ エラー処理
└─ Settings
   ├─ SwiftUI設定画面
   ├─ UserDefaults
   └─ Keychain
```

`ConversionCore`はmacOS版専用の変換処理として実装・保守する。iOS版の`SumibiCore`は設計・実装の参考にするが、コードや共通パッケージを両版で共有せず、実装同期も行わない。macOS版のソースコードと依存関係はSumibi-macリポジトリで独立して管理する。PCCクライアントはmacOS 27以降のAPIに依存するため、macOS版の内部でBYOKクライアントと分離する。

## 4. InputMethodKitの役割

InputMethodKitは、macOSの入力メソッドと各アプリの間を接続する標準フレームワークである。

### 4.1 IMKServer

`IMKServer`はSumibiの入力メソッドサービスをmacOSへ公開し、入力先アプリとの接続を管理する。

入力メソッドのアプリが起動すると、`Info.plist`に記載した接続名とBundle IDを使用して`IMKServer`を生成する。

### 4.2 IMKInputController

`IMKInputController`は入力セッションごとに生成される。Sumibiでは、このサブクラスが次の処理を担当する。

- キーイベントの受信
- 入力文字列の追跡
- `Control + J`の検出
- Backspaceやカーソル移動への対応
- 変換処理の開始とキャンセル
- 変換結果の確定
- 入力先変更時の状態破棄

入力先アプリや入力欄が変わるたびにセッションも変わり得るため、追跡状態をアプリ全体の単一変数として管理しない。入力セッションごとに独立して管理する。

### 4.3 IMKTextInput

入力先アプリは`IMKTextInput`を通してSumibiから操作される。

主に次の操作を使用する。

- `setMarkedText`: 追跡中の未確定文字列を表示または更新する
- `insertText`: 変換結果または原文を確定する
- `selectedRange`: 入力先の選択範囲を確認する
- `attributedSubstring`: 置換対象の文字列を確認する

Sumibiが入力先アプリのテキスト領域へ直接アクセスするのではなく、macOSが提供するこの通信経路を使用する。

## 5. キーイベントの処理

入力メソッドは、概念的には次のメソッドでキーイベントを受け取る。

```swift
override func handle(
    _ event: NSEvent!,
    client: Any!
) -> Bool {
    // 押されたキーと修飾キーを調べる
    // 通常文字なら追跡バッファへ追加する
    // Control + Jなら変換を開始する
    // Backspaceなら追跡文字列も削除する
}
```

`NSEvent`から、入力文字、キーコード、ControlやCommandなどの修飾キー、キーリピート状態を取得する。

戻り値の意味は次のとおりである。

- `true`: Sumibiがイベントを処理し、入力先アプリには渡さない
- `false`: Sumibiでは処理せず、入力先アプリへ渡す

基本的な振り分け案：

| 操作 | 処理案 |
| --- | --- |
| 通常の文字入力 | Sumibiが受け取り、追跡文字列を更新する |
| `Control + J` | Sumibiが受け取り、変換を開始する |
| Backspace | Sumibiが受け取り、追跡文字列の末尾を削除する |
| Commandを使うショートカット | 現在の追跡状態を安全に処理して、入力先アプリへ渡す |
| カーソル移動 | 追跡を終了し、入力先アプリへ渡す |
| IMEの無効化 | 原文を確定し、追跡状態を破棄する |

ショートカットや特殊キーの詳細な扱いは、別途仕様として決定する。

## 6. 追跡文字列と控えめな印

macOSの入力メソッドには「未確定文字列（marked text）」という仕組みがある。Sumibiが`setMarkedText`を呼ぶと、入力先アプリが文字列を表示し、未確定であることを下線などで示す。

未確定文字列を使用する利点：

- 変換対象範囲をmacOSが管理できる
- 原文から変換結果への置換が安全になる
- カーソル移動やアプリ切り替え時に入力を確定できる
- 他のアプリを操作するためのAccessibility権限を必要としない
- 追跡中の文字列へ控えめな印を表示できる

技術上の制約として、未確定文字列の最終的な描画は入力先アプリが担当する。Sumibiから下線の色や太さを指定しても、アプリによっては属性が無視され、macOS標準の下線になる可能性がある。

### 推奨案

最初のバージョンでは、追跡文字列をmacOS標準の未確定文字列として扱う。

- 対応する入力先では、非常に薄い炭火色の下線属性を指定する
- 属性を反映できない入力先では、標準の未確定文字列表示へフォールバックする
- 背景色や文字色は変更しない
- 独自の重ね合わせウィンドウによる下線描画は行わない

独自ウィンドウで下線を描く方式は、複数行、スクロール、縦書き、ブラウザ、文字サイズの違いへの対応が複雑になるため、初期実装には適さない。

この推奨案はまだ製品仕様として確定していない。

## 7. 変換処理

`Control + J`が押された後の処理案は次のとおりである。

```text
Control + J
    │
    ├─ 現在の追跡文字列をスナップショットとして保存
    ├─ 入力セッションと更新番号を記録
    ├─ macOS 27以降でPCCが利用可能ならPCCを呼び出す
    │    └─ 利用上限到達時は、設定済みBYOKへ最大1回切り替える
    ├─ PCCを利用できない場合はBYOKのAPIを呼び出す
    │
    ├─ 応答時に入力状態が変わっていないか検証
    │
    └─ 問題がなければ日本語を確定
```

通信はSwiftの非同期処理を使用し、入力メソッドのメインスレッドを停止させない。macOS 27未満ではBYOKを必須とする。macOS 27以降でもPCCの権限・デバイス・地域・言語・利用状態を確認し、使えない場合はBYOKを必要とする。

PCCの利用可否は`PrivateCloudComputeLanguageModel.availability`、利用上限は`quotaUsage`で確認する。利用可能状態と利用枠は別概念なので、変換処理中に`quotaLimitReached`エラーが返る場合も処理する。PCCの権限と配布条件が確認できるまで、PCC対応を製品として保証しない。

応答を適用する前に、少なくとも次の状態を検証する。

- 入力先アプリが同じである
- 入力セッションが同じである
- カーソル位置が変わっていない
- 追跡文字列が変わっていない
- IMEが引き続き有効である
- リクエストがキャンセルされていない

状態が変化していた場合、遅れて届いた変換結果を破棄する。これにより、別の入力欄や異なるカーソル位置へ結果が挿入される事故を防ぐ。

## 8. 候補ウィンドウ

InputMethodKitには`IMKCandidates`という標準候補ウィンドウがある。候補の表示、選択、選択結果の通知を処理できる。

候補UIには次の選択肢がある。

### 8.1 IMKCandidatesを使用する

- macOSの他の入力メソッドに近い操作感になる
- キーボード操作や入力位置への追従を実装しやすい
- 独自デザインの自由度は低い

### 8.2 AppKitで独自ウィンドウを作る

- iOS版Sumibiに近い候補表示を実現できる
- 追加候補ボタンや独自の状態表示を配置できる
- 入力位置、画面端、複数ディスプレイ、縦書きなどへの対応が必要になる

初期実装では`IMKCandidates`を使用し、必要性が明確になった段階で独自候補ウィンドウを検討する方法を推奨する。この選択も製品仕様としては未確定である。

## 9. 設定画面

設定画面はSwiftUIで実装し、macOS標準のウィンドウとして表示できる。

設定項目の候補：

- BYOK用のAPIエンドポイント
- BYOK用のモデル名とAPIキー
- PCCの利用状態と、上限到達時のBYOK自動切替への同意
- ユーザー辞書
- 変換指示プリセット
- プライバシー説明とデータ送信への同意
- 接続テスト

入力メソッド自体はバックグラウンドで動作するが、macOSの入力メニューに「Sumibi設定…」を追加し、そこから設定ウィンドウを開く構成にできる。

保存先の基本方針：

- BYOK用のAPIキー: macOS Keychain（PCCのみを使う場合は不要）
- APIエンドポイント、モデル名、その他の一般設定: UserDefaults
- 入力内容と変換対象: 永続保存しない

## 10. インストールと有効化

InputMethodKitを使用するアプリは、通常のmacOSアプリとは起動方法が異なる。

概念的な導入手順は次のとおりである。

1. `Sumibi.app`をビルドする。
2. 入力メソッド用のディレクトリへインストールする。
3. 必要に応じてログアウトまたは入力メソッド関連プロセスを再起動する。
4. システム設定の「キーボード」からSumibiを入力ソースへ追加する。
5. 入力ソースメニューからSumibiを選択する。

製品として配布する場合は、コード署名、公証、App Sandbox、アップデート方法、アンインストール方法も設計する必要がある。具体的な配布方式は未確定である。

## 11. 初期実装の推奨順序

1. InputMethodKitで最小の入力メソッドを起動する
2. 通常文字の入力と未確定文字列の表示を実装する
3. Backspace、カーソル移動、IME切り替えを安全に処理する
4. `Control + J`で固定の文字列へ置換する試作を作る
5. Sumibi-iOSを参照してOpenAI互換APIクライアントを追加する
6. 変換中の状態検証とキャンセルを追加する
7. Keychainと設定画面を追加する
8. PCCの権限と配布条件を確認し、利用可能な環境でPCC接続を追加する
9. PCCの利用上限を変換前・変換中の両方で検出し、BYOKへの切替を検証する
10. 候補表示、Undo、ユーザー辞書を順番に追加する
11. 複数アプリで互換性を検証する
12. インストーラー、署名、公証、配布方法を整備する

最初からすべての機能を実装せず、入力メソッドとしての安全な文字追跡と置換を先に検証する。
