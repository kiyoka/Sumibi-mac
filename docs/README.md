# Sumibi-macの仕様・引き継ぎ資料

最終照合: **2026-10-20**／[Issue #63](https://github.com/kiyoka/Sumibi-mac/issues/63)。

| 読みたい内容 | 入口 |
| --- | --- |
| Windows版を始める | [Sumibi-winへの引き継ぎ](WINDOWS_HANDOFF.md) |
| 何が実装済みか、main／作業版の違い | [現行の実装照合](IMPLEMENTATION_AUDIT.md) |
| 合意した要件と将来機能 | [仕様書](SPEC.md) |
| Macの構成と入力先・非同期処理 | [技術解説](TECHNICAL_OVERVIEW.md)、[所有関係](INPUT_CONTROLLER_ARCHITECTURE.md) |
| 自動変換・費用・競合・確認履歴 | [Decisions](DECISIONS_CONVERSION.md) |
| 記号候補・データ生成・ライセンス | [記号](https://github.com/kiyoka/Sumibi-mac/blob/401507c02a04f2a025540aeca8d1bc0829683053/docs/SYMBOL_CANDIDATES.md) |
| 一時デバッグ・原文比較の使い方 | [診断画面](https://github.com/kiyoka/Sumibi-mac/issues/62)、[ログ規約](DIAGNOSTIC_LOGGING.md) |
| 長文の制約・エラーと対処 | [長文診断](LONG_INPUT_DIAGNOSTICS.md)、[表示](CONVERSION_FEEDBACK.md) |
| ビルドと回帰テスト | [通常／開発ビルド](BUILD_MODES.md)、[Tests](../Tests/README.md) |
| 配布・署名・公証・残作業 | [自己配布](DIRECT_DISTRIBUTION.md)、[Developer ID](DEVELOPER_ID_DISTRIBUTION.md) |

`SPEC.md`だけを実装一覧として読まない。mainはPR #60まで、記号は未マージPR #61、診断独立画面は
#62の未コミット作業版という、今回の確認時点の区分を[照合記録](IMPLEMENTATION_AUDIT.md)で確認する。
古いJevの資料・調査時の回避策・過去のテスト数は、現在の仕様を上書きしない。

## 変更時のメンテナンス手順

1. 対象コミット、mainと作業ブランチ・未追跡ファイル、関連Issue／PRの状態を確認する。
2. 機能を変えたらSPECの合意要件と実装照合表、関係する詳細仕様・テスト資料を併せて更新する。
3. 「設計」「実装済み」「main統合済み」「模擬確認」「実機確認」「公開済み」を別の状態として記録する。
4. Windowsにも影響する入力・API・上限・同意・辞書・診断の変更は、引き継ぎ資料へ反映する。
   Mac固有の不具合対策を、別OSの仕様として追認しない。
5. 数値は定義も記す。文字数／UTF-16／状態数／HTTP回数／料金、初期値／保存値、API送信／読取確認を区別する。
6. PRマージ後は基準SHAと区分を更新する。未確認・未解決項目を、マージやテストの成功だけで完了へしない。
7. 実行した検証だけを日付・対象構成・件数・スキップ・アプリ名付きで記す。未実行の過去結果を今日の結果にしない。
8. 相対リンクと参照先ファイルを検査する。本文・キー・ログ・署名秘密鍵を資料へ含めない。

この手順は変更に伴う資料更新のためのもので、自動監視・定期実行を設定したものではない。

## 履歴資料

[旧技術解説](TECHNICAL_OVERVIEW_HISTORY.md)、[Issue #4](ISSUE_4_PROTOTYPE.md)、
[2026-10-04の照合](IMPLEMENTATION_AUDIT_2026-10-04.md)、[旧Jevの履歴](AMBIENT_CONVERSION.md)は
当時の観測・判断を残す資料。現行コードとの照合は現在の文書から始める。
