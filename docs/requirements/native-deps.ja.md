# ネイティブ依存要件（日本語）

元ドキュメント: `docs/requirements/native-deps.md`

## 目的

C/C++ ライブラリや CFFI/groveler 成果物を OCI overlays として配布し、各環境での再ビルド不要・再現可能な導入を実現する。

## 主な要件

- universal source と platform overlays の分離
- `os` / `arch`（必要なら `os-version` / `implementation`）での明示的ターゲティング
- prebuilt shared libraries と pre-groveled output の同梱
- asdf-native の `:native-library` コンポーネントを宣言したシステムは `:overlays` 不要: `lib/<os>-<arch>/` の各ディレクトリがそのプラットフォームの overlay になる（全ファイルを `native/` へ、必須ライブラリを検査）。明示的な `:overlays` は同じプラットフォームに統合され（ヘッダーやデータファイルなど）、名前付き（cuda）や他プラットフォームは別 overlay のまま。`:defsystem-depends-on` は .asd を評価せずに読み取り、先に OCI からインストールする
- 実行時統合はパッケージ自身のローダーが ASDF ロード時に行う（`native/` のライブラリを絶対パスでロード）。cl-repo は init スクリプトを生成・実行しない

## 実運用

詳細は英語版および `examples/04-native-deps` / `examples/07-multiplatform-native-ci` を参照してください。
