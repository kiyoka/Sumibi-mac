# GitHubからの自己配布設計

状態（2026-10-04）: 単一バンドル・ユーザー本人だけへの導入方針は確定。#15の配布スクリプトは別ブランチに実装中でmain未統合。Developer IDでの実署名・公証・pkgの実機導入・公開は未実施。開発署名のアプリビルドと既存登録での更新確認とは区別する。

現行構成は[技術解説](TECHNICAL_OVERVIEW.md)、コード・要件・未検証の照合は[実装照合記録](IMPLEMENTATION_AUDIT.md)、通常／開発ビルドは[ビルドモード](BUILD_MODES.md)を参照。

## 配布物と公開場所

- Mac App Storeには提出しない。
- IME・設定画面・メニューバーを同じプロセスで提供する単一の`Sumibi.app`を導入するmacOSインストーラーパッケージ（`.pkg`）を配布する方針。別の設定アプリやヘルパーを配置する構成ではない。[Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- 署名・公証済みの`.pkg`を**Sumibi-macリポジトリのGitHub Releasesの添付ファイル**として公開する。インストーラーのバイナリをGit履歴へコミットしない。リリースにはバージョン、対応macOS、変更点、ファイルのSHA-256値を記載する。[GitHub: About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- ダウンロードページは同リポジトリのGitHub Pagesでホストし、最新の安定版リリース、インストール・有効化手順、更新・削除手順、BYOKが必要なことを案内する。未公開のバージョンや存在しないインストーラーへリンクしない。Pages側にインストーラーバイナリを重複配置しない。[GitHub: Pagesの公開元](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)、[GitHub: Releasesへのリンク](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

ダウンロードページの原稿は[`docs/index.html`](index.html)に置く。PRが`main`へ取り込まれた後、リポジトリの「Settings → Pages」で公開元を「Deploy from a branch」、ブランチを`main`、フォルダーを`/docs`に設定する。これによりGitHub Pagesのプロジェクトサイトとして公開する。`docs/`内の他のMarkdown資料も公開対象になるため、公開前に機密情報がないことを確認する。初回リリース前に、実際のURL、リンク切れ、HTTPS、スマートフォンとMacでの表示を確認する。バイナリができる前に「ダウンロード可能」と表示しない。[GitHub: Pagesの公開元](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)

## 署名・公証・導入

1. 通常版の単一`Sumibi.app`を、インストールしたユーザーの`~/Library/Input Methods/Sumibi.app`へ導入する。全ユーザー用の`/Library/Input Methods`は採用しない。設定・メニューバーは同じアプリ内にあり、ログイン項目も`SMAppService.mainApp`でアプリ自身を登録する。pkgのhomeドメイン指定と実際の配置、標準ユーザーでの権限要求は#15の実物で検証し、模擬テストだけで「管理者権限不要」と保証しない。入力メソッド用ディレクトリについては[Appleの資料](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/inputmethodsdirectory)を参照する。
2. すべての実行可能コードを適切な**Developer ID Application**証明書で署名し、Hardened Runtimeを有効にする。`.pkg`には**Developer ID Installer**証明書を使う。Mac App Store用の署名・証明書を流用しない。[Apple: 配布用署名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、[Apple: パッケージ化](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
3. 配布する`.pkg`をAppleの公証サービスへ提出し、承認されたチケットを添付する。公証はApp Reviewではなく、配布物の検査である。[Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
4. 公証後のパッケージを未導入のMacで試し、Gatekeeperの確認、IMEの認識、入力ソースへの追加、設定画面、メニューバー常駐、BYOK接続を確認する。アップグレードでは設定・Keychain・ユーザー辞書を保持し、旧バージョンと重複して入力ソースが表示されないことを確認する。
5. `.pkg`には標準のアンインストール操作がないため、Sumibi専用の安全な削除方法と案内を別途用意する。削除対象を正確に列挙し、他アプリやユーザーデータを広く削除しない。設定・辞書・Keychain項目を削除するか残すかは、ユーザーへ明示して決める。

現行ビルドはSwift Packageと`App/build.sh`で行い、開発署名付き実行ファイル・アプリは作成済み。#15の別ブランチ`codex/issue-15-developer-id-distribution`、ローカルコミット`c027ccf`には配布用ビルド・pkg作成・公証のスクリプトがあるが、mainには未統合。#46でそのスナップショットへの模擬テスト18項目が成功している（[実行方法](../Tests/README.md)）。これは実際のDeveloper ID証明書・Appleの公証・Gatekeeper・pkg導入が成功したことを意味しない。

初回公開は実署名・公証・実機導入検証後に行う。2026-10-04のGitHub Releases一覧にはリリースがなかった。Pagesの公開設定・実ページの確認は今回行っていない。自動更新の有無とアンインストール時のデータ保持は未確定で、実装前に利用者へ確認する。導入範囲はユーザー本人のみという決定済みの事項である。

## PCCの扱い

[Appleの現行案内](https://developer.apple.com/private-cloud-compute/)では、PCCの本番利用は要件を満たす開発者の**App Store配布アプリ**として説明される。TestFlight・ad hocでの試験が可能という説明を、GitHubからの製品配布にも利用できるという意味には解釈しない。自己配布版ではmacOS 27でもPCCを提供せず、macOS 26以降の変換にはBYOKを必須とする。Appleが後日、自己配布の利用条件を明示した場合だけ再検討する。
