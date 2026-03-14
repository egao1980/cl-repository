# CL Repository 要件（概要・日本語）

元ドキュメント: `docs/requirements/overview.md`

## 課題

Common Lisp には、PyPI/crates.io/npm 相当の標準配布基盤がなく、特にネイティブ依存の扱いが弱い。

## 目標

1. OCI 互換配布
2. マルチプラットフォーム native overlays
3. ASDF ネイティブな利用
4. 依存の軽量化
5. pure-Lisp 向け後方互換
6. Quicklisp/Ultralisp からのエコシステム移行

## 非目標

- 独自 registry サーバ実装
- FASL バイナリ配布
- アプリ層での署名機構実装（OCI 側機能に委譲）
