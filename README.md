# Sumibi for macOS

ローマ字・英語をLLMで自然な日本語へ変換するmacOS用入力メソッド。
変換は利用者のAPIキー（BYOK）を使用し、任意でDecisionsによる自動変換を有効にできる。

- [仕様・資料の入口](docs/README.md)
- [現行実装と未実装・未解決事項](docs/IMPLEMENTATION_AUDIT.md)
- [Windows版Sumibi-winへの引き継ぎ](docs/WINDOWS_HANDOFF.md)
- [ビルド](docs/BUILD_MODES.md)／[テスト](Tests/README.md)
- [配布の準備・検証状況](docs/DEVELOPER_ID_DISTRIBUTION.md)

2026-10-20時点の基準mainはPR #65まで。記号サポートも統合済み。診断画面の独立化は#62対応ブランチの変更であり、
仕様書に記載された全機能がmainや公開版に含まれるわけではない。参照時点の区分は実装照合記録を確認する。
macOS 26以降を対象とし、Windows版の実装方式・対応OS・配布は別途設計する。
