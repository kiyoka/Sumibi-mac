# Developer IDによる単一ユーザー用pkg配布（Issue #15）

2026-10-15: 以前の配布実装 `c027ccf` を現在の作業ツリーへ取り込み、通常版ビルドへ追従した。配布処理の模擬テスト28項目と通常版のローカルビルド・成果物検査が成功。同日、Developer ID Application／Installerの実署名とタイムスタンプの検証、検証用pkgのApple公証Accepted・チケット添付／検証・Gatekeeper判定が成功した。別Macでのpkg導入、公開は未実施。mainへ取り込まれた状態とは区別する。

初回確認では、このMacにDeveloper ID証明書は見つからなかった。同日、利用者がApplication／Installerをそれぞれ発行した。キーチェーンアクセスで読込エラー-25294とフリーズが発生したため、本人の承認後、対象CERだけをログインキーチェーンへ追加する標準コマンドを実行した。Applicationは登録済み、Installerは追加成功と報告され、いずれも `kiyoka nishiyama (HJ95UN7B74)` の有効な署名用IDとして認識されている。ローカルの証明書検証も成功した。既存項目の削除・信頼設定変更・秘密鍵の取り出しは行っていない。GUIのフリーズ原因は未特定。公証用のアプリ用パスワードは本人が作成・入力し、Keychainプロファイル `Sumibi-notary` への保存成功を報告した。秘密の値はチャット・ログ・資料に記録していない。

実署名の検証物は `.build/distribution/build.GKoGdj/Sumibi.app` と `.build/distribution/package.wfDB5v/Sumibi-0.4-4-arm64.pkg`。現行 `App/Info.plist` の0.4／build 4を用いた検証用であり、0.9.0リリース成果物ではない。アプリのHardened Runtime・Developer ID Application署名・タイムスタンプ、外側pkgの同じTeamのDeveloper ID Installer署名・信頼済みタイムスタンプを確認した。本人がmacOSのcodesign鍵アクセス要求を許可した。pkgを一時フォルダーへ完全展開した後も、格納アプリの通常版コード境界・リソース・識別子・署名と、home限定の導入設定が検証に成功した。pkgbuildの `write: Permission denied` 警告4回は再発しており、原因未特定として残す。インストール済みSumibiの入れ替え・起動終了・公開は行っていない。

### 公証の実施結果（2026-10-15）

統合状態の更新（2026-10-20確認）：配布スクリプトは2026-10-17にPR #59でmainへ統合済み。
上記の証明書・署名・公証は2026-10-15の履歴であり、0.9.0の最終配布物やpkg実機導入の合格ではない。

本人の明示承認後、上記検証用pkgをAppleへ1回提出し、承認後に外側pkgへチケットを添付した。インストール・GitHubへの公開は行っていない。

- 提出ID: `184d0ef9-af24-47ce-9950-4fe0f69162d7`
- Appleの結果: `Accepted`、`Ready for distribution`、issues 0件。
- チケット添付と `stapler validate`: 成功。
- Gatekeeper: `accepted`、`source=Notarized Developer ID`。
- 最終pkgのSHA-256: `4612ab745f6526a8cbeea8aa9c2c6391a92a7f05064304b85742de7c43adc17c`。添付後に作成したチェックサムの再検証も成功。
- 記録: `.build/distribution/package.wfDB5v/Sumibi-0.4-4-arm64.notary.XYJCIb/` の `submission.plist`、`log.json`、`SHA256.txt`。

公証・チケット検証の成功は、標準ユーザーでの導入・更新時の設定保持・別Macでの入力ソース追加を検証済みにするものではない。実署名検査はmacOSの証明書検証へアクセスできる環境で実行する。制限された環境では同じpkgでも署名無効と報告されたが、通常の検証環境・Apple公証・Gatekeeperで成功した。

同日、実際のmacOSの`pkgbuild`／`productbuild`で署名なしの一時検証pkgを組み立て、展開後のhome限定設定・コンポーネント配置と、ペイロードから取り出したアプリの通常版内容・登録識別子・リソース・アドホック署名を検査した。すべて成功したが、`pkgbuild`は終了コード0でも`write: Permission denied`を4回表示した。原因は未特定であり、実配布用ビルド時に再確認する。これは実署名・公証・Installerでの導入確認の代替ではない。通常構成のSwift回帰テストも成功した。

## 方針と準備

