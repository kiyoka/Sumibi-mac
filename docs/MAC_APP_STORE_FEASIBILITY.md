# 旧方針: Mac App Store向けIME配布の検証記録（Issue #3）

調査日: 2026-09-20。この文書は、当時のMac App Store配布案を調べた履歴である。その後、利用者はMac App Store配布を見送り、GitHubで自己配布する方針を決定した。**現在の仕様は[`SPEC.md`](SPEC.md)、配布設計は[`DIRECT_DISTRIBUTION.md`](DIRECT_DISTRIBUTION.md)を参照する。** 以下の調査結果とAppleへの質問は、現行リリースの完了条件ではない。

## 結論と検証範囲

**現時点では、InputMethodKit製のSumibi IMEをMac App Storeだけで配布できる構成は確認できていない。** Apple Developer Technical Support（DTS）は2020年に、macOSにはiOSのキーボード拡張に相当する仕組みがなく、IMEのMac App Store配布に公認の方法はないと回答した。2026年4月の同じスレッドでも、App Store対応の入力メソッド拡張をmacOSに追加する機能要望を勧めている。ただし、この2026年の返信は「macOS 27でも不可能」と明言したものではない。[Apple Developer Forums: How to distribute an Input Method Engine](https://developer.apple.com/forums/thread/134115)

このリポジトリにはまだXcodeプロジェクトやIME実行体がない。したがって、以下はAppleの公開資料とローカルSDKの調査結果であり、Sumibiの実機インストール、App Store Connectへのアップロード、TestFlight、審査の実測結果ではない。ストア審査に通ると推定して開発を進める根拠にはしない。

## 確認した環境・手順・結果

| 項目 | 手順 | 結果 |
| --- | --- | --- |
| 調査端末 | `sw_vers` | macOS 27.0（26A428） |
| 開発環境 | `xcodebuild -version`、`xcrun --sdk macosx --show-sdk-version` | Xcode 27.0（27A266a）、macOS SDK 27.0 |
| リポジトリ | `git ls-files` | 仕様・技術解説のみ。ビルド、署名、インストール試験を行う対象は未作成 |
| 公開された配布方法 | Apple DTSの[2020年の回答と2026年4月の追問](https://developer.apple.com/forums/thread/134115)を確認 | 2020年の回答はMac App Store配布を否定。2026年の回答は拡張機能の追加要望を案内。現行OSでの例外的な経路は未確認 |
| ストアのサンドボックス | Appleの[App Sandbox要件](https://developer.apple.com/documentation/security/app-sandbox)と[ファイルアクセス制約](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)を確認 | Mac App StoreアプリにはApp Sandboxが必須。任意の入力メソッド用ディレクトリへ、同梱IMEを自動配置できるとは確認できない |
| 入力メソッドAPI | macOS 27 SDKの公開`InputMethodKit.framework`と[InputMethodKit資料](https://developer.apple.com/documentation/inputmethodkit)を確認 | InputMethodKitは存在する。一方、この確認だけではストア対応のIME拡張・導入方法の存在を証明できない |
| 独立したメニューバー常駐 | [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)と[アプリ同梱ヘルパー構成](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)を確認 | アプリ同梱のログイン項目・エージェントをユーザー承認の下で登録する公開APIはある。Sumibiでの動作やストア審査は未試験。IMEの導入問題は解決しない |
| PCC | [PCCアクセス条件](https://developer.apple.com/private-cloud-compute/)、[managed entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute)、[Foundation ModelsのPCC資料](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)を確認 | macOS 27以降のAPIと管理対象権限が必要。Sumibiの権限付与状況、実行対象への付与可否、IMEからの呼び出しは未確認 |

## 配布構成ごとの判断

1. **`Sumibi.app`自体をIMEとしてストア配布する案:** Apple DTSの2020年の否定回答に直接該当する。App Storeが標準のアプリ配置先に置くだけで、入力ソースとして認識・有効化できるという公開手順は見つかっていない。試作や審査提出に先立ち、Appleに現行の扱いを確認する。
2. **ストアアプリにIMEを同梱し、初回起動時に入力メソッド用ディレクトリへコピーする案:** サンドボックスとインストール先の制約に抵触する可能性が高い。サンドボックスを迂回するヘルパーや権限昇格を前提にしない。Appleの明示的な承認なく製品構成に採用しない。
3. **macOS向けキーボード拡張として同梱する案:** Apple DTSが2026年4月時点で、そのようなApp Store対応の仕組みを追加する機能要望を勧めている。現行の公開資料・SDK調査から採用可能な拡張ポイントは確認できなかった。
4. **設定アプリとメニューバーのみをストア配布する案:** 常駐部分の実装には公開APIがあるが、IMEを別経路で提供するなら「Mac App StoreだけでSumibiを配布する」という合意済み要件を満たさない。配布方針の変更として別途利用者の判断が必要。

Mac App Storeで配布できたとしても、入力ソースの追加、ログイン項目の承認、更新時の再有効化、アンインストール後の残存物の扱いは実機で確認が必要である。現在はこれらを「成功」と記録しない。

## PCCとの関係

PCCは[Appleの案内](https://developer.apple.com/private-cloud-compute/)で、Small Business Programへの参加、アプリの初回ダウンロード数などの適格性、管理対象entitlementの付与を前提とする。OSがmacOS 27であることだけでは利用できない。開発者アカウントのプログラム参加承認とPCC権限付与は別に確認する。いずれも本調査では確認していない。

`com.apple.developer.private-cloud-compute`の既定値は`NO`であり、Appleへの申請が必要な管理対象権限である。実際にPCCを呼ぶ実行対象（IMEプロセス、設定アプリ、あるいは同梱ヘルパー）にどのような署名・プロビジョニングで付与できるかは、構成の確定後にAppleへ確認する。親アプリに権限を付ければ別プロセスのIMEでも使える、とは仮定しない。PCC API自体はmacOS 27以降で、対応デバイス・地域・設定・利用枠も必要である。[Foundation ModelsのPCC資料](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)

## Appleに確認する質問

以下をApple Developer Technical SupportまたはApp Reviewへの正式な問い合わせ文面の要点とする。問い合わせはまだ送信していない。

1. macOS 27で、InputMethodKit製のサードパーティIMEを**Mac App Storeのみ**で導入・有効化・更新・削除する、Appleが認める構成はあるか。ある場合、必要なアプリ／拡張ターゲット、配置先、公開資料、サンプルを示してほしい。
2. ストアのサンドボックス化された親アプリにIMEを同梱する場合、システムの入力ソースとして認識させる公認手順はあるか。初回起動時のコピーや同梱ログイン項目による配置は許されるか。
3. その構成でPCCの管理対象entitlementを申請するとき、どのBundle ID・実行対象に付与する必要があるか。IMEが別プロセスの場合、親アプリの権限から呼び出せるのか、IME側に個別の権限が必要か。
4. TestFlight、App Store Connectの検証、審査に進む前に、IME固有の事前承認や確認窓口はあるか。

## 当時の次のゲート（現在は適用しない）

- **現在の判定:** Mac App StoreからのIME本体の配布可否は未解決。公開されたApple DTS回答は否定的であり、製品構成に重大なリスクがある。
- **Appleの回答で公認の構成が示された場合:** 最小IME＋設定アプリ＋メニューバー項目をその構成で試作し、サンドボックス、署名、導入、有効化、更新、削除を実測する。PCC entitlementの付与対象を確定し、許可取得後にTestFlight等で確認する。
- **Appleが現行も非対応と回答した場合:** Mac App Store配布とInputMethodKit製IMEの両立は要件上の衝突として利用者へ提示する。ストア外配布、IME以外の方式、製品範囲の変更のいずれも、別途合意なしに決めない。

上記は配布先変更前の判断基準である。現在はAppleへのMac App Store配布可否の回答を待たず、自己配布用の署名・公証・インストーラー・GitHub Pagesを検証する。PCCの自己配布への適用可否は別の問題として扱い、Appleの現行案内を満たせない限り製品には含めない。
