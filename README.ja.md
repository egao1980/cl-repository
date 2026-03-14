# CL Repository（日本語版）

英語版（正本）: `README.md`

Common Lisp パッケージを OCI アーティファクトとして配布するためのシステムです。

## 概要

- パッケージを標準 OCI 形式で公開/取得できます。
- GHCR、Docker Hub、Quay、社内レジストリなどを利用できます。
- ネイティブ依存向けに platform overlays をサポートします。
- OCICL と互換です。

## クイックスタート（CLI）

```sh
cl-repo install alexandria
cl-repo publish
cl-repo publish-github owner/repo --registry ghcr.io --namespace my-org/my-project
cl-repo sync-qlot --use-lock --publish-sources --registry ghcr.io --namespace my-org/my-project
cl-repo ql-export https://beta.quicklisp.org/dist/quicklisp.txt --registry ghcr.io --namespace my-org/my-project
```

## プロジェクトのオンボーディング

- ローカルプロジェクト: `cl-repo publish`（複数 ASDF は `--all-systems`）。
- GitHub リポジトリ: `cl-repo publish-github owner/repo`。
- qlot: `cl-repo sync-qlot`（`qlfile`/`qlfile.lock` は親ディレクトリまで自動探索）。
- 依存解決オプション:
  - `--publish-dependencies`: ローカル依存を自動公開
  - `--publish-ql-dependencies`: Quicklisp/Ultralisp exporter によるフォールバック
  - `--deps-dist-url`: dist URL を指定

## ドキュメント

- 仕様: `docs/spec.md`
- 要件: `docs/requirements/overview.md`
- ローカル CI（Docker + act）: `docs/tutorial-local-testing-docker-act.md`

## 多言語ドキュメント運用

主要ドキュメントには以下を用意します。
- `*.ru.md`（ロシア語）
- `*.ja.md`（日本語）

英語版更新時は、同じ変更で翻訳版も更新してください。
