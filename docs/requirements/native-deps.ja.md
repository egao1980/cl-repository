# ネイティブ依存要件（日本語）

元ドキュメント: `docs/requirements/native-deps.md`

## 目的

C/C++ ライブラリや CFFI/groveler 成果物を OCI overlays として配布し、各環境での再ビルド不要・再現可能な導入を実現する。

## 主な要件

- universal source と platform overlays の分離
- `os` / `arch`（必要なら `os-version` / `implementation`）での明示的ターゲティング
- prebuilt shared libraries と pre-groveled output の同梱
- init/loader を通じた実行時統合

## 実運用

詳細は英語版および `examples/04-native-deps` / `examples/07-multiplatform-native-ci` を参照してください。
