# 製品コードと開発機能

診断ログの切替は通常版・開発版で共通。[診断ログ](DIAGNOSTIC_LOGGING.md)を参照。
旧`PrototypeDiagnoseText`は#14で廃止し、どのモードでも入力文字列を記録しない。

## 命名・配置

| 対象 | 現在の名前・配置 |
| --- | --- |
| Package・モジュール | `Sumibi`、`SumibiCore`、`SumibiIME` |
| IMK接続・共有状態・起動 | `SumibiInputController`、`InputRuntime`、`SumibiMain` |
| バンドルと素材 | `App/`（Info.plist、日英表示、アイコン、辞書） |
| 開発ツール | `Development/Tools/`（素材生成、読み取り専用の登録確認） |
| 模擬応答 | `Sources/SumibiIME/Development/`（開発版だけにコンパイル） |
| 旧ビルド入口 | `Prototype/build.sh`（#15と既存手順の互換用） |

状態の所有者・寿命や入力処理は変更しない。`docs/ISSUE_4_PROTOTYPE.md`は歴史的な調査記録として旧名を残し、現行手順には使わない。

## 通常版

```sh
SUMIBI_DEVELOPMENT_FEATURES=0 swift test
SUMIBI_SIGN_IDENTITY='<Apple Development証明書の名前またはID>' sh App/build.sh
ruby Development/verify-build.rb production .build/app/Sumibi.app
```

出力は`.build/app/Sumibi.app`。署名指定なしはアドホック署名。開発署名はDeveloper ID配布・公証の代替ではない（#15）。ビルド・検証はインストール、起動、入力ソース変更を行わない。

`App/build.sh`は呼び出し元に`SUMIBI_DEVELOPMENT_FEATURES=1`が残っていても、引数なしなら必ず0へ上書きする。通常版はdebug/releaseにかかわらず、模擬応答・入力文字列を含む診断・`--settings`による設定画面単独起動をコンパイルしない。開発設定も読み取らず、実API・入力内容診断なし・`marked`方式に固定する。実APIの利用にはAPIキーと送信同意が必要。通常の文字数・範囲などの診断ログは維持し、ログ量や切り替えは#14で扱う。

`Prototype/build.sh`は開発用引数を拒否し、通常版を作って`.build/prototype/Sumibi.app`へコピーする。#15の未マージの配布スクリプトからも呼び出せる。署名変数の旧名`SUMIBI_PROTOTYPE_SIGN_IDENTITY`も互換用に受け付けるが、`SUMIBI_SIGN_IDENTITY`を優先する。#15統合時は新しい入口へ追従する。

## 明示的な開発版

```sh
SUMIBI_DEVELOPMENT_FEATURES=1 swift test
SUMIBI_SIGN_IDENTITY='<Apple Development証明書の名前またはID>' sh Development/build.sh
ruby Development/verify-build.rb development .build/development/Sumibi.app
```

出力は`.build/development/Sumibi.app`。開発入口は`App/build.sh --development`を呼び、Packageの`SUMIBI_DEVELOPMENT`コンパイル条件を明示的に有効にする。直接Swiftを実行するときも環境変数の明示が必要。

| 設定キー（互換のため旧名を維持） | 開発版の既定値 | 指定できる値 |
| --- | --- | --- |
| `PrototypeResponseMode` | `api` | `api`、`success`、`slow`、`failure`、`timeout` |
| `PrototypePokeStyle` | `marked` | `marked`、`insert`、`both`、`off` |

未知の値は安全な既定値へ戻す。模擬応答は実通信しないが、`api`は実通信する。入力内容の診断は秘密情報を含み得るため通常利用では有効にしない。設定は`org.sumibi.inputmethod.Sumibi`へ保存し、開発版だけが読み取る。例：

```sh
defaults write org.sumibi.inputmethod.Sumibi PrototypeResponseMode -string success
defaults delete org.sumibi.inputmethod.Sumibi PrototypeResponseMode
```

開発版も登録IDは通常版と同じであり、同時登録する別製品ではない。実機への入れ替えはABCに切り替え、旧アプリを退避してから行う。

## 互換性と確認

Bundle ID `org.sumibi.inputmethod.Sumibi`、日本語入力ソースID `org.sumibi.inputmethod.Sumibi.Japanese`、接続名`org.sumibi.inputmethod.Sumibi_Connection`、実行ファイル名`Sumibi`を変更しない。UserDefaultsのキー・保存形式、ユーザー辞書、Keychainサービス`org.sumibi.Sumibi-mac.api-key`とaccount `default`も変更しない。

Swiftのクラス名は整理するが、登録済みIMKのObjective-C名`SumibiPrototypeInputController`は残す。旧設定移行の`prototypeDomain`・`importPrototypeSettingsIfNeeded`は実際の試作版からの移行を表すため残し、移行元`dev.kiyoka.inputmethod.SumibiPrototypeProbe1`も変更しない。

通常・開発の両構成で138テストを実行し、既存の設定・移行・辞書・Keychainテストに加えて、登録名と実クラスの一致、残存する開発設定の無効化を確認する。成果物検証はビルド種別メタデータ、開発用設定文字列・模擬サービスの有無、登録識別子、素材、署名を確認する。実際の入力ソース登録と本人の設定・辞書・キーの保持は実機確認が必要。テストは本人の設定・Keychainを読まない。

2026-10-04、利用者がABCへ切り替えてから旧アプリを退避し、開発署名した#47の通常版へ入れ替えた。通常変換・候補選択・Escと、設定・ユーザー辞書・保存済みAPIキーの保持について、利用者から「すべて問題ありませんでした」と確認を得た。APIキー自体は取得・記録していない。この確認は既存の入力ソース登録を使った更新確認であり、新規登録・別Macでの導入・Developer ID署名／公証の検証ではない。