- 通常版の単一 `Sumibi.app` を導入する `.pkg`。全ユーザー用インストールは提供しない。
- 同じTeamの **Developer ID Application** と **Developer ID Installer** を、それぞれ秘密鍵付きで用意する。Apple DistributionはApp Store向けであり代替にならない。[Apple: Developer ID証明書の作成](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- 各証明書用に新しいCSRを作成する。今回Application用CSRをInstallerへ再利用すると、Appleの申請画面で「使用済み」として拒否された。新しく生成したCSRに差し替えてInstallerの発行が成功した。既存の証明書・鍵・CSRを削除・上書きしない。
- 公証にはXcode付属の `notarytool` と、本人が準備したKeychainプロファイルを使う。証明書・秘密鍵・パスワード・APIキーをリポジトリやチャットへ貼らない。
- 証明書の作成・読み込み、認証情報の登録、公証への提出、GitHub Releasesへの公開は、それぞれ利用者の確認のうえで行う。この手順書を用意しただけでは提出・公開しない。
- バージョンは `App/Info.plist` が元になる。0.9.0への番号更新と公開はリリース準備Issue #57で扱い、#28はその対象外。

準備状況は、秘密情報を取り出さない次の照会で確認できる。

```sh
security find-identity -v -p codesigning
security find-identity -v -p basic
```

公証用プロファイルは本人がローカルで対話的に登録する。以下の `Sumibi-notary` は例示名で、設定済みという意味ではない。認証値をコマンド引数や手順書へ書き込まない。

```sh
xcrun notarytool store-credentials Sumibi-notary
```

## 1. 通常版の配布用アプリをビルド

リポジトリのルートで実行する。証明書名は有効な本人のものへ置き換える。

```sh
SUMIBI_DEVELOPER_ID_APPLICATION='Developer ID Application: NAME (TEAMID)' \
  sh Distribution/build-app.sh
```

この入口は開発版の引数を拒否し、証明書がなければビルド前に停止する。現在の `App/build.sh` を通常モードで呼び、継承された開発署名指定を明示的に上書きする。通常版の内容検証後、`.build/distribution/build.XXXXXX/Sumibi.app` という独立したコピーにDeveloper ID署名・Hardened Runtime・セキュアタイムスタンプを付け、署名を検査する。[Apple: 公証の要件](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

開発機能・模擬変換サービス・旧テキストログ実装が混入していないこと、登録識別子、辞書・アイコン・ライセンス等のリソースを `Development/verify-build.rb` で検査する。インストール済みアプリ、入力ソース、設定・辞書・APIキーは変更せず、IMEを起動・終了しない。

## 2. 単一ユーザー用pkgを作成

直前に表示された配布用アプリの絶対パスを指定する。

```sh
SUMIBI_DEVELOPER_ID_INSTALLER='Developer ID Installer: NAME (TEAMID)' \
  sh Distribution/build-pkg.sh '/absolute/path/to/Sumibi.app'
```

Developer ID Installerの秘密鍵付き署名、通常版の内容、アプリ署名の種類・Team・Runtime・タイムスタンプを検査してからパッケージを作る。バージョン・最小macOS・CPU種類は指定アプリから取得し、生成後のpkg署名も照合する。現行ビルドは実行したMacのCPU向けであり、検査したバイナリがUniversalでない限りUniversal対応と案内しない。

`Distribution.xml` はhomeドメインのみを許可し、localSystem／anywhereを無効にする。コンポーネントの `/Library/Input Methods` はこのhomeドメインに対する配置であり、意図する実配置は `~/Library/Input Methods/Sumibi.app`。Appleの仕様ではhomeドメインは現在のユーザーとして動作し、ホーム外へ書き込めない。ただし実際のInstallerの配置・権限要求は別Macの標準ユーザーで確認するまで検証済みとはしない。[Apple: インストール先ドメイン](https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html#//apple_ref/doc/uid/TP40005370-CH100-SW9)

既存バンドルを検索して別の場所へ再配置しない。インストールスクリプト・ヘルパーを含めず、入力ソース登録、ログイン項目、APIキーの設定も自動操作しない。配布対象は表示された **外側の `Sumibi-<version>-<build>-<CPU>.pkg`** のみで、内部の `Sumibi-component.pkg` は配布しない。

## 3. 本人の承認後、公証とチケット添付

外側のpkgの絶対パスと、準備したKeychainプロファイル名を指定する。この操作はpkgをAppleへ送信する。

```sh
sh Distribution/notarize-pkg.sh '/absolute/path/to/Sumibi-version-build-CPU.pkg' Sumibi-notary
```

処理順は、pkgの署名確認 → 公証提出と完了待ち → 結果・ログ保存 → `Accepted` の確認 → チケット添付 → チケット検証 → Gatekeeperのインストーラー判定 → 最終pkgのSHA-256作成。署名・提出・承認・添付・判定のいずれかに失敗したら停止し、自動再提出や公開をしない。

pkgの隣に `*.notary.XXXXXX` を作り、`submission.plist`・`log.json`・`SHA256.txt` を保存する。途中失敗の場合は作成済みの記録だけが残る。通信切断等で提出の成否が不明な場合は、記録を確認して既存提出を追跡し、むやみに再提出しない。公証承認だけで導入・起動の成功とは扱わない。

## 4. 実物で確認する項目

- [x] Developer ID Application／Installerによる実署名と同じTeamの確認（2026-10-15、検証用0.4／build 4、arm64）。
- [x] 公証Accepted、チケット添付・検証、Gatekeeper判定、最終SHA-256（2026-10-15、上記検証用pkg）。
- [ ] 未導入の対応Macへダウンロードしたpkgを標準ユーザーで導入し、本人の `Library/Input Methods` だけに配置されること。権限要求と別ユーザーへの影響も確認。
- [ ] 必要ならログアウト・ログイン後、macOSの入力ソースへSumibiを追加し、メニュー・設定画面を利用できること。通常版は開発専用の `--settings` 起動に依存しない。
- [ ] 本人の操作でAPIキーと送信同意を設定し、手動／自動変換・候補・Esc・Command+Zを確認する。
- [ ] 既存版から更新し、設定・辞書・保存済みAPIキー・入力ソースが保持されること。署名Team変更時のKeychainアクセスは特に確認し、実キーを取得・記録しない。
- [ ] 更新・削除・旧版への戻し方を実機確認し、利用者向け案内へ反映する。設定・辞書・Keychainの削除を無断で含めない。

検証日・OS・CPU・標準ユーザーでの結果を記録した後に、Issue #15の完了を判断する。リリース公開とPagesの案内は#57で別に進める。[自己配布設計](DIRECT_DISTRIBUTION.md)も参照。

## 送信・インストールをしない自動検証

```sh
ruby Tests/Distribution/test-distribution.rb
```

28項目を専用の一時ディレクトリ・模擬ツール・ダミーデータで確認する。署名・公証・導入が実際に成功したという意味ではない。[テストの詳細](../Tests/README.md)を参照。
