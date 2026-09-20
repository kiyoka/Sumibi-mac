# GitHubからの自己配布設計

状態: 配布方針は確定。インストーラーの実装・実機検証・公開は未実施。

## 配布物と公開場所

- Mac App Storeには提出しない。
- IMEと設定・メニューバー用アプリを導入できるmacOSインストーラーパッケージ（`.pkg`）を配布する。複数の構成要素を所定の位置に配置する製品には、Appleもインストーラーパッケージを適した形式として案内している。[Apple: Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- 署名・公証済みの`.pkg`を**Sumibi-macリポジトリのGitHub Releasesの添付ファイル**として公開する。インストーラーのバイナリをGit履歴へコミットしない。リリースにはバージョン、対応macOS、変更点、ファイルのSHA-256値を記載する。[GitHub: About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- ダウンロードページは同リポジトリのGitHub Pagesでホストし、最新の安定版リリース、インストール・有効化手順、更新・削除手順、BYOKが必要なことを案内する。未公開のバージョンや存在しないインストーラーへリンクしない。Pages側にインストーラーバイナリを重複配置しない。[GitHub: Pagesの公開元](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)、[GitHub: Releasesへのリンク](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)

ダウンロードページの原稿は[`docs/index.html`](index.html)に置く。PRが`main`へ取り込まれた後、リポジトリの「Settings → Pages」で公開元を「Deploy from a branch」、ブランチを`main`、フォルダーを`/docs`に設定する。これによりGitHub Pagesのプロジェクトサイトとして公開する。`docs/`内の他のMarkdown資料も公開対象になるため、公開前に機密情報がないことを確認する。初回リリース前に、実際のURL、リンク切れ、HTTPS、スマートフォンとMacでの表示を確認する。バイナリができる前に「ダウンロード可能」と表示しない。[GitHub: Pagesの公開元](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)

## 署名・公証・導入

1. IME本体と、設定・メニューバーを提供するアプリ／ヘルパーの構成を決める。IMEの設置先を`/Library/Input Methods`（全ユーザー）と`~/Library/Input Methods`（単一ユーザー）の候補から実機で検証し、管理者権限の要否を明示する。設定アプリの配置先、ログイン項目の登録方法も合わせて決める。入力メソッド用ディレクトリについては[Appleの資料](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/inputmethodsdirectory)を参照する。
2. すべての実行可能コードを適切な**Developer ID Application**証明書で署名し、Hardened Runtimeを有効にする。`.pkg`には**Developer ID Installer**証明書を使う。Mac App Store用の署名・証明書を流用しない。[Apple: 配布用署名](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)、[Apple: パッケージ化](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
3. 配布する`.pkg`をAppleの公証サービスへ提出し、承認されたチケットを添付する。公証はApp Reviewではなく、配布物の検査である。[Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
4. 公証後のパッケージを未導入のMacで試し、Gatekeeperの確認、IMEの認識、入力ソースへの追加、設定画面、メニューバー常駐、BYOK接続を確認する。アップグレードでは設定・Keychain・ユーザー辞書を保持し、旧バージョンと重複して入力ソースが表示されないことを確認する。
5. `.pkg`には標準のアンインストール操作がないため、Sumibi専用の安全な削除方法と案内を別途用意する。削除対象を正確に列挙し、他アプリやユーザーデータを広く削除しない。設定・辞書・Keychain項目を削除するか残すかは、ユーザーへ明示して決める。

現在はXcodeプロジェクト・配布用証明書を使ったビルド・実行ファイルがないため、上記の成功は未確認である。初回公開は実機検証後に行う。自動更新の有無、インストール範囲（全ユーザー／単一ユーザー）、アンインストール時のデータ保持は未確定とし、実装前に利用者へ確認する。

## PCCの扱い

[Appleの現行案内](https://developer.apple.com/private-cloud-compute/)では、PCCの本番利用は要件を満たす開発者の**App Store配布アプリ**として説明される。TestFlight・ad hocでの試験が可能という説明を、GitHubからの製品配布にも利用できるという意味には解釈しない。自己配布版ではmacOS 27でもPCCを提供せず、macOS 26以降の変換にはBYOKを必須とする。Appleが後日、自己配布の利用条件を明示した場合だけ再検討する。
